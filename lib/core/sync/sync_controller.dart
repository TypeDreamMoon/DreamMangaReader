import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/library_store.dart';
import '../source/source_repository.dart';
import 'sync_data.dart';
import 'webdav_backend.dart';

/// 云同步控制器(目前后端=WebDAV,后续可加 IAM 账号后端)。
///
/// 一次「同步」= 拉远端 → 与本地无损合并 → 应用到本地 → 推回远端。双向、不丢收藏/进度。
/// 配置(WebDAV 地址/账密/自动开关/上次时间)存 SharedPreferences。
class SyncController extends ChangeNotifier {
  SyncController._();
  static final SyncController instance = SyncController._();

  static const _kUrl = 'sync.webdav.url';
  static const _kUser = 'sync.webdav.user';
  static const _kPass = 'sync.webdav.pass';
  static const _kAuto = 'sync.auto';
  static const _kLastAt = 'sync.lastAt';

  String url = '';
  String username = '';
  String password = '';
  bool auto = false;
  int lastSyncedAt = 0;

  bool _syncing = false;
  bool get syncing => _syncing;
  String status = '';

  bool get configured => url.trim().isNotEmpty;

  SharedPreferences? _prefs;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    url = _prefs!.getString(_kUrl) ?? '';
    username = _prefs!.getString(_kUser) ?? '';
    password = _prefs!.getString(_kPass) ?? '';
    auto = _prefs!.getBool(_kAuto) ?? false;
    lastSyncedAt = _prefs!.getInt(_kLastAt) ?? 0;
    notifyListeners();
  }

  Future<void> saveConfig({
    required String url,
    required String username,
    required String password,
    required bool auto,
  }) async {
    this.url = url.trim();
    this.username = username.trim();
    this.password = password;
    this.auto = auto;
    final p = _prefs ??= await SharedPreferences.getInstance();
    await p.setString(_kUrl, this.url);
    await p.setString(_kUser, this.username);
    await p.setString(_kPass, this.password);
    await p.setBool(_kAuto, this.auto);
    notifyListeners();
  }

  WebDavBackend _backend() =>
      WebDavBackend(baseUrl: url, username: username, password: password);

  Future<(bool, String)> testConnection() => _backend().test();

  /// 双向同步一次。成功返回合并后条目概况;失败抛异常(带人话信息)。
  Future<String> syncNow(LibraryStore lib, SourceRepository repo) async {
    if (!configured) throw Exception('还没配置 WebDAV 地址');
    if (_syncing) throw Exception('正在同步中…');
    _syncing = true;
    status = '同步中…';
    notifyListeners();
    try {
      final backend = _backend();
      final local = SyncData.build(lib, repo);
      final remote = await backend.pull();
      final merged = remote == null ? local : SyncData.merge(local, remote);
      await SyncData.apply(merged, lib, repo);
      await backend.push(merged);
      lastSyncedAt = (merged['syncedAt'] as num).toInt();
      await (_prefs ??= await SharedPreferences.getInstance())
          .setInt(_kLastAt, lastSyncedAt);
      final favN = ((merged['library'] as Map)['favorites'] as List?)?.length ?? 0;
      final hisN = ((merged['library'] as Map)['history'] as Map?)?.length ?? 0;
      status = '已同步 · 收藏 $favN · 进度 $hisN';
      return status;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// 启动时自动同步(开了自动 + 配了才跑);best-effort,失败只记状态不抛。
  Future<void> autoSyncOnStart(LibraryStore lib, SourceRepository repo) async {
    if (!auto || !configured) return;
    try {
      await syncNow(lib, repo);
    } catch (e) {
      status = '自动同步失败:$e';
      notifyListeners();
    }
  }
}
