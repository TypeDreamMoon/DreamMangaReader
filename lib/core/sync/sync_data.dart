import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../app/library_store.dart';
import '../source/source_registry.dart' show registeredSources;
import '../source/source_repository.dart';
import '../source/title_match.dart' show sameCoreKey;

/// 可选择同步的内容类别。源开关按内容类型拆成漫画源 / 番剧源两档;
/// 设置按用途拆成 阅读 / 界面外观 / 其它,搜索历史单独一类(是数据不是设置)。
/// 旧版的整份「settings」类别在 [SyncController.load] 迁移成后四类。
enum SyncCategory {
  favorites, // 收藏
  history, // 阅读进度 / 历史(含作品级共享进度)
  searchHistory, // 搜索历史
  readerSettings, // 阅读设置(翻页/缩放/滤镜/亮度/每本书的模式…)
  uiSettings, // 界面与外观(布局/字体/圆角/背景图/动画…)
  appSettings, // 其它设置(更新检查/搜索翻译/Bangumi 绑定…)
  mangaSources, // 漫画源开关(disabledSources 中 kind=manga 的)
  animeSources, // 番剧源开关(disabledSources 中 kind=anime 的)
  sourceRepo, // 源仓库配置(repoUrl/localDir/token)
}

/// 云同步的数据 blob:书架数据(收藏/历史/设置/源开关)+ 源仓库配置。
/// **不含**每源登录 token 与下载文件。
///
/// - [build] 只放所选类别;源开关按 source kind 拆成 `disabledSourcesManga/Anime`。
/// - [merge] 类别并集(自动双向同步用)。
/// - [overlay] 把 over 的类别盖到 base 上(上传:本地覆盖服务器对应类别,保留其余)。
/// - [apply] 把 blob 的所选类别写回本地;`append=false` 覆盖,`append=true` 追加
///   (收藏/历史并集、源开关并集,设置/源仓保持本地不动)。
class SyncData {
  static int _int(Object? v) => (v is num) ? v.toInt() : 0;
  static Map<String, dynamic> _map(Object? v) =>
      (v is Map) ? v.cast<String, dynamic>() : <String, dynamic>{};
  static List _list(Object? v) => (v is List) ? v : const [];
  static List<String> _strList(Object? v) =>
      (v is List) ? v.map((e) => e.toString()).toList() : <String>[];

  /// library 里属于「设置」类别的键(排除收藏/历史/源开关/背景图内容与版本标记)。
  /// 公开:变化侦测(自动上传的类别签名)也按同一套归类,别再抄一份。
  static bool isSettingsKey(String k) =>
      k != 'v' &&
      k != 'favorites' &&
      k != 'history' &&
      k != 'workProgress' && // 作品级共享进度归「进度」类别,不算设置
      k != 'disabledSources' &&
      k != 'bgImageData' &&
      k != 'bgImageExt';

  // ---- 设置键 → 细分类别 ----
  // 阅读器行为(含每本书的模式覆盖 mangaModes)。
  static const _readerKeys = {
    'readerMode', 'preload', 'doublePage', 'doubleTapZoom', 'showPageNumber',
    'brightness', 'webtoonWidth', 'readerBackground', 'readerGestures',
    'volumeKeyPaging', 'invertTapZones', 'readerBg', 'readerOrientation',
    'keepScreenOn', 'autoDetectMode', 'webtoonGap', 'chapterToast',
    'cfGrayscale', 'cfInvert', 'cfSepia', 'cfContrast', 'zoomMode',
    'autoScrollSpeed', 'mangaModes', 'chaptersDesc',
  };

  // 界面与外观(布局/字体/圆角/背景图/动画;showSourcePicker 与书架布局同组)。
  static const _uiKeys = {
    'gridColumns', 'coverRadius', 'controlRadius', 'uiScale', 'uiFont',
    'bgImage', 'bgBlur', 'bgTintColor', 'bgTintAlpha', 'enableAnimations',
    'scrollAnimations', 'detailTintStrength', 'feedLayout', 'showSourcePicker',
  };

  /// 设置类键 → 细分类别;非设置键(收藏/历史/源开关/v 等)返回 null。
  /// 不在名单里的键(将来新增的设置)兜底归「其它设置」,保证仍会被同步。
  static SyncCategory? settingsCatOf(String k) {
    if (!isSettingsKey(k)) return null;
    if (k == 'searchHistory') return SyncCategory.searchHistory;
    if (_readerKeys.contains(k)) return SyncCategory.readerSettings;
    if (_uiKeys.contains(k)) return SyncCategory.uiSettings;
    return SyncCategory.appSettings; // 更新/翻译/Bangumi 绑定 + 未来新增
  }

