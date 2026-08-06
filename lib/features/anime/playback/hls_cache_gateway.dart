import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hls/hls.dart';

import '../../../core/source/models.dart';
import 'hls_cache_store.dart';
import 'hls_media_rewriter.dart';
import 'hls_session.dart';
import 'hls_stream_response.dart';

class HlsUpstreamResponse {
  const HlsUpstreamResponse({
    required this.statusCode,
    required this.bytes,
    required this.headers,
  });

  final int statusCode;
  final List<int> bytes;
  final Map<String, List<String>> headers;

  String get contentType =>
      headers[HttpHeaders.contentTypeHeader]?.firstOrNull ??
      'application/octet-stream';
}

abstract interface class HlsUpstreamClient {
  Future<HlsUpstreamResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    int? rangeStart,
    int? rangeLength,
  });
}

/// HLS 上游地址准入策略。
///
/// 清单内容由上游站点控制,里面的每个 URI 都可能指向任意主机,所以注册资源前和跟随
/// 重定向时都必须过这里。只校验字面量 IP —— 域名解析后落到内网(DNS rebinding)不在
/// 本策略覆盖范围内,那需要解析并锁定地址,代价高得多。
class HlsUpstreamPolicy {
  const HlsUpstreamPolicy({this.allowLoopback = false});

  final bool allowLoopback;

  Uri validate(Uri uri) {
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('HLS 上游必须是无凭据 HTTP(S) URL');
    }
    if (allowLoopback) return uri;
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host.endsWith('.localhost')) {
      throw const FormatException('HLS 上游不能指向回环网络');
    }
    final address = InternetAddress.tryParse(host);
    if (address != null && !_isPublic(address)) {
      throw const FormatException('HLS 上游不能指向回环或内网地址');
    }
    return uri;
  }

  static bool _isPublic(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return false;
    }
    final raw = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final a = raw[0];
      final b = raw[1];
      if (a == 0 || a == 10 || a == 127) return false; // 本网段 / 私有 / 回环
      if (a == 172 && b >= 16 && b <= 31) return false; // 172.16/12
      if (a == 192 && b == 168) return false; // 192.168/16
      if (a == 100 && b >= 64 && b <= 127) return false; // CGNAT 100.64/10
      if (a == 169 && b == 254) return false; // 云元数据 169.254.169.254
      if (a >= 224) return false; // 组播 / 保留
      return true;
    }
    if (raw.every((byte) => byte == 0)) return false; // ::
    if ((raw[0] & 0xfe) == 0xfc) return false; // fc00::/7 唯一本地地址
    if (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) return false; // fe80::/10
    // ::ffff:a.b.c.d —— IPv4 映射地址要按 IPv4 规则再判一次。
    final mapped = raw.take(10).every((byte) => byte == 0) &&
        raw[10] == 0xff &&
        raw[11] == 0xff;
    if (mapped) {
      return _isPublic(InternetAddress.fromRawAddress(
        Uint8List.fromList(raw.sublist(12)),
      ));
    }
    return true;
  }
}

abstract interface class HlsStreamingUpstreamClient {
  Future<HlsStreamResponse> stream(
    Uri uri, {
    required Map<String, String> headers,
    int? rangeStart,
    int? rangeLength,
  });
}

