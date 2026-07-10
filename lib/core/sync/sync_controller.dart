import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/library_store.dart';
import '../log/app_log.dart';
import '../net/iam_auth.dart';
import '../source/source_registry.dart' show registeredSources;
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
  static const _kAutoUpFav = 'sync.autoUploadOnFavorite'; // 旧布尔开关(已并入 _kAutoUpOn)
  static const _kAutoUpOn = 'sync.autoUploadOn';
  static const _kAutoUpBase = 'sync.autoUploadBase'; // 各类别基线签名(跨启动)
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
  String hertzPreset = 'hertz';

  /// 官方 Hertz Service 预设值(选中后三项锁定为此)。
  static const hzPresetSyncUrl = 'https://api.mr.64hz.cn';
  static const hzPresetIssuer = 'https://account.64hz.cn';
  static const hzPresetClientId = 'dream_manga_reader';

  bool auto = false;

  /// 「变化后自动上传」勾选的类别:本机该类内容变化后去抖自动上传到云端。
  Set<SyncCategory> autoUploadOn = {};

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
    final upCats = p.getStringList(_kAutoUpOn);
    autoUploadOn = upCats == null
        ? <SyncCategory>{}
        : {
            for (final c in SyncCategory.values)
              if (upCats.contains(c.name)) c
          };
    // 迁移旧的「收藏后自动上传」布尔开关 → 类别集合。
    if (p.getBool(_kAutoUpFav) == true) {
      autoUploadOn.add(SyncCategory.favorites);
      await p.remove(_kAutoUpFav);
      await p.setStringList(
          _kAutoUpOn, [for (final c in autoUploadOn) c.name]);
    }
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

  /// 勾选/取消某类别的「变化后自动上传」。全取消时连带取消还没触发的上传。
  Future<void> setAutoUploadOn(SyncCategory c, bool on) async {
    if (on) {
      autoUploadOn.add(c);
    } else {
      autoUploadOn.remove(c);
    }
    if (autoUploadOn.isEmpty) {
      _upTimer?.cancel();
      _upTimer = null;
    } else if (on) {
      _onLocalChanged(); // 刚勾上 → 把开启前积累的变化也检查/传一次
    }
    await (await _p)
        .setStringList(_kAutoUpOn, [for (final x in autoUploadOn) x.name]);
    notifyListeners();
  }

  // ---- 变化后自动上传:监听本地数据 → 按类别签名比对 → 去抖上传变了的类别 ----
  //
  // 一处引擎覆盖所有「需要同步的地方」:收藏/进度/设置(书架 store 的一切)走
  // LibraryStore 的通知;源脚本与源仓库配置走 SourceRepository.onChanged 钩子。
  // 云同步/下载写回本地也会触发通知,但同步成功后会用「写回时刻」的签名重置基线,
  // 签名对得上就不会自己触发自己(不回环)。基线跨启动持久化:退出前没来得及传的
  // 变化(还在去抖/节流窗口里),下次启动能对出差异接着传,不会被吞。

  LibraryStore? _upLib;
  SourceRepository? _upRepo;
  Timer? _upTimer;
  int _upTimerDueAt = 0; // 当前定时器到点时刻(比较「谁更早」用)
  int _upFirstDirtyAt = 0; // 本轮连续变化的起点(去抖上限用;0=没有待查变化)
  int _upFailAt = 0; // 上次自动上传失败时刻(退避 1 分钟,别在断网时每 20 秒重试)
  final Map<SyncCategory, String> _upBase = {}; // 各类别云端已知状态的本地签名(基线)
  final Map<SyncCategory, int> _upLastAt = {}; // 各类别上次自动上传时刻(节流)

  static const _upDebounceMs = 5000;

  /// 去抖上限:连续变化(阅读翻页每几秒一次)会不断顺延 5 秒去抖,最多顺延到
  /// 首次变化后 20 秒——保证检查照样跑,阅读中进度照样按节流间隔上传。
  static const _upMaxWaitMs = 20000;

  /// 高频类别的最小上传间隔:阅读进度逐页更新,阅读中最快每 2 分钟传一次,
  /// 停止翻页后由去抖兜底把最终进度传上去。其余类别变化即传。
  static const _upMinGapMs = {SyncCategory.history: 120000};

  /// app 启动(书架读档完成后)挂上变化监听。基线优先用上次持久化的(能接着传
  /// 上次退出前漏掉的变化);首次使用则取挂载时刻的本地状态。
  Future<void> attachAutoUpload(LibraryStore lib, SourceRepository repo) async {
    _upLib = lib;
    _upRepo = repo;
    final saved = (await _p).getStringList(_kAutoUpBase) ?? const [];
    final savedMap = <String, String>{
      for (final s in saved)
        if (s.contains('=')) s.substring(0, s.indexOf('=')): s.substring(s.indexOf('=') + 1)
    };
    final cur = _localSigs(SyncCategory.values.toSet());
    _upBase.clear();
    for (final c in SyncCategory.values) {
      _upBase[c] = savedMap[c.name] ?? cur[c]!;
    }
    lib.addListener(_onLocalChanged);
    repo.onChanged = _onLocalChanged;
    if (savedMap.isEmpty) {
      _persistBase(); // 首次:把当前基线落盘
    } else {
      _onLocalChanged(); // 有历史基线 → 启动就检查一次,补传上次退出前的变化
    }
  }

  void _onLocalChanged() {
    if (autoUploadOn.isEmpty || !configured) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_upFirstDirtyAt == 0) _upFirstDirtyAt = now;
    // 去抖 5 秒,但连续变化最多顺延到首次变化后 [_upMaxWaitMs],别把检查饿死。
    var due = now + _upDebounceMs;
    final cap = _upFirstDirtyAt + _upMaxWaitMs;
    if (cap < due) due = cap;
    _armAt(due, keepEarlier: false);
  }

  /// 把检查定时器定到 [dueMs]。[keepEarlier]=true 时若已有更早的定时器则不动它
  /// (节流补查/重试用,别把「变化 5 秒即查」的近期定时器顶掉)。
  void _armAt(int dueMs, {required bool keepEarlier}) {
    if (keepEarlier && _upTimer != null && _upTimerDueAt <= dueMs) return;
    _upTimer?.cancel();
    _upTimerDueAt = dueMs;
    final delta = dueMs - DateTime.now().millisecondsSinceEpoch;
    _upTimer =
        Timer(Duration(milliseconds: delta < 0 ? 0 : delta), _autoUploadCheck);
  }

  Future<void> _autoUploadCheck() async {
    _upTimer = null;
    _upFirstDirtyAt = 0; // 本轮检查消化当前积累;之后的新变化重新起算
    final lib = _upLib;
    final repo = _upRepo;
    if (lib == null || repo == null) return;
    if (autoUploadOn.isEmpty || !configured) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_syncing) {
      _armAt(now + _upDebounceMs, keepEarlier: true); // 撞上进行中的同步 → 再等一轮
      return;
    }
    if (now - _upFailAt < 60000) {
      _armAt(_upFailAt + 60250, keepEarlier: true); // 刚失败过 → 退避 1 分钟再试
      return;
    }
    final sigs = _localSigs(autoUploadOn);
    final changed = <SyncCategory>{
      for (final e in sigs.entries)
        if (_upBase[e.key] != e.value) e.key
    };
    if (changed.isEmpty) return;
    // 高频类别(进度)节流:没到最小间隔的先攒着,到点再传。
    final ready = <SyncCategory>{
      for (final c in changed)
        if (now - (_upLastAt[c] ?? 0) >= (_upMinGapMs[c] ?? 0)) c
    };
    if (ready.isNotEmpty) {
      try {
        AppLog.i.info(
            LogCat.sync, '本地变化 · 自动上传 ${ready.map((c) => c.name).join(', ')}');
        // 基线由 uploadNow 用「打快照时刻」的签名重置,上传期间的新变化下轮还能测到。
        await uploadNow(lib, repo, categories: ready);
        _upFailAt = 0;
        for (final c in ready) {
          _upLastAt[c] = now;
        }
      } catch (e) {
        // 失败退避 1 分钟(uploadNow 已记日志);之后本地变化/补查会自然重试。
        _upFailAt = DateTime.now().millisecondsSinceEpoch;
        status = '自动上传失败:$e';
        notifyListeners();
      }
    }
    // 被节流攒下的类别:按剩余等待时间补一次检查(取更早的定时器,别顶掉新变化的 5 秒查)。
    final deferred = changed.difference(ready);
    if (deferred.isNotEmpty) {
      final now2 = DateTime.now().millisecondsSinceEpoch;
      var wait = 0;
      for (final c in deferred) {
        final left = (_upMinGapMs[c] ?? 0) - (now2 - (_upLastAt[c] ?? 0));
        if (left > 0 && (wait == 0 || left < wait)) wait = left;
      }
      _armAt(now2 + wait + 250, keepEarlier: true);
    }
  }

  /// 同步/上传/下载把本地与云端对齐后,用**对齐时刻**(打快照/写回完成时)的签名
  /// 重置基线——期间又发生的本地变化签名对不上,下轮检查照样能传,不会被吞。
  void _rebaselineWith(Map<SyncCategory, String> sigs) {
    if (sigs.isEmpty) return;
    _upBase.addAll(sigs);
    _persistBase();
  }

  void _persistBase() {
    _p.then((p) => p.setStringList(_kAutoUpBase,
        [for (final e in _upBase.entries) '${e.key.name}=${e.value}']));
  }

  /// 各类别当前本地状态的**短签名**(变了 = 签名不同)。长度 + FNV-1a 哈希:
  /// 跨进程稳定(String.hashCode 不保证跨启动一致),且短到可以随基线落盘。
  static String _sig(String s) {
    var h = 0x811c9dc5;
    for (var i = 0; i < s.length; i++) {
      h = ((h ^ s.codeUnitAt(i)) * 0x01000193) & 0xFFFFFFFF;
    }
    return '${s.length}:${h.toRadixString(16)}';
  }

  /// 设置类别的键归类沿用 [SyncData.isSettingsKey];源类别看「禁用列表 +
  /// 每个源的 meta(名称/开关/防盗链等,同步载荷里都带)+ 脚本内容」。
  Map<SyncCategory, String> _localSigs(Set<SyncCategory> cats) {
    final lib = _upLib;
    final repo = _upRepo;
    if (lib == null || repo == null) return const {};
    final full = lib.exportData();
    String enc(Object? v) => _sig(jsonEncode(v ?? ''));
    String srcSig(bool anime) {
      final disabled = ((full['disabledSources'] as List?) ?? const [])
          .map((e) => e.toString())
          .where((id) => _srcIsAnime(id) == anime)
          .toList()
        ..sort();
      final scripts = [
        for (final m in registeredSources)
          if (m.isAnime == anime)
            '${m.id}:${m.name}:${m.kind}:${m.experimental}:${m.useWebView}:'
                '${m.imageReferer}:${m.needsLogin}:${_sig(m.script)}'
      ]..sort();
      return _sig('${disabled.join(',')}|${scripts.join(',')}');
    }

    final out = <SyncCategory, String>{};
    for (final c in cats) {
      out[c] = switch (c) {
        SyncCategory.favorites => enc(full['favorites']),
        SyncCategory.history =>
          _sig('${enc(full['history'])}|${enc(full['workProgress'])}'),
        SyncCategory.settings => enc({
            for (final e in full.entries)
              if (SyncData.isSettingsKey(e.key)) e.key: e.value
          }),
        SyncCategory.mangaSources => srcSig(false),
        SyncCategory.animeSources => srcSig(true),
        SyncCategory.sourceRepo =>
          _sig('${repo.repoUrl ?? ''}|${repo.localDir ?? ''}|${repo.token ?? ''}'),
      };
    }
    return out;
  }

  static bool _srcIsAnime(String id) {
    for (final m in registeredSources) {
      if (m.id == id) return m.isAnime;
    }
    return false;
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
    AppLog.i.info(LogCat.sync, '开始同步 · ${_catLabel(syncCategories)}');
    final sw = Stopwatch()..start();
    try {
      final sel = syncCategories;
      final applyModes = {for (final c in sel) c: false}; // 自动同步:合并后整份覆盖本地
      final backend = _backend();
      AppLog.i.debug(LogCat.sync, '后端 $_backendLabel · 类别 ${_catLabel(sel)}',
          detail: '类别:${sel.map((c) => c.name).join(', ')}');
      final local = SyncData.build(lib, repo, categories: sel);
      AppLog.i.debug(LogCat.sync, '本地快照 · ${_dataSummary(local)}');
      final remote = await backend.pull();
      AppLog.i.debug(LogCat.sync,
          remote == null ? '拉取远端 · 无数据(首次同步)' : '拉取远端 · ${_dataSummary(remote)}');
      var merged = remote == null ? local : SyncData.merge(local, remote);
      if (remote != null) {
        AppLog.i.debug(LogCat.sync, '合并本地+远端 · ${_dataSummary(merged)}');
      }
      await SyncData.apply(merged, lib, repo, modes: applyModes);
      AppLog.i.debug(LogCat.sync, '已应用合并结果到本地');
      // 基线签名取「写回完成时刻」:推送期间的新变化对不上签名,之后照样能自动上传。
      var preSigs = _localSigs(sel);

      // 推回;账号后端可能因并发写入抛 SyncConflict → 与服务端最新态重合并后重试。
      var attempt = 0;
      while (true) {
        try {
          await backend.push(merged);
          AppLog.i.debug(LogCat.sync,
              attempt == 0 ? '已推送到远端' : '重试推送成功(第 ${attempt + 1} 次)');
          break;
        } on SyncConflict catch (c) {
          if (++attempt > 3) {
            throw Exception('同步冲突,多次重试仍失败,请稍后再试');
          }
          AppLog.i.warn(LogCat.sync, '推送遇并发冲突,重合并后重试(第 $attempt 次)');
          if (c.remote != null) {
            merged = SyncData.merge(merged, c.remote!);
            await SyncData.apply(merged, lib, repo, modes: applyModes);
            preSigs = _localSigs(sel);
          }
        }
      }

      lastSyncedAt = (merged['syncedAt'] as num).toInt();
      await (await _p).setInt(_kLastAt, lastSyncedAt);
      _rebaselineWith(preSigs); // 合并结果已两边一致,别让「同步写回」再触发自动上传
      final favN = ((merged['library'] as Map)['favorites'] as List?)?.length ?? 0;
      final hisN = ((merged['library'] as Map)['history'] as Map?)?.length ?? 0;
      status = '已同步 · 收藏 $favN · 进度 $hisN';
      AppLog.i.success(LogCat.sync, '$status · ${sw.elapsedMilliseconds}ms');
      return status;
    } catch (e) {
      AppLog.i.err(LogCat.sync, '同步失败', detail: '$e');
      rethrow;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// 上传:本地所选类别 → 服务器(覆盖服务器上对应类别,保留其它未选类别)。
  /// [categories] 不传 = 用设置里勾选的 [syncCategories];自动上传只传变化的类别。
  Future<String> uploadNow(LibraryStore lib, SourceRepository repo,
      {Set<SyncCategory>? categories}) async {
    final cats = categories ?? syncCategories;
    if (!configured) {
      throw Exception(isHertz ? '账号同步未就绪(先配地址并登录)' : '还没配置 WebDAV 地址');
    }
    if (cats.isEmpty) throw Exception('至少选择一项要同步的内容');
    if (_syncing) throw Exception('正在同步中…');
    _syncing = true;
    status = '上传中…';
    notifyListeners();
    AppLog.i.info(LogCat.sync, '开始上传 · ${_catLabel(cats)}');
    final sw = Stopwatch()..start();
    try {
      final backend = _backend();
      AppLog.i.debug(LogCat.sync, '后端 $_backendLabel · 覆盖上传 ${_catLabel(cats)}',
          detail: '类别:${cats.map((c) => c.name).join(', ')}');
      final local = SyncData.build(lib, repo, categories: cats);
      // 基线签名与快照同刻采集:推送期间的新变化对不上签名,之后照样能自动上传。
      final preSigs = _localSigs(cats);
      AppLog.i.debug(LogCat.sync, '本地快照 · ${_dataSummary(local)}');
      final remote = await backend.pull();
      AppLog.i.debug(LogCat.sync,
          remote == null ? '拉取远端 · 无数据' : '拉取远端(保留未选类别)· ${_dataSummary(remote)}');
      var toPush = remote == null ? local : SyncData.overlay(remote, local);
      var attempt = 0;
      while (true) {
        try {
          await backend.push(toPush);
          AppLog.i.debug(LogCat.sync,
              attempt == 0 ? '已覆盖上传到远端' : '重试上传成功(第 ${attempt + 1} 次)');
          break;
        } on SyncConflict catch (c) {
          if (++attempt > 3) throw Exception('上传冲突,多次重试仍失败,请稍后再试');
          AppLog.i.warn(LogCat.sync, '上传遇并发冲突,重叠加后重试(第 $attempt 次)');
          toPush = c.remote == null ? local : SyncData.overlay(c.remote!, local);
        }
      }
      await _stampSynced();
      _rebaselineWith(preSigs); // 云端此刻 = 快照时刻的本地态
      status = '已上传 · ${_catLabel(cats)}';
      AppLog.i.success(LogCat.sync, '$status · ${sw.elapsedMilliseconds}ms');
      return status;
    } catch (e) {
      AppLog.i.err(LogCat.sync, '上传失败', detail: '$e');
      rethrow;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// 下载:服务器 → 本地。[modes] 逐类别指定方式(false=覆盖 · true=追加;不在 map=不下载)。
  Future<String> downloadNow(
    LibraryStore lib,
    SourceRepository repo, {
    required Map<SyncCategory, bool> modes,
  }) async {
    if (!configured) {
      throw Exception(isHertz ? '账号同步未就绪(先配地址并登录)' : '还没配置 WebDAV 地址');
    }
    if (modes.isEmpty) throw Exception('至少选择一项要下载的内容');
    if (_syncing) throw Exception('正在同步中…');
    _syncing = true;
    status = '下载中…';
    notifyListeners();
    AppLog.i.info(LogCat.sync, '开始从云端下载 · ${modes.length} 项');
    final sw = Stopwatch()..start();
    try {
      final backend = _backend();
      final modeText = modes.entries
          .map((e) => '${e.key.name}(${e.value ? '追加' : '覆盖'})')
          .join(', ');
      AppLog.i.debug(LogCat.sync, '后端 $_backendLabel · 下载 ${modes.length} 项',
          detail: modeText);
      final remote = await backend.pull();
      if (remote == null) {
        status = '服务器暂无数据';
        AppLog.i.warn(LogCat.sync, '云端下载:$status');
        return status;
      }
      AppLog.i.debug(LogCat.sync, '拉取远端 · ${_dataSummary(remote)},开始写入本地');
      await SyncData.apply(remote, lib, repo, modes: modes);
      AppLog.i.debug(LogCat.sync, '已写入本地(${modes.length} 项)');
      final preSigs = _localSigs(modes.keys.toSet()); // 写回完成时刻的签名
      await _stampSynced();
      _rebaselineWith(preSigs); // 下载写回的内容不算「本地新变化」
      status = '已下载 · ${modes.length} 项';
      AppLog.i.success(LogCat.sync, '云端$status · ${sw.elapsedMilliseconds}ms');
      return status;
    } catch (e) {
      AppLog.i.err(LogCat.sync, '云端下载失败', detail: '$e');
      rethrow;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> _stampSynced() async {
    lastSyncedAt = DateTime.now().millisecondsSinceEpoch;
    await (await _p).setInt(_kLastAt, lastSyncedAt);
  }

  static String _catLabel(Set<SyncCategory> c) =>
      '${c.length} 项';

  // 日志用:后端名 + 快照内容摘要(收藏/历史条数、是否含源仓库配置)。
  String get _backendLabel => isHertz ? '账号(Hertz)' : 'WebDAV';

  static String _dataSummary(Map<String, dynamic> d) {
    int cnt(dynamic x) => x is List ? x.length : (x is Map ? x.length : 0);
    final lib = d['library'];
    final parts = <String>[];
    if (lib is Map) {
      if (lib['favorites'] != null) parts.add('收藏 ${cnt(lib['favorites'])}');
      if (lib['history'] != null) parts.add('历史 ${cnt(lib['history'])}');
      if (lib['mangaSources'] != null) parts.add('漫画源脚本');
      if (lib['animeSources'] != null) parts.add('番剧源脚本');
    }
    if (d['sourceRepo'] != null) parts.add('源仓库配置');
    return parts.isEmpty ? '空' : parts.join(' · ');
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
