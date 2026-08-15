import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一本收藏的追更状态。
///
/// [seen] 是「用户已经知道的话数」,[latest] 是「上次成功检查查到的话数」,
/// 差值就是书架卡片上那个角标。分成两个数而不是只存一个 bool,是为了让角标能
/// 说「3 话新」而不只是「有更新」,并且在用户看过之后能精确回到 0。
@immutable
class UpdateMark {
  const UpdateMark({
    required this.seen,
    required this.latest,
    required this.checkedAt,
  });

  final int seen;
  final int latest;
  final int checkedAt; // epoch ms;0 = 从未成功检查过

  int get pending => latest > seen ? latest - seen : 0;

  UpdateMark copyWith({int? seen, int? latest, int? checkedAt}) => UpdateMark(
        seen: seen ?? this.seen,
        latest: latest ?? this.latest,
        checkedAt: checkedAt ?? this.checkedAt,
      );

  Map<String, dynamic> toJson() => {'s': seen, 'l': latest, 'c': checkedAt};

  static UpdateMark fromJson(Map<String, dynamic> j) => UpdateMark(
        seen: (j['s'] as num?)?.toInt() ?? 0,
        latest: (j['l'] as num?)?.toInt() ?? 0,
        checkedAt: (j['c'] as num?)?.toInt() ?? 0,
      );
}

/// 追更账本:书架每条收藏「上次看到几话 / 现在几话 / 什么时候查的」。
///
/// 键用 [ShelfItem.key] 的口径(`manga:src:id` / `novel:…` / `anime:…`),
/// 于是漫画、小说、番剧三类共用这一份账,书架卡片也只需要问一次。
///
/// 只管账,不联网 —— 联网那半在 [LibraryUpdateChecker]。拆开是因为这半边
/// 全是能直接测的纯逻辑,而「首次收藏不该炸出 500 话新」这类规则恰恰是最容易
/// 写错、也最该被测住的地方。
class LibraryUpdateTracker extends ChangeNotifier {
  LibraryUpdateTracker();

  static final LibraryUpdateTracker instance = LibraryUpdateTracker();

  static const _kMarks = 'lib.updateMarks';
  static const _kAuto = 'lib.updateAutoCheck';
  static const _kLastSweep = 'lib.updateLastSweep';

  /// 两次自动检查之间的最小间隔。手动点「检查更新」不受此限制。
  static const autoInterval = Duration(hours: 6);

  SharedPreferences? _prefs;
  final Map<String, UpdateMark> _marks = {};

  bool _autoCheck = true;
  int _lastSweepAt = 0;

  /// 启动时是否自动扫一遍收藏(节流见 [autoInterval])。
  bool get autoCheck => _autoCheck;
  set autoCheck(bool v) {
    if (_autoCheck == v) return;
    _autoCheck = v;
    _prefs?.setBool(_kAuto, v);
    notifyListeners();
  }

  int get lastSweepAt => _lastSweepAt;

  Future<void> load() async {
    final p = _prefs ??= await SharedPreferences.getInstance();
    _autoCheck = p.getBool(_kAuto) ?? true;
    _lastSweepAt = p.getInt(_kLastSweep) ?? 0;
    _marks.clear();
    final raw = p.getString(_kMarks);
    if (raw != null && raw.isNotEmpty) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        j.forEach((k, v) {
          if (v is Map<String, dynamic>) _marks[k] = UpdateMark.fromJson(v);
        });
      } catch (_) {
        // 存档损坏:当作没有追更记录重来,不影响书架本身。
      }
    }
    notifyListeners();
  }

  UpdateMark? markFor(String shelfKey) => _marks[shelfKey];

  /// 这本书有几话没看过(没有记录 / 已看完都是 0)。
  int pendingFor(String shelfKey) => _marks[shelfKey]?.pending ?? 0;

  /// 书架上一共有几本有更新(驱动书架标题栏上的总数角标)。
  int get pendingWorks {
    var n = 0;
    for (final m in _marks.values) {
      if (m.pending > 0) n++;
    }
    return n;
  }

  /// 记录一次成功检查的结果,返回**新增了几话**(0 = 没更新)。
  ///
  /// 首次见到这本书时把 [UpdateMark.seen] 直接对齐到 [count]:否则刚装上 App、
  /// 或刚收藏一部完结老番的用户,会被一屏「500 话新」糊脸 —— 那不是更新,
  /// 只是我们第一次数它。真正的「新」只能相对于上一次数出来的数。
  int recordCheck(String shelfKey, int count, {required int now}) {
    if (count <= 0) return 0; // 一话都没查到多半是源出错,不动基线
    final prev = _marks[shelfKey];
    if (prev == null || prev.checkedAt == 0) {
      _marks[shelfKey] =
          UpdateMark(seen: count, latest: count, checkedAt: now);
      _persist();
      return 0;
    }
    // 话数变少(源换了目录 / 下架了几话):跟着降下来,并把基线一起压到新值,
    // 免得之后涨回原位时误报一堆「新话」。
    if (count < prev.latest) {
      _marks[shelfKey] = UpdateMark(
        seen: count < prev.seen ? count : prev.seen,
        latest: count,
        checkedAt: now,
      );
      _persist();
      return 0;
    }
    _marks[shelfKey] = prev.copyWith(latest: count, checkedAt: now);
    _persist();
    return _marks[shelfKey]!.pending - prev.pending;
  }

  /// 用户看过了(打开详情页):角标归零,但保留 latest 作为下次比较的基线。
  void markSeen(String shelfKey) {
    final m = _marks[shelfKey];
    if (m == null || m.pending == 0) return;
    _marks[shelfKey] = m.copyWith(seen: m.latest);
    _persist();
    notifyListeners();
  }

  /// 全部标为已看(书架上的「全部已读」)。
  void markAllSeen() {
    var changed = false;
    _marks.updateAll((_, m) {
      if (m.pending == 0) return m;
      changed = true;
      return m.copyWith(seen: m.latest);
    });
    if (changed) {
      _persist();
      notifyListeners();
    }
  }

  /// 只留仍在书架上的键。每次扫描后调一次 —— 取消收藏不单独通知账本,
  /// 靠这一下统一回收,免得账本随收藏来回增删无限长大。
  void retainOnly(Set<String> liveKeys) {
    final before = _marks.length;
    _marks.removeWhere((k, _) => !liveKeys.contains(k));
    if (_marks.length != before) _persist();
  }

  /// 距上次全量扫描是否已超过 [autoInterval]。
  bool sweepDue(int now) => now - _lastSweepAt >= autoInterval.inMilliseconds;

  void recordSweep(int now) {
    _lastSweepAt = now;
    _prefs?.setInt(_kLastSweep, now);
    notifyListeners();
  }

  void _persist() => _prefs?.setString(
      _kMarks, jsonEncode({for (final e in _marks.entries) e.key: e.value.toJson()}));

  @visibleForTesting
  void debugSeed(Map<String, UpdateMark> marks) {
    _marks
      ..clear()
      ..addAll(marks);
  }
}