class DioHlsUpstreamClient
    implements HlsUpstreamClient, HlsStreamingUpstreamClient {
  const DioHlsUpstreamClient(
    this.dio, {
    this.policy = const HlsUpstreamPolicy(),
    this.maxRedirects = 5,
  });

  final Dio dio;
  final HlsUpstreamPolicy policy;
  final int maxRedirects;

  @override
  Future<HlsUpstreamResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    int? rangeStart,
    int? rangeLength,
  }) async {
    final requestHeaders = Map<String, String>.of(headers);
    if (rangeStart != null && rangeLength != null) {
      requestHeaders[HttpHeaders.rangeHeader] =
          'bytes=$rangeStart-${rangeStart + rangeLength - 1}';
    }
    // 自动跟随重定向会绕过 policy:上游只要 302 到 127.0.0.1 / 内网就穿透了准入检查。
    // 所以关掉 Dio 的自动跳转,自己逐跳校验 Location。
    var target = policy.validate(uri);
    for (var hop = 0; hop <= maxRedirects; hop++) {
      final response = await dio.get<List<int>>(
        target.toString(),
        options: Options(
          responseType: ResponseType.bytes,
          headers: requestHeaders,
          validateStatus: (_) => true,
          followRedirects: false,
          maxRedirects: 0,
        ),
      );
      final status = response.statusCode ?? 0;
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (status < 300 || status > 399 || location == null) {
        return HlsUpstreamResponse(
          statusCode: status,
          bytes: response.data ?? const [],
          headers: response.headers.map,
        );
      }
      final next = policy.validate(target.resolve(location));
      // 跨主机跳转不得携带原站认证头。
      if (next.host.toLowerCase() != target.host.toLowerCase()) {
        requestHeaders.removeWhere(
          (key, _) => _credentialHeaders.contains(key.toLowerCase()),
        );
      }
      target = next;
    }
    throw const FormatException('HLS 上游重定向次数过多');
  }

  @override
  Future<HlsStreamResponse> stream(
    Uri uri, {
    required Map<String, String> headers,
    int? rangeStart,
    int? rangeLength,
  }) async {
    final requestHeaders = Map<String, String>.of(headers);
    if (rangeStart != null) {
      requestHeaders[HttpHeaders.rangeHeader] = rangeLength == null
          ? 'bytes=$rangeStart-'
          : 'bytes=$rangeStart-${rangeStart + rangeLength - 1}';
    }
    final cancelToken = CancelToken();
    var target = policy.validate(uri);
    for (var hop = 0; hop <= maxRedirects; hop++) {
      final response = await dio.get<ResponseBody>(
        target.toString(),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: requestHeaders,
          validateStatus: (_) => true,
          followRedirects: false,
          maxRedirects: 0,
        ),
      );
      final status = response.statusCode ?? 0;
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (status < 300 || status > 399 || location == null) {
        return HlsStreamResponse(
          statusCode: status,
          stream:
              response.data?.stream.cast<List<int>>() ?? const Stream.empty(),
          headers: response.headers.map,
          cancel: () async {
            if (!cancelToken.isCancelled) {
              cancelToken.cancel('stream-cancelled');
            }
          },
        );
      }
      await response.data?.stream.drain<void>();
      final next = policy.validate(target.resolve(location));
      if (next.host.toLowerCase() != target.host.toLowerCase()) {
        requestHeaders.removeWhere(
          (key, _) => _credentialHeaders.contains(key.toLowerCase()),
        );
      }
      target = next;
    }
    throw const FormatException('HLS 上游重定向次数过多');
  }
}

const Set<String> _credentialHeaders = {
  'authorization',
  'cookie',
  'proxy-authorization',
  'x-auth-token',
};

abstract interface class HlsSessionGateway {
  Future<HlsSession> open(
    VideoTrack track, {
    required String authScope,
  });
}

class HlsCacheGateway implements HlsSessionGateway {
  HlsCacheGateway({
    required HlsCacheStore cache,
    required HlsUpstreamClient upstream,
    this.allowLoopbackUpstream = false,
  })  : _cache = cache,
        _upstream = upstream,
        _policy = HlsUpstreamPolicy(allowLoopback: allowLoopbackUpstream);

  final HlsCacheStore _cache;
  final HlsUpstreamClient _upstream;
  final bool allowLoopbackUpstream;
  final HlsUpstreamPolicy _policy;
  final Random _random = Random.secure();
  final Map<String, _SessionData> _sessions = {};
  final Set<Future<void>> _activeRequests = {};
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;

  @override
  Future<HlsSession> open(
    VideoTrack track, {
    required String authScope,
  }) async {
    if (!track.hls) throw ArgumentError.value(track.url, 'track', '不是 HLS');
    await _ensureServer();
    final source = _policy.validate(Uri.parse(track.url));
    final id = _randomId();
    final data = _SessionData(
      id: id,
      headers: Map.unmodifiable(track.headers ?? const {}),
      authScope: authScope,
      originHost: source.host.toLowerCase(),
    );
    _sessions[id] = data;
    final root = _register(data, source, _ResourceKind.playlist);
    return HlsSession(
      localUri: _localUri(id, root.id),
      onClose: () => _closeSession(id),
      onBuffer: (buffer) {
        final healthy = buffer >= const Duration(seconds: 15);
        if (data.bufferHealthy && !healthy) data.prefetchGeneration++;
        data.bufferHealthy = healthy;
      },
      onSeek: () => data.prefetchGeneration++,
    );
  }