  /// 三个设置细类(遍历用)。
  static const settingsCats = [
    SyncCategory.readerSettings,
    SyncCategory.uiSettings,
    SyncCategory.appSettings,
  ];

  /// 背景图:设置里只存本地路径,跨设备无意义;上传时把图片内容(base64)也带上,
  /// 有 3MB 上限(免撑爆 blob;更大就只同步路径,目标机自行处理)。
  static void _embedBgImage(Map<String, dynamic> outLib, Object? bgPath) {
    final p = (bgPath is String) ? bgPath.trim() : '';
    if (p.isEmpty) return;
    try {
      final f = File(p);
      if (!f.existsSync()) return;
      final len = f.lengthSync();
      if (len <= 0 || len > 3 * 1024 * 1024) return;
      outLib['bgImageData'] = base64Encode(f.readAsBytesSync());
      final dot = p.lastIndexOf('.');
      outLib['bgImageExt'] =
          (dot >= 0 && p.length - dot <= 6) ? p.substring(dot + 1).toLowerCase() : 'png';
    } catch (_) {}
  }

  /// 应用背景图:带了内容就落到本机再指过去;没带则清掉本机不存在的悬空路径(免坏图)。
  static Future<void> _applyBgImage(
      Map<String, dynamic> blib, LibraryStore lib) async {
    try {
      final data = blib['bgImageData'] as String?;
      if (data != null && data.isNotEmpty) {
        final ext =
            (blib['bgImageExt'] as String?)?.replaceAll(RegExp(r'[^a-z0-9]'), '');
        final dir = await getApplicationSupportDirectory();
        final file = File('${dir.path}/synced_bg.${ext == null || ext.isEmpty ? 'png' : ext}');
        await file.writeAsBytes(base64Decode(data));
        lib.bgImage = file.path;
      } else {
        final cur = lib.bgImage.trim();
        if (cur.isNotEmpty && !File(cur).existsSync()) lib.bgImage = '';
      }
    } catch (_) {}
  }

  /// 源 id 是否为番剧源。未知(源已移除/未加载)按漫画处理。
  static bool _isAnimeId(String id) {
    for (final m in registeredSources) {
      if (m.id == id) return m.isAnime;
    }
    return false;
  }

  /// 导出当前已加载的某类源的完整定义(含脚本正文 'code'),让源本身也能被同步。
  static List<Map<String, dynamic>> _exportSources(bool anime) => [
        for (final m in registeredSources)
          if (m.isAnime == anime)
            {
              'id': m.id,
              'name': m.name,
              'kind': m.kind,
              'experimental': m.experimental,
              'useWebView': m.useWebView,
              'imageReferer': m.imageReferer,
              'needsLogin': m.needsLogin,
              'code': m.script,
            },
      ];

  static List<Map<String, dynamic>> _entryList(Object? v) => (v is List)
      ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
      : const <Map<String, dynamic>>[];

