enum HlsUriKind { segment, init, key }

class HlsByteRange {
  const HlsByteRange({required this.length, this.offset});

  final int length;
  final int? offset;
}

typedef HlsUriRegistrar = Uri Function(
  Uri upstream,
  HlsUriKind kind,
  HlsByteRange? range,
);

class HlsRewriteResult {
  const HlsRewriteResult({
    required this.text,
    required this.duration,
    required this.isLive,
  });

  final String text;
  final Duration duration;
  final bool isLive;
}

class UnsupportedHlsEncryption implements Exception {
  const UnsupportedHlsEncryption();
}

class HlsMediaRewriter {
  bool isLivePlaylist(String source) {
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    return !lines.any((line) {
      final upper = line.trim().toUpperCase();
      return upper == '#EXT-X-ENDLIST' ||
          upper.startsWith('#EXT-X-PLAYLIST-TYPE:VOD');
    });
  }

  HlsRewriteResult rewrite(
    String source, {
    required Uri baseUri,
    required HlsUriRegistrar register,
  }) {
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    final isLive = isLivePlaylist(source);
    final isVod = !isLive;
    final dateRangePairs = _scanDateRangePairs(lines);
    final canFilterAds = isVod &&
        dateRangePairs.valid &&
        _hasValidMarkerPairs(lines, dateRangePairs.pairedIds);
    final output = <String>[];
    var cueActive = false;
    var timedAdRemaining = 0.0;
    var needBoundary = false;
    var keptSegments = 0;
    var durationMicros = 0;
    var segmentDuration = 0.0;
    HlsByteRange? pendingRange;
    int? previousRangeEnd;

    bool filteringAd() => cueActive || timedAdRemaining > 0;

    void emit(String line) {
      if (needBoundary &&
          line.isNotEmpty &&
          line != '#EXT-X-ENDLIST' &&
          !line.startsWith('#EXT-X-CUE-') &&
          !line.startsWith('#EXT-X-SCTE35-')) {
        if (line != '#EXT-X-DISCONTINUITY') {
          output.add('#EXT-X-DISCONTINUITY');
        }
        needBoundary = false;
      }
      output.add(line);
    }

    for (final original in lines) {
      final trimmed = original.trim();
      final upper = trimmed.toUpperCase();

      if (canFilterAds) {
        final marker = _pairedMarker(trimmed, dateRangePairs.pairedIds);
        if (marker != null) {
          cueActive = marker.action == _AdMarkerAction.start;
          if (!cueActive && keptSegments > 0) needBoundary = true;
          continue;
        }
      }

      final timedDuration =
          canFilterAds ? _explicitTimedAdDuration(trimmed) : null;
      if (timedDuration != null) {
        timedAdRemaining = timedDuration;
        continue;
      }

      if (upper.startsWith('#EXTINF:')) {
        segmentDuration = _parseExtInf(trimmed);
        if (!filteringAd()) emit(original);
        continue;
      }

      if (upper.startsWith('#EXT-X-BYTERANGE:')) {
        pendingRange = _parseByteRange(
          trimmed.substring(trimmed.indexOf(':') + 1),
          implicitOffset: previousRangeEnd,
        );
        // 不透传:范围已经编进注册出来的本地 URI(网关按 rangeStart/rangeLength 回源),
        // 再留一行 BYTERANGE 会让播放器对着「已经切好的那一段」二次取偏移 —— 偏移叠加两次,
        // 得到 416 或错位数据。整段单文件 fMP4 的清单就是这么整集播不出来的。
        continue;
      }

      if (upper.startsWith('#EXT-X-MAP:')) {
        if (!filteringAd()) {
          final attributes =
              _attributes(trimmed.substring(trimmed.indexOf(':') + 1));
          final uriText = attributes['URI'];
          if (uriText == null) throw const FormatException('MAP 缺少 URI');
          final rangeText = attributes['BYTERANGE'];
          final range = rangeText == null ? null : _parseByteRange(rangeText);
          final local = register(
            _resolve(baseUri, uriText),
            HlsUriKind.init,
            range,
          );
          // 同 #EXT-X-BYTERANGE:本地 URI 已经只返回这一段,属性必须一起摘掉。
          emit(_removeByteRangeAttribute(
            _replaceUriAttribute(original, local.toString()),
          ));
        }
        continue;
      }

      if (upper.startsWith('#EXT-X-KEY:')) {
        if (!filteringAd()) {
          final attributes =
              _attributes(trimmed.substring(trimmed.indexOf(':') + 1));
          final method = (attributes['METHOD'] ?? '').toUpperCase();
          if (method == 'NONE') {
            emit(original);
            continue;
          }
          final keyFormat = attributes['KEYFORMAT'];
          if (method != 'AES-128' ||
              (keyFormat != null && keyFormat != 'identity')) {
            throw const UnsupportedHlsEncryption();
          }
          final uriText = attributes['URI'];
          if (uriText == null) throw const UnsupportedHlsEncryption();
          final local = register(
            _resolve(baseUri, uriText),
            HlsUriKind.key,
            null,
          );
          emit(_replaceUriAttribute(original, local.toString()));
        }
        continue;
      }

      if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
        final range = pendingRange;
        if (range != null && range.offset != null) {
          previousRangeEnd = range.offset! + range.length;
        }
        pendingRange = null;
        if (filteringAd()) {
          if (timedAdRemaining > 0) {
            timedAdRemaining -= segmentDuration;
            if (timedAdRemaining <= 0 && keptSegments > 0) {
              needBoundary = true;
            }
          }
          segmentDuration = 0;
          continue;
        }
        final local = register(
          _resolve(baseUri, trimmed),
          HlsUriKind.segment,
          range,
        );
        emit(local.toString());
        durationMicros +=
            (segmentDuration * Duration.microsecondsPerSecond).round();
        segmentDuration = 0;
        keptSegments++;
        continue;
      }

      if (!filteringAd()) emit(original);
    }