  Future<void> _ensureServer() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _subscription = server.listen(_acceptRequest);
  }

  void _acceptRequest(HttpRequest request) {
    late final Future<void> operation;
    operation = _handleRequest(request).whenComplete(() {
      _activeRequests.remove(operation);
    });
    _activeRequests.add(operation);
    unawaited(operation);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final parts = request.uri.pathSegments;
    if (parts.length != 2) {
      await _respondError(request, HttpStatus.notFound, 'not-found');
      return;
    }
    final session = _sessions[parts[0]];
    final resource = session?.resources[parts[1]];
    if (session == null || resource == null) {
      await _respondError(request, HttpStatus.notFound, 'not-found');
      return;
    }
    try {
      switch (resource.kind) {
        case _ResourceKind.playlist:
          await _servePlaylist(request, session, resource);
        case _ResourceKind.segment:
        case _ResourceKind.init:
          await _serveMedia(request, session, resource);
        case _ResourceKind.key:
          await _serveKey(request, session, resource);
      }
    } on UnsupportedHlsEncryption {
      await _respondError(
        request,
        HttpStatus.notImplemented,
        'unsupported-hls-encryption',
      );
    } catch (_) {
      await _respondError(request, HttpStatus.badGateway, 'hls-gateway-error');
    }
  }

  Future<void> _servePlaylist(
    HttpRequest request,
    _SessionData session,
    _Resource resource,
  ) async {
    final upstream = await _fetch(session, resource);
    final text = utf8.decode(upstream.bytes);
    final parsed = HlsParser.parse(text, baseUri: resource.uri.resolve('.'));
    late final List<int> body;
    if (parsed is HlsMasterPlaylist) {
      body = utf8.encode(HlsComposer.compose(_rewriteMaster(session, parsed)));
    } else if (parsed is HlsMediaPlaylist) {
      body = utf8.encode(
        _rewriteMediaText(
          session,
          text,
          baseUri: resource.uri.resolve('.'),
        ),
      );
    } else {
      throw const FormatException('未知 HLS 清单');
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType(
      'application',
      'vnd.apple.mpegurl',
      charset: 'utf-8',
    );
    request.response.contentLength = body.length;
    request.response.add(body);
    await request.response.close();
  }

  HlsMasterPlaylist _rewriteMaster(
    _SessionData session,
    HlsMasterPlaylist source,
  ) {
    final normalized = HlsComposer.normalize(source) as HlsMasterPlaylist;
    Uri playlist(Uri uri) {
      final resource = _register(
        session,
        _validateUpstream(uri),
        _ResourceKind.playlist,
      );
      return _localUri(session.id, resource.id);
    }

    Uri key(Uri uri) {
      final resource =
          _register(session, _validateUpstream(uri), _ResourceKind.key);
      return _localUri(session.id, resource.id);
    }

    return normalized.copyWith(
      variants: normalized.variants
          .map((variant) => variant.copyWith(uri: playlist(variant.uri)))
          .toList(),
      renditions: normalized.renditions
          .map((rendition) => rendition.copyWith(
                uri: rendition.uri == null ? null : playlist(rendition.uri!),
              ))
          .toList(),
      iFrameVariants: normalized.iFrameVariants
          .map((variant) => variant.copyWith(uri: playlist(variant.uri)))
          .toList(),
      sessionKeys: normalized.sessionKeys
          .map((sessionKey) => sessionKey.copyWith(uri: key(sessionKey.uri)))
          .toList(),
    );
  }

  String _rewriteMediaText(
    _SessionData session,
    String source, {
    required Uri baseUri,
  }) {
    final rewriter = HlsMediaRewriter();
    final isLive = rewriter.isLivePlaylist(source);
    final segmentResources = <_Resource>[];
    final result = rewriter.rewrite(
      source,
      baseUri: baseUri,
      register: (uri, kind, range) {
        final resourceKind = switch (kind) {
          HlsUriKind.segment => _ResourceKind.segment,
          HlsUriKind.init => _ResourceKind.init,
          HlsUriKind.key => _ResourceKind.key,
        };
        final resource = _register(
          session,
          _validateUpstream(uri),
          resourceKind,
          rangeStart: range?.offset,
          rangeLength: range?.length,
          live: isLive,
        );
        if (kind == HlsUriKind.segment) segmentResources.add(resource);
        return _localUri(session.id, resource.id);
      },
    );

    for (var index = 0; index < segmentResources.length; index++) {
      segmentResources[index].prefetchIds = isLive
          ? const []
          : segmentResources
              .skip(index + 1)
              .take(3)
              .map((resource) => resource.id)
              .toList();
      segmentResources[index].forwardPrefetchId =
          isLive || index + 4 >= segmentResources.length
              ? null
              : segmentResources[index + 4].id;
    }

    return result.text;
  }

  Future<void> _serveMedia(
    HttpRequest request,
    _SessionData session,
    _Resource resource,
  ) async {
    _RequestedRange? range;
    try {
      range = _parseRange(request.headers.value(HttpHeaders.rangeHeader));
    } on FormatException {
      await _respondError(
        request,
        HttpStatus.requestedRangeNotSatisfiable,
        'invalid-range',
      );
      return;
    }
    final cacheRequest = HlsCacheRequest(
      url: resource.uri.toString(),
      authScope: session.authScope,
      rangeStart: resource.rangeStart,
      rangeLength: resource.rangeLength,
    );
    final hit = resource.live ? null : await _cache.lookup(cacheRequest);
    if (hit != null) {
      try {
        await _serveCacheHit(request, hit, range);
      } finally {
        await hit.release();
      }
      _schedulePrefetch(session, resource);
      return;
    }

    await _streamMediaMiss(
      request,
      session,
      resource,
      cacheRequest,
      range,
    );
    if (range == null) _schedulePrefetch(session, resource);
  }

  Future<void> _serveCacheHit(
    HttpRequest request,
    HlsCacheLease lease,
    _RequestedRange? range,
  ) async {
    final length = await lease.file.length();
    var start = 0;
    var end = length - 1;
    if (range != null) {
      if (range.start >= length) {
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */$length',
        );
        await _respondError(
          request,
          HttpStatus.requestedRangeNotSatisfiable,
          'range-not-satisfiable',
        );
        return;
      }
      start = range.start;
      end = min(range.end ?? end, end);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$length',
      );
    } else {
      request.response.statusCode = HttpStatus.ok;
    }
    request.response.headers.contentType =
        _contentTypeOrBinary(lease.contentType);
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.contentLength = end - start + 1;
    await request.response.addStream(lease.file.openRead(start, end + 1));
    await request.response.close();
  }

  Future<void> _streamMediaMiss(
    HttpRequest request,
    _SessionData session,
    _Resource resource,
    HlsCacheRequest cacheRequest,
    _RequestedRange? range,
  ) async {
    final localLength = resource.rangeLength;
    if (range != null && localLength != null && range.start >= localLength) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$localLength',
      );
      await _respondError(
        request,
        HttpStatus.requestedRangeNotSatisfiable,
        'range-not-satisfiable',
      );
      return;
    }
    final rangeEnd = range == null
        ? null
        : min(range.end ?? ((localLength ?? 0) - 1),
            localLength == null ? (range.end ?? -1) : localLength - 1);
    final upstreamStart = range == null
        ? resource.rangeStart
        : (resource.rangeStart ?? 0) + range.start;
    final upstreamLength = range == null
        ? resource.rangeLength
        : rangeEnd != null && rangeEnd >= range.start
            ? rangeEnd - range.start + 1
            : null;
    final upstream = await _fetchStream(
      session,
      resource,
      rangeStart: upstreamStart,
      rangeLength: upstreamLength,
    );
    if (upstream.statusCode < 200 || upstream.statusCode >= 300) {
      await upstream.cancel();
      throw HttpException('上游 HTTP ${upstream.statusCode}');
    }
    if (range != null && upstream.statusCode != HttpStatus.partialContent) {
      await upstream.cancel();
      await _respondError(
        request,
        HttpStatus.requestedRangeNotSatisfiable,
        'upstream-range-unsupported',
      );
      return;
    }

    HlsCacheWriter? writer;
    if (!resource.live && range == null) {
      try {
        writer = await _cache.beginWrite(cacheRequest);
      } on StateError {
        writer = null;
      }
    }
    request.response.statusCode =
        range == null ? HttpStatus.ok : HttpStatus.partialContent;
    request.response.headers.contentType =
        _contentTypeOrBinary(upstream.contentType);
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (range != null) {
      final total =
          localLength ?? _totalFromContentRange(upstream.contentRange);
      final returnedLength = upstream.contentLength ?? upstreamLength;
      final end = returnedLength == null
          ? (range.end ?? range.start)
          : range.start + returnedLength - 1;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.start}-$end/${total ?? '*'}',
      );
    }
    if (upstream.contentLength != null) {
      request.response.contentLength = upstream.contentLength!;
    } else {
      request.response.bufferOutput = false;
      request.response.headers.chunkedTransferEncoding = true;
    }

    HlsCacheLease? committed;
    try {
      await for (final chunk in upstream.stream) {
        writer?.sink.add(chunk);
        request.response.add(chunk);
        await request.response.flush();
      }
      if (writer != null) {
        committed = await writer.commit(
          contentType: upstream.contentType,
          expectedLength: upstream.contentLength,
        );
      }
      await request.response.close();
    } catch (_) {
      await writer?.abort();
      await upstream.cancel();
      try {
        await request.response.close();
      } on Object {
        // The player may have cancelled the local HTTP request mid-segment.
      }
    } finally {
      await committed?.release();
    }
  }

  void _schedulePrefetch(_SessionData session, _Resource resource) {
    if (resource.prefetchIds.isEmpty) return;
    final generation = session.prefetchGeneration;
    final ids = List<String>.of(resource.prefetchIds);
    if (session.bufferHealthy && resource.forwardPrefetchId != null) {
      ids.add(resource.forwardPrefetchId!);
    }
    session.prefetch =
        (session.prefetch ?? Future<void>.value()).then((_) async {
      if (session.closing) return;
      await _prefetch(session, ids, generation);
    });
    unawaited(session.prefetch);
  }

  _RequestedRange? _parseRange(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(value.trim());
    if (match == null) throw const FormatException('invalid range');
    final start = int.parse(match.group(1)!);
    final endText = match.group(2)!;
    final end = endText.isEmpty ? null : int.parse(endText);
    if (end != null && end < start) {
      throw const FormatException('invalid range');
    }
    return _RequestedRange(start, end);
  }

  int? _totalFromContentRange(String? value) {
    if (value == null) return null;
    final match = RegExp(r'/([0-9]+)$').firstMatch(value);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  Future<void> _serveKey(
    HttpRequest request,
    _SessionData session,
    _Resource resource,
  ) async {
    var bytes = session.keyBytes[resource.id];
    if (bytes == null) {
      final response = await _fetch(session, resource);
      bytes = Uint8List.fromList(response.bytes);
      session.keyBytes[resource.id] = bytes;
    }
    await _writeResponse(request, bytes, 'application/octet-stream');
  }

  Future<void> _prefetch(
    _SessionData session,
    List<String> ids,
    int generation,
  ) async {
    for (final id in ids) {
      if (session.closing ||
          generation != session.prefetchGeneration ||
          !_sessions.containsKey(session.id)) {
        return;
      }
      final resource = session.resources[id];
      if (resource == null || resource.kind != _ResourceKind.segment) continue;
      try {
        final lease = await _cache.acquire(
          HlsCacheRequest(
            url: resource.uri.toString(),
            authScope: session.authScope,
            rangeStart: resource.rangeStart,
            rangeLength: resource.rangeLength,
          ),
          (file) async {
            final upstream = await _fetch(session, resource);
            await file.writeAsBytes(upstream.bytes, flush: true);
            return CacheDownloadResult(
              contentType: upstream.contentType,
              expectedLength: upstream.bytes.length,
            );
          },
        );
        await lease.release();
      } catch (_) {
        return;
      }
    }
  }

  Future<HlsUpstreamResponse> _fetch(
    _SessionData session,
    _Resource resource,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await _upstream.get(
          resource.uri,
          headers: _headersFor(session, resource.uri),
          rangeStart: resource.rangeStart,
          rangeLength: resource.rangeLength,
        );
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return response;
        }
        lastError = HttpException('上游 HTTP ${response.statusCode}');
        if (response.statusCode < 500) break;
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('HLS 上游请求失败: ${lastError.runtimeType}');
  }

  Future<HlsStreamResponse> _fetchStream(
    _SessionData session,
    _Resource resource, {
    int? rangeStart,
    int? rangeLength,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final client = _upstream;
        final response = client is HlsStreamingUpstreamClient
            ? await (client as HlsStreamingUpstreamClient).stream(
                resource.uri,
                headers: _headersFor(session, resource.uri),
                rangeStart: rangeStart,
                rangeLength: rangeLength,
              )
            : await _streamFromBytes(
                client,
                resource.uri,
                _headersFor(session, resource.uri),
                rangeStart,
                rangeLength,
              );
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return response;
        }
        lastError = HttpException('上游 HTTP ${response.statusCode}');
        await response.cancel();
        if (response.statusCode < 500) break;
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('HLS 上游请求失败: ${lastError.runtimeType}');
  }

  Future<HlsStreamResponse> _streamFromBytes(
    HlsUpstreamClient client,
    Uri uri,
    Map<String, String> headers,
    int? rangeStart,
    int? rangeLength,
  ) async {
    final response = await client.get(
      uri,
      headers: headers,
      rangeStart: rangeStart,
      rangeLength: rangeLength,
    );
    return HlsStreamResponse(
      statusCode: response.statusCode,
      stream: Stream.value(response.bytes),
      headers: response.headers,
      cancel: () async {},
    );
  }

  _Resource _register(
    _SessionData session,
    Uri uri,
    _ResourceKind kind, {
    int? rangeStart,
    int? rangeLength,
    bool live = false,
  }) {
    final signature = '$kind\n$uri\n$rangeStart\n$rangeLength\n$live';
    final existingId = session.signatures[signature];
    if (existingId != null) return session.resources[existingId]!;
    final resource = _Resource(
      id: _randomId(),
      uri: uri,
      kind: kind,
      rangeStart: rangeStart,
      rangeLength: rangeLength,
      live: live,
    );
    session.signatures[signature] = resource.id;
    session.resources[resource.id] = resource;
    return resource;
  }

  Uri _validateUpstream(Uri uri) => _policy.validate(uri);

  /// 清单里的 URI 可以指向任意主机,而 [_SessionData.headers] 来自原始 track
  /// (可能带 Cookie / Authorization / Referer)。只有回源到同一主机时才带认证头,
  /// 否则一个被改写的清单就能把用户在原站的凭据送给第三方。
  Map<String, String> _headersFor(_SessionData session, Uri target) {
    if (target.host.toLowerCase() == session.originHost) return session.headers;
    return {
      for (final entry in session.headers.entries)
        if (!_credentialHeaders.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
  }

  Uri _localUri(String sessionId, String resourceId) => Uri.parse(
        'http://${InternetAddress.loopbackIPv4.address}:${_server!.port}/'
        '$sessionId/$resourceId',
      );

  String _randomId() => List.generate(
        16,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();

  Future<void> _closeSession(String id) async {
    final session = _sessions[id];
    if (session == null) return;
    session.closing = true;
    await session.prefetch;
    _sessions.remove(id);
    for (final bytes in session.keyBytes.values) {
      bytes.fillRange(0, bytes.length, 0);
    }
    session.keyBytes.clear();
    session.resources.clear();
    session.signatures.clear();
  }

  Future<void> close() async {
    for (final id in List<String>.of(_sessions.keys)) {
      await _closeSession(id);
    }
    await _subscription?.cancel();
    await _server?.close(force: true);
    await Future.wait(List<Future<void>>.of(_activeRequests));
    _subscription = null;
    _server = null;
  }

  Future<void> _writeResponse(
    HttpRequest request,
    List<int> bytes,
    String contentType,
  ) async {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = _contentTypeOrBinary(contentType);
    request.response.contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  }

  ContentType _contentTypeOrBinary(String value) {
    try {
      return ContentType.parse(value);
    } catch (_) {
      return ContentType.binary;
    }
  }

  Future<void> _respondError(
    HttpRequest request,
    int status,
    String message,
  ) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.text;
    request.response.write(message);
    await request.response.close();
  }
}

enum _ResourceKind { playlist, segment, init, key }

class _RequestedRange {
  const _RequestedRange(this.start, this.end);

  final int start;
  final int? end;
}

class _Resource {
  _Resource({
    required this.id,
    required this.uri,
    required this.kind,
    required this.rangeStart,
    required this.rangeLength,
    required this.live,
  });

  final String id;
  final Uri uri;
  final _ResourceKind kind;
  final int? rangeStart;
  final int? rangeLength;
  final bool live;
  List<String> prefetchIds = const [];
  String? forwardPrefetchId;
}

class _SessionData {
  _SessionData({
    required this.id,
    required this.headers,
    required this.authScope,
    required this.originHost,
  });

  final String id;
  final Map<String, String> headers;
  final String authScope;
  final String originHost;
  final Map<String, _Resource> resources = {};
  final Map<String, String> signatures = {};
  final Map<String, Uint8List> keyBytes = {};
  Future<void>? prefetch;
  bool closing = false;
  bool bufferHealthy = false;
  int prefetchGeneration = 0;
}
