import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/library_store.dart';
import '../net/iam_auth.dart';
import '../source/source_repository.dart';
import 'hertz_backend.dart';
import 'sync_backend.dart';
import 'sync_data.dart';
import 'webdav_backend.dart';

/// 云同步控制器。两个可切换后端:
///   - `webdav`:WebDAV 文件(地址/账密)。
///   - `hertz` :自建账号服务 `dreamreader-sync`(IAM 登录 + ETag 乐观并发)。
///
/// 一次「同步」= 拉远端 → 与本地无损合并 → 应用到本地 → 推回远端。双向、不丢收藏/进度。
/// 配置(后端选择/WebDAV 账密/账号服务地址/自动开关/上次时间)存 SharedPreferences;
/// IAM 的 access/refresh token 由 [IamAuth] 存安全存储。
class SyncController extends ChangeNotifier {
  SyncController._();
  static final SyncController instance = SyncController._();

  // WebDAV
  static const _kUrl = 'sync.webdav.url';
  static const _kUser = 'sync.webdav.user';
  static const _kPass = 'sync.webdav.pass';
  // 通用
  static const _kAuto = 'sync.auto';
  static const _kLastAt = 'sync.lastAt';
  static const _kBackend = 'sync.backend';
  // 账号服务(hertz）
  static const _kHSyncUrl = 'sync.hertz.syncUrl';
  static const _kHIssuer = 'sync.hertz.issuer';
  static const _kHClientId = 'sync.hertz.clientId';
  static const _kHPreset = 'sync.hertz.preset';
  static const _kCategories = 'sync.categories';

  /// 后端类型:'webdav' | 'hertz'。
  String backendKind = 'webdav';

  // WebDAV 配置
  String url = '';
  String username = '';
  String password = '';

  // 账号服务配置
  String hertzSyncUrl = '';
  String hertzIssuer = '';
  String hertzClientId = 'dreamreader';

  /// 账号服务预设:'custom'(手填) | 'hertz'(官方 64hz 服务,地址锁定)。
  String hertzPreset = 'custom';

  /// 官方 Hertz Service 预设值(选中后三项锁定为此)。
  static const hzPresetSyncUrl = 'https://api.mr.64hz.cn';
  static const hzPresetIssuer = 'https://account.64hz.cn';
  static const hzPresetClientId = 'dream_manga_reader';

  bool auto = false;
  int lastSyncedAt = 0;

  /// 要同步的内容类别(默认全选)。两个后端共用。
  Set<SyncCategory> syncCategories = SyncCategory.values.toSet();

  bool _syncing = false;
  bool get syncing => _syncing;
  String status = '';

  IamAuth get auth => IamAuth.instance;

  bool get isHertz => backendKind == 'hertz';

  /// 当前后端是否已配置到可同步的程度。
  bool get configured => isHertz
      ? (hertzSyncUrl.trim().isNotEmpty && IamAuth.instance.isLoggedIn)
      : url.trim().isNotEmpty;

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<void> load() async {
    final p = await _p;
    backendKind = p.getString(_kBackend) ?? 'webdav';
    url = p.getString(_kUrl) ?? '';
    username = p.getString(_kUser) ?? '';
    password = p.getString(_kPass) ?? '';
    hertzSyncUrl = p.getString(_kHSyncUrl) ?? '';
    hertzIssuer = p.getString(_kHIssuer) ?? '';
    hertzClientId = p.getString(_kHClientId) ?? 'dreamreader';
    hertzPreset = p.getString(_kHPreset) ?? 'custom';
    // 预设为官方服务时地址以常量为准(即便旧值不同或常量随版本更新)。
    if (hertzPreset == 'hertz') {
      hertzSyncUrl = hzPresetSyncUrl;
      hertzIssuer = hzPresetIssuer;
      hertzClientId = hzPresetClientId;
    }
    auto = p.getBool(_kAuto) ?? false;
    lastSyncedAt = p.getInt(_kLastAt) ?? 0;
    final cats = p.getStringList(_kCategories);
    syncCategories = cats == null
        ? SyncCategory.values.toSet()
        : {
            for (final c in SyncCategory.values)
              if (cats.contains(c.name)) c
          };
    await IamAuth.instance.load(issuer: hertzIssuer, clientId: hertzClientId);
    notifyListeners();
  }

