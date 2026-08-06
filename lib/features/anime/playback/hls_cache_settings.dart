import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hls_cache_gateway.dart';
import 'hls_cache_store.dart';

enum HlsCacheLimit {
  off(0),
  mib256(256 * 1024 * 1024),
  mib512(512 * 1024 * 1024),
  gib1(1024 * 1024 * 1024);

  const HlsCacheLimit(this.bytes);

  static const defaultValue = HlsCacheLimit.mib512;

  final int bytes;
}

typedef HlsCacheDirectoryProvider = Future<Directory> Function();
typedef HlsCachePreferencesProvider = Future<SharedPreferences> Function();

abstract interface class VideoCacheSettingsController {
  HlsCacheLimit get limit;
  Future<void> initialize();
  Future<void> setLimit(HlsCacheLimit value);
  Future<int> sizeBytes();
  Future<void> clear();
}

class HlsCacheController implements VideoCacheSettingsController {
  HlsCacheController({
    HlsCacheDirectoryProvider? directoryProvider,
    HlsCachePreferencesProvider? preferencesProvider,
    HlsUpstreamClient? upstream,
  })  : _directoryProvider = directoryProvider ?? _defaultDirectory,
        _preferencesProvider =
            preferencesProvider ?? SharedPreferences.getInstance,
        _upstream = upstream ?? DioHlsUpstreamClient(Dio());

  static final HlsCacheController instance = HlsCacheController();
  static const _limitKey = 'anime.hlsCacheLimit';

  final HlsCacheDirectoryProvider _directoryProvider;
  final HlsCachePreferencesProvider _preferencesProvider;
  final HlsUpstreamClient _upstream;
  HlsCacheLimit _limit = HlsCacheLimit.defaultValue;
  HlsCacheStore? _cache;
  HlsCacheGateway? _gateway;
  Future<void>? _initializing;

  @override
  HlsCacheLimit get limit => _limit;

  HlsCacheStore get cache {
    final value = _cache;
    if (value == null) throw StateError('视频缓存尚未初始化');
    return value;
  }

  HlsCacheGateway get gateway {
    final value = _gateway;
    if (value == null) throw StateError('视频缓存尚未初始化');
    return value;
  }

  @override
  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    final values = await Future.wait([
      _preferencesProvider(),
      _directoryProvider(),
    ]);
    final preferences = values[0] as SharedPreferences;
    final stored = preferences.getString(_limitKey);
    _limit = HlsCacheLimit.values.firstWhere(
      (value) => value.name == stored,
      orElse: () => HlsCacheLimit.defaultValue,
    );
    final store = HlsCacheStore(
      directory: values[1] as Directory,
      limitBytes: _limit.bytes,
    );
    await store.initialize();
    _cache = store;
    _gateway = HlsCacheGateway(cache: store, upstream: _upstream);
  }

  @override
  Future<void> setLimit(HlsCacheLimit value) async {
    await initialize();
    await cache.setLimitBytes(value.bytes);
    final preferences = await _preferencesProvider();
    await preferences.setString(_limitKey, value.name);
    _limit = value;
  }

  @override
  Future<int> sizeBytes() async {
    await initialize();
    return cache.sizeBytes();
  }

  @override
  Future<void> clear() async {
    await initialize();
    await cache.clear();
  }

  Future<void> close() async {
    await _gateway?.close();
    _gateway = null;
  }

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(
      '${support.path}${Platform.pathSeparator}anime-hls-cache',
    );
  }
}