    return HlsRewriteResult(
      text: '${output.join('\n')}\n',
      duration: Duration(microseconds: durationMicros),
      isLive: isLive,
    );
  }

  bool _hasValidMarkerPairs(List<String> lines, Set<String> pairedDateRanges) {
    String? active;
    for (final line in lines) {
      final marker = _pairedMarker(line.trim(), pairedDateRanges);
      if (marker == null) continue;
      if (marker.action == _AdMarkerAction.start) {
        if (active != null) return false;
        active = marker.key;
      } else {
        if (active != marker.key) return false;
        active = null;
      }
    }
    return active == null;
  }

  _AdMarker? _pairedMarker(String line, Set<String> pairedDateRanges) {
    final upper = line.toUpperCase();
    if (upper.startsWith('#EXT-X-CUE-OUT')) {
      return const _AdMarker('cue', _AdMarkerAction.start);
    }
    if (upper.startsWith('#EXT-X-CUE-IN')) {
      return const _AdMarker('cue', _AdMarkerAction.end);
    }
    if (upper.startsWith('#EXT-X-SCTE35-OUT')) {
      return const _AdMarker('scte35', _AdMarkerAction.start);
    }
    if (upper.startsWith('#EXT-X-SCTE35-IN')) {
      return const _AdMarker('scte35', _AdMarkerAction.end);
    }
    if (!upper.startsWith('#EXT-X-DATERANGE:')) return null;
    final attributes = _attributes(line.substring(line.indexOf(':') + 1));
    final hasOut = attributes.containsKey('SCTE35-OUT');
    final hasIn = attributes.containsKey('SCTE35-IN');
    if (hasOut == hasIn) return null;
    final id = attributes['ID'];
    if (id == null || !pairedDateRanges.contains(id)) return null;
    return _AdMarker(
      'daterange:$id',
      hasOut ? _AdMarkerAction.start : _AdMarkerAction.end,
    );
  }

  _DateRangePairScan _scanDateRangePairs(List<String> lines) {
    final outIds = <String>{};
    final timedOutIds = <String>{};
    final inIds = <String>{};
    var valid = true;
    for (final line in lines) {
      final trimmed = line.trim();
      if (!trimmed.toUpperCase().startsWith('#EXT-X-DATERANGE:')) continue;
      final attributes =
          _attributes(trimmed.substring(trimmed.indexOf(':') + 1));
      final hasOut = attributes.containsKey('SCTE35-OUT');
      final hasIn = attributes.containsKey('SCTE35-IN');
      if (!hasOut && !hasIn) continue;
      if (hasOut && hasIn) continue;
      final id = attributes['ID'];
      if (id == null || id.isEmpty) {
        valid = false;
        continue;
      }
      if (hasOut) {
        if (!outIds.add(id)) valid = false;
        if (_durationAttribute(attributes) != null) timedOutIds.add(id);
      } else if (!inIds.add(id)) {
        valid = false;
      }
    }
    for (final id in inIds) {
      if (!outIds.contains(id)) valid = false;
    }
    for (final id in outIds) {
      if (!inIds.contains(id) && !timedOutIds.contains(id)) valid = false;
    }
    return _DateRangePairScan(
      valid: valid,
      pairedIds: outIds.intersection(inIds),
    );
  }

  double? _explicitTimedAdDuration(String line) {
    final upper = line.toUpperCase();
    if (!upper.startsWith('#EXT-X-DATERANGE:')) return null;
    final attributes = _attributes(line.substring(line.indexOf(':') + 1));
    final className = (attributes['CLASS'] ?? '').toLowerCase();
    final explicitClass = RegExp(
      r'(^|[^a-z0-9])(ad|ads|advert|advertisement|interstitial)($|[^a-z0-9])',
    ).hasMatch(className);
    if (!explicitClass && !attributes.containsKey('SCTE35-OUT')) {
      return null;
    }
    return _durationAttribute(attributes);
  }

  double? _durationAttribute(Map<String, String> attributes) => double.tryParse(
        attributes['DURATION'] ?? attributes['PLANNED-DURATION'] ?? '',
      );

  double _parseExtInf(String line) {
    final value = line.substring(line.indexOf(':') + 1).split(',').first;
    return double.tryParse(value) ?? 0;
  }

  HlsByteRange _parseByteRange(
    String value, {
    int? implicitOffset,
  }) {
    final parts = value.replaceAll('"', '').split('@');
    final length = int.parse(parts.first);
    final offset = parts.length > 1 ? int.parse(parts[1]) : implicitOffset;
    return HlsByteRange(length: length, offset: offset);
  }

  Map<String, String> _attributes(String source) {
    final result = <String, String>{};
    var index = 0;
    while (index < source.length) {
      while (index < source.length &&
          (source[index] == ',' || source[index].trim().isEmpty)) {
        index++;
      }
      final keyStart = index;
      while (index < source.length && source[index] != '=') {
        index++;
      }
      if (index >= source.length) break;
      final key = source.substring(keyStart, index).trim().toUpperCase();
      index++;
      late final String value;
      if (index < source.length && source[index] == '"') {
        index++;
        final valueStart = index;
        while (index < source.length && source[index] != '"') {
          index++;
        }
        value = source.substring(valueStart, index);
        if (index < source.length) index++;
      } else {
        final valueStart = index;
        while (index < source.length && source[index] != ',') {
          index++;
        }
        value = source.substring(valueStart, index).trim();
      }
      result[key] = value;
    }
    return result;
  }

  String _removeByteRangeAttribute(String line) => line
      .replaceAll(
        RegExp(r',\s*BYTERANGE=("[^"]*"|[^,]*)', caseSensitive: false),
        '',
      )
      .replaceAll(
        RegExp(r'(?<=:)\s*BYTERANGE=("[^"]*"|[^,]*),\s*', caseSensitive: false),
        '',
      );

  String _replaceUriAttribute(String line, String replacement) {
    final match =
        RegExp(r'URI=("[^"]*"|[^,]*)', caseSensitive: false).firstMatch(line);
    if (match == null) throw const FormatException('标签缺少 URI');
    return line.replaceRange(match.start, match.end, 'URI="$replacement"');
  }

  Uri _resolve(Uri baseUri, String value) {
    final uri = Uri.parse(value);
    return uri.hasScheme ? uri : baseUri.resolveUri(uri);
  }
}

enum _AdMarkerAction { start, end }

class _AdMarker {
  const _AdMarker(this.key, this.action);

  final String key;
  final _AdMarkerAction action;
}

class _DateRangePairScan {
  const _DateRangePairScan({required this.valid, required this.pairedIds});

  final bool valid;
  final Set<String> pairedIds;
}
