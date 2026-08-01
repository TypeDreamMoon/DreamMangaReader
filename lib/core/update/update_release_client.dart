import 'dart:convert';

import 'package:dio/dio.dart';

import 'update_models.dart';

const updateManifestAssetName = 'dream-manga-reader-update.json';

class UpdateSourceException implements Exception {
  const UpdateSourceException(
    this.source,
    this.message, {
    this.statusCode,
    this.cause,
  });

  final UpdateSource source;
  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() => '${source.displayName}: $message'
      '${statusCode == null ? '' : ' (HTTP $statusCode)'}';
}

abstract interface class UpdateReleaseClient {
  UpdateSource get source;

  Future<List<RemoteRelease>> listReleases();

  Future<RemoteRelease> loadAssets(RemoteRelease release);

  Future<UpdateManifest> fetchManifest(RemoteRelease release);
}

abstract class _DioReleaseClient implements UpdateReleaseClient {
  _DioReleaseClient(Dio? dio)
      : dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 12),
              validateStatus: (_) => true,
            ));

  final Dio dio;

  Future<Response<dynamic>> get(String url,
      {Map<String, dynamic>? queryParameters}) async {
    try {
      final response = await dio.get<dynamic>(
        url,
        queryParameters: queryParameters,
      );
      if (response.statusCode != 200) {
        throw UpdateSourceException(
          source,
          'Release request failed',
          statusCode: response.statusCode,
        );
      }
      return response;
    } on UpdateSourceException {
      rethrow;
    } on DioException catch (error) {
      throw UpdateSourceException(
        source,
        'Release request failed',
        statusCode: error.response?.statusCode,
        cause: error,
      );
    } catch (error) {
      throw UpdateSourceException(
        source,
        'Invalid Release response',
        cause: error,
      );
    }
  }

  @override
  Future<UpdateManifest> fetchManifest(RemoteRelease release) async {
    final loaded = await loadAssets(release);
    RemoteAsset? manifestAsset;
    for (final asset in loaded.assets) {
      if (asset.name.toLowerCase() == updateManifestAssetName) {
        manifestAsset = asset;
        break;
      }
    }
    if (manifestAsset == null) {
      throw UpdateSourceException(source, 'Release is missing update manifest');
    }

    final response = await get(manifestAsset.url);
    try {
      final data = response.data;
      final decoded = data is String ? jsonDecode(data) : data;
      if (decoded is! Map) {
        throw const FormatException('Invalid update manifest response');
      }
      final manifest =
          UpdateManifest.fromJson(Map<String, dynamic>.from(decoded));
      final platforms = manifest.assets.map((asset) => asset.platform).toSet();
      for (final platform in platforms) {
        manifest.resolve(platform, loaded.assets);
      }
      return manifest;
    } on FormatException catch (error) {
      throw UpdateSourceException(
        source,
        'Invalid update manifest',
        cause: error,
      );
    }
  }

  static List<RemoteAsset> parseAssets(Object? rawAssets) {
    if (rawAssets is! List) return const [];
    final assets = <RemoteAsset>[];
    for (final raw in rawAssets) {
      if (raw is! Map) continue;
      final json = Map<String, dynamic>.from(raw);
      final name = json['name'];
      final url = json['browser_download_url'];
      final size = json['size'];
      if (name is String &&
          name.isNotEmpty &&
          url is String &&
          url.isNotEmpty &&
          size is int &&
          size > 0) {
        assets.add(RemoteAsset(name: name, url: url, size: size));
      }
    }
    return List.unmodifiable(assets);
  }
}

class GitHubReleaseClient extends _DioReleaseClient {
  GitHubReleaseClient({Dio? dio}) : super(dio) {
    this.dio.options.headers.addAll(const {
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'DreamMangaReader-UpdateCheck',
    });
  }

  static const releasesUrl =
      'https://api.github.com/repos/TypeDreamMoon/DreamMangaReader/releases';

  @override
  UpdateSource get source => UpdateSource.github;