  /// 从本地各 store 组装当前 blob——只包含 [categories] 所选类别。
  static Map<String, dynamic> build(
    LibraryStore lib,
    SourceRepository repo, {
    required Set<SyncCategory> categories,
  }) {
    final full = lib.exportData();
    final outLib = <String, dynamic>{'v': 1};
    if (categories.contains(SyncCategory.favorites)) {
      outLib['favorites'] = full['favorites'];
    }
    if (categories.contains(SyncCategory.history)) {
      outLib['history'] = full['history'];
      outLib['workProgress'] = full['workProgress']; // 作品级共享进度随进度一起走
    }
    // 设置细类 + 搜索历史:按键归类,选了哪类就带哪类的键。
    for (final e in full.entries) {
      final cat = settingsCatOf(e.key);
      if (cat != null && categories.contains(cat)) outLib[e.key] = e.value;
    }
    if (categories.contains(SyncCategory.uiSettings)) {
      // 先放墓碑再嵌图:本机没有可嵌的背景图(没设/超 3MB)时,空串会经
      // overlay/LWW 盖掉云端残留的旧 bgImageData——否则清掉的背景图会在
      // 别的设备上复活。_applyBgImage 对空串按「无图」处理。
      outLib['bgImageData'] = '';
      outLib['bgImageExt'] = '';
      _embedBgImage(outLib, full['bgImage']); // 背景图内容随「界面与外观」走
    }
    final allDisabled = _strList(full['disabledSources']);
    if (categories.contains(SyncCategory.mangaSources)) {
      outLib['disabledSourcesManga'] =
          allDisabled.where((id) => !_isAnimeId(id)).toList();
      outLib['localSourcesManga'] = _exportSources(false); // 源脚本本身
    }
    if (categories.contains(SyncCategory.animeSources)) {
      outLib['disabledSourcesAnime'] = allDisabled.where(_isAnimeId).toList();
      outLib['localSourcesAnime'] = _exportSources(true);
    }
    final blob = <String, dynamic>{
      'v': 1,
      'syncedAt': DateTime.now().millisecondsSinceEpoch,
      'library': outLib,
    };
    if (categories.contains(SyncCategory.sourceRepo)) {
      blob['sourceRepo'] = {
        'repoUrl': repo.repoUrl ?? '',
        'localDir': repo.localDir ?? '',
        'token': repo.token ?? '',
      };
    }
    return blob;
  }

  /// 合并两个 blob——**按类别取并集**(只有一方有的类别原样保留)。自动双向同步用。
  static Map<String, dynamic> merge(
      Map<String, dynamic> local, Map<String, dynamic> remote) {
    final lTs = _int(local['syncedAt']);
    final rTs = _int(remote['syncedAt']);
    final lLib = _map(local['library']);
    final rLib = _map(remote['library']);

    final outLib = <String, dynamic>{'v': 1};
    final keys = {...lLib.keys, ...rLib.keys}..remove('v');
    for (final k in keys) {
      if (k == 'favorites') {
        outLib[k] = _mergeFavorites(_list(lLib[k]), _list(rLib[k]));
      } else if (k == 'history') {
        outLib[k] = _mergeHistory(_map(lLib[k]), _map(rLib[k]));
      } else if (k == 'workProgress') {
        outLib[k] = _mergeWorkProgress(_map(lLib[k]), _map(rLib[k]));
      } else if (k == 'searchHistory') {
        // 搜索历史随「设置」类别走,但不作 LWW 整份覆盖:两端取并集,
        // 较新的一方在前,大小写不敏感去重,截断上限(免一端清掉另一端的历史)。
        outLib[k] =
            _mergeSearchHistory(_strList(lLib[k]), lTs, _strList(rLib[k]), rTs);
      } else {
        outLib[k] = _lww(
            lLib.containsKey(k), lLib[k], lTs, rLib.containsKey(k), rLib[k], rTs);
      }
    }

    final out = <String, dynamic>{
      'v': 1,
      'syncedAt': DateTime.now().millisecondsSinceEpoch,
      'library': outLib,
    };
    final sr = _lww(local.containsKey('sourceRepo'), local['sourceRepo'], lTs,
        remote.containsKey('sourceRepo'), remote['sourceRepo'], rTs);
    if (sr != null) out['sourceRepo'] = sr;
    return out;
  }

  /// 把 [over] 出现的类别覆盖到 [base] 上,base 其余类别原样保留(上传语义:
  /// 本地覆盖服务器对应类别,不动服务器上别的类别)。
  static Map<String, dynamic> overlay(
      Map<String, dynamic> base, Map<String, dynamic> over) {
    final outLib = Map<String, dynamic>.from(_map(base['library']))..['v'] = 1;
    _map(over['library']).forEach((k, v) {
      if (k != 'v') outLib[k] = v;
    });
    final out = <String, dynamic>{
      'v': 1,
      'syncedAt': DateTime.now().millisecondsSinceEpoch,
      'library': outLib,
    };
    final sr = over.containsKey('sourceRepo')
        ? over['sourceRepo']
        : base['sourceRepo'];
    if (sr != null) out['sourceRepo'] = sr;
    return out;
  }

  static dynamic _lww(
      bool hasL, dynamic lv, int lTs, bool hasR, dynamic rv, int rTs) {
    if (!hasL) return rv;
    if (!hasR) return lv;
    return rTs >= lTs ? rv : lv;
  }