  Future<void> setBackendKind(String kind) async {
    if (kind != 'webdav' && kind != 'hertz') return;
    backendKind = kind;
    await (await _p).setString(_kBackend, kind);
    notifyListeners();
  }

  Future<void> setAuto(bool v) async {
    auto = v;
    await (await _p).setBool(_kAuto, v);
    notifyListeners();
  }

  /// 勾选/取消一个同步内容类别。
  Future<void> setSyncCategory(SyncCategory c, bool on) async {
    if (on) {
      syncCategories.add(c);
    } else {
      syncCategories.remove(c);
    }
    await (await _p)
        .setStringList(_kCategories, syncCategories.map((e) => e.name).toList());
    notifyListeners();
  }

  /// 保存 WebDAV 配置。
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
    final p = await _p;
    await p.setString(_kUrl, this.url);
    await p.setString(_kUser, this.username);
    await p.setString(_kPass, this.password);
    await p.setBool(_kAuto, this.auto);
    notifyListeners();
  }

  /// 保存账号服务配置(并同步更新 IamAuth 的 issuer/clientId)。
  Future<void> saveHertzConfig({
    required String syncUrl,
    required String issuer,
    required String clientId,
  }) async {
    hertzSyncUrl = syncUrl.trim();
    hertzIssuer = issuer.trim();
    hertzClientId = clientId.trim().isEmpty ? 'dreamreader' : clientId.trim();
    final p = await _p;
    await p.setString(_kHSyncUrl, hertzSyncUrl);
    await p.setString(_kHIssuer, hertzIssuer);
    await p.setString(_kHClientId, hertzClientId);
    IamAuth.instance.configure(issuer: hertzIssuer, clientId: hertzClientId);
    notifyListeners();
  }

  /// 切换账号服务预设。选官方服务(hertz)时锁定为常量地址并落盘。
  Future<void> setHertzPreset(String preset) async {
    if (preset != 'custom' && preset != 'hertz') return;
    hertzPreset = preset;
    await (await _p).setString(_kHPreset, preset);
    if (preset == 'hertz') {
      await saveHertzConfig(
        syncUrl: hzPresetSyncUrl,
        issuer: hzPresetIssuer,
        clientId: hzPresetClientId,
      );
    } else {
      notifyListeners();
    }
  }

  SyncBackend _backend() => isHertz
      ? HertzAccountBackend(baseUrl: hertzSyncUrl, auth: IamAuth.instance)
      : WebDavBackend(baseUrl: url, username: username, password: password);

  Future<(bool, String)> testConnection() => _backend().test();

  /// 双向同步一次。成功返回合并后条目概况;失败抛异常(带人话信息)。
  Future<String> syncNow(LibraryStore lib, SourceRepository repo) async {
    if (!configured) {
      throw Exception(isHertz ? '账号同步未就绪(先配地址并登录)' : '还没配置 WebDAV 地址');
    }
    if (syncCategories.isEmpty) throw Exception('至少选择一项要同步的内容');
    if (_syncing) throw Exception('正在同步中…');
    _syncing = true;
    status = '同步中…';
    notifyListeners();
    try {
      final sel = syncCategories;
      final backend = _backend();
      final local = SyncData.build(lib, repo, categories: sel);
      final remote = await backend.pull();
      var merged = remote == null ? local : SyncData.merge(local, remote);
      await SyncData.apply(merged, lib, repo, categories: sel);

      // 推回;账号后端可能因并发写入抛 SyncConflict → 与服务端最新态重合并后重试。
      var attempt = 0;
      while (true) {
        try {
          await backend.push(merged);
          break;
        } on SyncConflict catch (c) {
          if (++attempt > 3) {
            throw Exception('同步冲突,多次重试仍失败,请稍后再试');
          }
          if (c.remote != null) {
            merged = SyncData.merge(merged, c.remote!);
            await SyncData.apply(merged, lib, repo, categories: sel);
          }
        }
      }

      lastSyncedAt = (merged['syncedAt'] as num).toInt();
      await (await _p).setInt(_kLastAt, lastSyncedAt);
      final favN = ((merged['library'] as Map)['favorites'] as List?)?.length ?? 0;
      final hisN = ((merged['library'] as Map)['history'] as Map?)?.length ?? 0;
      status = '已同步 · 收藏 $favN · 进度 $hisN';
      return status;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// 启动时自动同步(开了自动 + 当前后端已就绪才跑);best-effort,失败只记状态不抛。
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