  static RemoteRelease parseRelease(Map<String, dynamic> json) {
    final tag = json['tag_name'];
    final pageUrl = json['html_url'];
    if (tag is! String ||
        tag.isEmpty ||
        pageUrl is! String ||
        pageUrl.isEmpty) {
      throw const FormatException('Invalid GitHub Release');
    }
    return RemoteRelease(
      source: UpdateSource.github,
      tag: tag,
      pageUrl: pageUrl,
      notes: json['body'] is String ? json['body'] as String : '',
      prerelease: json['prerelease'] == true,
      assets: _DioReleaseClient.parseAssets(json['assets']),
    );
  }

  static List<RemoteRelease> parseReleaseList(Object? data) {
    if (data is! List) throw const FormatException('Invalid GitHub list');
    final releases = <RemoteRelease>[];
    for (final raw in data) {
      if (raw is! Map || raw['draft'] == true) continue;
      try {
        releases.add(parseRelease(Map<String, dynamic>.from(raw)));
      } on FormatException {
        continue;
      }
    }
    return List.unmodifiable(releases);
  }

  @override
  Future<List<RemoteRelease>> listReleases() async {
    final response =
        await get(releasesUrl, queryParameters: const {'per_page': 20});
    try {
      return parseReleaseList(response.data);
    } on FormatException catch (error) {
      throw UpdateSourceException(source, 'Invalid Release list', cause: error);
    }
  }

  @override
  Future<RemoteRelease> loadAssets(RemoteRelease release) async => release;
}

class GiteeReleaseClient extends _DioReleaseClient {
  GiteeReleaseClient({Dio? dio}) : super(dio) {
    this.dio.options.headers['User-Agent'] = 'DreamMangaReader-UpdateCheck';
  }

  static const releasesUrl =
      'https://gitee.com/api/v5/repos/TypeDreamMoon/DreamMangaReader/releases';
  final Map<String, int> _releaseIds = {};

  @override
  UpdateSource get source => UpdateSource.gitee;

  static RemoteRelease parseRelease(
    Map<String, dynamic> json,
    Object? attachFiles,
  ) {
    final tag = json['tag_name'];
    if (tag is! String || tag.isEmpty || json['id'] is! int) {
      throw const FormatException('Invalid Gitee Release');
    }
    return RemoteRelease(
      source: UpdateSource.gitee,
      tag: tag,
      pageUrl:
          'https://gitee.com/TypeDreamMoon/DreamMangaReader/releases/tag/${Uri.encodeComponent(tag)}',
      notes: json['body'] is String ? json['body'] as String : '',
      prerelease: json['prerelease'] == true,
      assets: _DioReleaseClient.parseAssets(attachFiles),
    );
  }

  @override
  Future<List<RemoteRelease>> listReleases() async {
    final response = await get(
      releasesUrl,
      queryParameters: const {'per_page': 20, 'direction': 'desc'},
    );
    final data = response.data;
    if (data is! List) {
      throw UpdateSourceException(source, 'Invalid Release list');
    }
    final releases = <RemoteRelease>[];
    for (final raw in data) {
      if (raw is! Map) continue;
      final json = Map<String, dynamic>.from(raw);
      try {
        final release = parseRelease(json, const []);
        _releaseIds[release.tag] = json['id'] as int;
        releases.add(release);
      } on FormatException {
        continue;
      }
    }
    return List.unmodifiable(releases);
  }

  @override
  Future<RemoteRelease> loadAssets(RemoteRelease release) async {
    if (release.assets.isNotEmpty) return release;
    final id = _releaseIds[release.tag];
    if (id == null) {
      throw UpdateSourceException(source, 'Unknown Gitee Release id');
    }
    final response = await get('$releasesUrl/$id/attach_files',
        queryParameters: const {'per_page': 100});
    return RemoteRelease(
      source: release.source,
      tag: release.tag,
      pageUrl: release.pageUrl,
      notes: release.notes,
      prerelease: release.prerelease,
      assets: _DioReleaseClient.parseAssets(response.data),
    );
  }
}