  static List _mergeFavorites(List a, List b) {
    final by = <String, Map>{};
    void add(List xs) {
      for (final x in xs) {
        if (x is! Map) continue;
        final key = '${x['s']}:${x['m']}';
        final prev = by[key];
        if (prev == null || _int(x['a']) >= _int(prev['a'])) by[key] = x;
      }
    }

    add(a);
    add(b);
    return by.values.toList();
  }

  // 搜索历史并集:新的一方在前,大小写不敏感去重(保留先出现的原样大小写),截断到 30。
  static List<String> _mergeSearchHistory(
      List<String> a, int aTs, List<String> b, int bTs) {
    final first = bTs >= aTs ? b : a;
    final second = bTs >= aTs ? a : b;
    final seen = <String>{};
    final out = <String>[];
    for (final s in [...first, ...second]) {
      final t = s.trim();
      if (t.isEmpty) continue;
      if (seen.add(t.toLowerCase())) out.add(t);
      if (out.length >= 30) break;
    }
    return out;
  }

  /// 合并两条作品进度:续读点(话数/章名/时间/源)取**更新时间较新**的一方;
  /// 已读章话数集合取并集。
  static Map<String, dynamic> _mergeWorkEntry(Map x, Map y) {
    final recent = _int(x['u']) >= _int(y['u']) ? x : y;
    final reads = <double>{
      ...(x['r'] as List? ?? const []).whereType<num>().map((e) => e.toDouble()),
      ...(y['r'] as List? ?? const []).whereType<num>().map((e) => e.toDouble()),
    };
    return {
      'n': recent['n'],
      'l': recent['l'],
      'u': recent['u'],
      's': recent['s'],
      'r': reads.toList(),
    };
  }

  /// 作品级共享进度并集:两端(设备)按各自"最后读到哪"汇合,不丢已读记录。
  /// ①按精确 key 并集;②**模糊合并同作品的不同 key**(繁简/异体字变体跨设备各自
  /// 建了不同 key)—— key 排序后字典序小者存活,两端产出同一份结果,不留一半分裂。
  static Map<String, dynamic> _mergeWorkProgress(Map a, Map b) {
    final union = <String, Map>{};
    void addAll(Map m) {
      m.forEach((k, v) {
        if (v is! Map) return;
        final ks = k.toString();
        final prev = union[ks];
        union[ks] = prev == null ? v : _mergeWorkEntry(prev, v);
      });
    }

    addAll(a);
    addAll(b);

    final keys = union.keys.toList()..sort();
    final out = <String, dynamic>{};
    for (final k in keys) {
      String? target;
      for (final ok in out.keys) {
        if (sameCoreKey(k, ok)) {
          target = ok;
          break;
        }
      }
      if (target == null) {
        out[k] = union[k];
      } else {
        out[target] = _mergeWorkEntry(out[target] as Map, union[k]!);
      }
    }
    return out;
  }

  static Map<String, dynamic> _mergeHistory(Map a, Map b) {
    final out = <String, dynamic>{};
    void add(Map xs) {
      xs.forEach((k, v) {
        if (v is! Map) return;
        final prev = out[k];
        if (prev == null || _int(v['u']) >= _int((prev as Map)['u'])) {
          out[k.toString()] = v;
        }
      });
    }

    add(a);
    add(b);
    return out;
  }

  /// 把 [blob] 写回本地——[modes] 逐类别指定方式:
  ///   不在 map 里 = 不下载该类;`false` = 覆盖(用服务器替换本地);`true` = 追加。
  /// 追加:收藏/历史/源开关取并集;设置/源仓库无「追加」语义,只有覆盖(false)才应用。
  static Future<void> apply(
    Map<String, dynamic> blob,
    LibraryStore lib,
    SourceRepository repo, {
    required Map<SyncCategory, bool> modes,
  }) async {
    final blib = _map(blob['library']);
    final mangaMode = modes[SyncCategory.mangaSources];
    final animeMode = modes[SyncCategory.animeSources];

    // 源脚本:先导入(importLocalSources 会 reload 刷新 registeredSources),后面 toggle 的
    // kind 判断才准。覆盖(false)= 替换该类本地源;追加(true)= 合并保留。
    if (mangaMode != null && blib['localSourcesManga'] is List) {
      await repo.importLocalSources(_entryList(blib['localSourcesManga']),
          restrictKind: 'manga', replace: mangaMode == false);
    }
    if (animeMode != null && blib['localSourcesAnime'] is List) {
      await repo.importLocalSources(_entryList(blib['localSourcesAnime']),
          restrictKind: 'anime', replace: animeMode == false);
    }

    final full = lib.exportData(); // 当前本地态:供追加合并 + 源开关重建
    final toImport = <String, dynamic>{'v': 1};

    final favMode = modes[SyncCategory.favorites];
    final histMode = modes[SyncCategory.history];
    final importFav = favMode != null && blib.containsKey('favorites');
    final importHist = histMode != null && blib.containsKey('history');
    if (importFav) {
      toImport['favorites'] = favMode == true
          ? _mergeFavorites(_list(full['favorites']), _list(blib['favorites']))
          : blib['favorites'];
    }
    if (importHist) {
      toImport['history'] = histMode == true
          ? _mergeHistory(_map(full['history']), _map(blib['history']))
          : blib['history'];
    }
    // 作品级共享进度随「进度」类别:追加=并集,覆盖=用服务器的。importData 按
    // replaceHistory 落它,故这里只在 importHist 时放进 toImport。
    if (histMode != null && blib.containsKey('workProgress')) {
      toImport['workProgress'] = histMode == true
          ? _mergeWorkProgress(
              _map(full['workProgress']), _map(blib['workProgress']))
          : blib['workProgress'];
    }
    // 搜索历史:覆盖=用服务器的;追加=并集(本地近期在前,免清掉本地记录)。
    final shMode = modes[SyncCategory.searchHistory];
    if (shMode != null && blib.containsKey('searchHistory')) {
      toImport['searchHistory'] = shMode == true
          ? _mergeSearchHistory(
              _strList(full['searchHistory']), 1, _strList(blib['searchHistory']), 0)
          : blib['searchHistory'];
    }
    // 设置细类:只有覆盖(false)才应用;追加/不选保持本地。
    for (final cat in settingsCats) {
      if (modes[cat] != false) continue;
      for (final e in blib.entries) {
        if (settingsCatOf(e.key) == cat) toImport[e.key] = e.value;
      }
    }
    // 源开关:按 kind 分别重建整份 disabledSources 交给 importData。
    final wantManga =
        mangaMode != null && blib.containsKey('disabledSourcesManga');
    final wantAnime =
        animeMode != null && blib.containsKey('disabledSourcesAnime');
    if (wantManga || wantAnime) {
      final result = Set<String>.from(_strList(full['disabledSources']));
      if (wantManga) {
        if (mangaMode == false) result.removeWhere((id) => !_isAnimeId(id));
        result.addAll(_strList(blib['disabledSourcesManga']));
      }
      if (wantAnime) {
        if (animeMode == false) result.removeWhere(_isAnimeId);
        result.addAll(_strList(blib['disabledSourcesAnime']));
      }
      toImport['disabledSources'] = result.toList();
    }

    await lib.importData(toImport,
        replaceFavorites: importFav, replaceHistory: importHist);

    // 背景图:「界面与外观」覆盖模式下落地图片内容并指向本机路径(追加不动设置)。
    if (modes[SyncCategory.uiSettings] == false) {
      await _applyBgImage(blib, lib);
    }

    // 源仓库:只有覆盖(false)才应用。失败不连累整体。
    if (modes[SyncCategory.sourceRepo] == false) {
      try {
        final sr = _map(blob['sourceRepo']);
        final url = (sr['repoUrl'] as String?)?.trim() ?? '';
        final dir = (sr['localDir'] as String?)?.trim() ?? '';
        final tok = (sr['token'] as String?)?.trim() ?? '';
        if (tok != (repo.token ?? '')) {
          await repo.setToken(tok.isEmpty ? null : tok);
        }
        if (url.isNotEmpty && url != (repo.repoUrl ?? '')) {
          await repo.setRepoUrl(url);
        } else if (url.isEmpty && dir.isNotEmpty && dir != (repo.localDir ?? '')) {
          await repo.setLocalDir(dir);
        }
      } catch (_) {}
    }
  }

  /// 哪些类别支持「追加」(其余只有覆盖):收藏/历史/搜索历史/源开关是集合可并;
  /// 各设置细类/源仓库是整份值。
  static bool supportsAppend(SyncCategory c) =>
      c == SyncCategory.favorites ||
      c == SyncCategory.history ||
      c == SyncCategory.searchHistory ||
      c == SyncCategory.mangaSources ||
      c == SyncCategory.animeSources;
}
