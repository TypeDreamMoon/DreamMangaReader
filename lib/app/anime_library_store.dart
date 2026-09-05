import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AnimeFavoriteEntry {
  const AnimeFavoriteEntry({
    required this.sourceId,
    required this.animeId,
    required this.title,
    this.cover,
    required this.addedAt,
  });

  final String sourceId;
  final String animeId;
  final String title;
  final String? cover;
  final int addedAt;

  String get key => '$sourceId:$animeId';

  Map<String, Object?> toJson() => {
        'sourceId': sourceId,
        'animeId': animeId,
        'title': title,
        if (cover != null) 'cover': cover,
        'addedAt': addedAt,
      };

  factory AnimeFavoriteEntry.fromJson(Map<String, dynamic> json) {
    final sourceId = _requiredString(json, 'sourceId');
    final animeId = _requiredString(json, 'animeId');
    final title = _requiredString(json, 'title');
    return AnimeFavoriteEntry(
      sourceId: sourceId,
      animeId: animeId,
      title: title,
      cover: _optionalString(json['cover']),
      addedAt: (json['addedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class AnimeHistoryEntry {
  const AnimeHistoryEntry({
    required this.sourceId,
    required this.animeId,
    required this.title,
    this.cover,
    required this.episodeId,
    required this.episodeName,
    required this.episodeIndex,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.updatedAt,
  });

  final String sourceId;
  final String animeId;
  final String title;
  final String? cover;
  final String episodeId;
  final String episodeName;
  final int episodeIndex;
  final int positionSeconds;
  final int durationSeconds;
  final int updatedAt;

  String get key => '$sourceId:$animeId';

  Map<String, Object?> toJson() => {
        'sourceId': sourceId,
        'animeId': animeId,
        'title': title,
        if (cover != null) 'cover': cover,
        'episodeId': episodeId,
        'episodeName': episodeName,
        'episodeIndex': episodeIndex,
        'positionSeconds': positionSeconds,
        'durationSeconds': durationSeconds,
        'updatedAt': updatedAt,
      };

  factory AnimeHistoryEntry.fromJson(Map<String, dynamic> json) {
    return AnimeHistoryEntry(
      sourceId: _requiredString(json, 'sourceId'),
      animeId: _requiredString(json, 'animeId'),
      title: _requiredString(json, 'title'),
      cover: _optionalString(json['cover']),
      episodeId: _requiredString(json, 'episodeId'),
      episodeName: _requiredString(json, 'episodeName'),
      episodeIndex:
          ((json['episodeIndex'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30),
      positionSeconds:
          ((json['positionSeconds'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30),
      durationSeconds:
          ((json['durationSeconds'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30),
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class AnimeLibraryStore extends ChangeNotifier {
  AnimeLibraryStore({
    this.persistDelay = const Duration(milliseconds: 600),
    this.progressPersistDelay = const Duration(seconds: 5),
  });

  static const _favoritesKey = 'anime.library.v1';
  static const _historyKey = 'anime.history.v1';

  final Duration persistDelay;

  /// 「同一集里位置往前走」的落盘间隔。
  ///
  /// 播放中每秒都会来一次进度。按 [persistDelay] 那套走 = 每秒把整张收藏表和
  /// 整张历史表重新序列化一遍再写进 SharedPreferences,还顺带把所有依赖方重建
  /// 一遍。位置是「丢掉最后几秒也无所谓」的数据,所以节流;真正要紧的时刻
  /// (暂停 / 切集 / 退出播放页 / 进后台)由 [flushPending] 立刻落盘。
  final Duration progressPersistDelay;

  /// 落盘次数。单测拿它盯住节流有没有回潮。
  @visibleForTesting
  int persistCount = 0;
  final Map<String, AnimeFavoriteEntry> _favorites = {};
  final Map<String, AnimeHistoryEntry> _history = {};
  final Set<Future<void>> _pendingWrites = {};

  SharedPreferences? _prefs;
  Timer? _persistTimer;
  bool _dirty = false;

  /// 攒着的、还没通知出去的进度变化。见 [_progressChanged]。
  bool _progressNotifyPending = false;
  bool _disposed = false;

  List<AnimeFavoriteEntry> get favorites {
    final values = _favorites.values.toList(growable: false);
    values.sort((a, b) {
      final byTime = b.addedAt.compareTo(a.addedAt);
      return byTime != 0 ? byTime : a.key.compareTo(b.key);
    });
    return List.unmodifiable(values);
  }

  List<AnimeHistoryEntry> get history {
    final values = _history.values.toList(growable: false);
    values.sort((a, b) {
      final byTime = b.updatedAt.compareTo(a.updatedAt);
      return byTime != 0 ? byTime : a.key.compareTo(b.key);
    });
    return List.unmodifiable(values);
  }

  bool isFavorite(String sourceId, String animeId) =>
      _favorites.containsKey('$sourceId:$animeId');

  AnimeHistoryEntry? historyFor(String sourceId, String animeId) =>
      _history['$sourceId:$animeId'];

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    _prefs = prefs;

    final favorites = <String, AnimeFavoriteEntry>{};
    final history = <String, AnimeHistoryEntry>{};
    var repairFavorites = false;
    var repairHistory = false;

    final favoriteRaw = prefs.getString(_favoritesKey);
    if (favoriteRaw != null) {
      try {
        final decoded = jsonDecode(favoriteRaw);
        if (decoded is! List) {
          repairFavorites = true;
        } else {
          for (final raw in decoded) {
            try {
              if (raw is! Map) throw const FormatException();
              final entry = AnimeFavoriteEntry.fromJson(
                Map<String, dynamic>.from(raw),
              );
              favorites[entry.key] = entry;
            } catch (_) {
              repairFavorites = true;
            }
          }
        }
      } catch (_) {
        repairFavorites = true;
      }
    }

    final historyRaw = prefs.getString(_historyKey);
    if (historyRaw != null) {
      try {
        final decoded = jsonDecode(historyRaw);
        if (decoded is! List) {
          repairHistory = true;
        } else {
          for (final raw in decoded) {
            try {
              if (raw is! Map) throw const FormatException();
              final entry = AnimeHistoryEntry.fromJson(
                Map<String, dynamic>.from(raw),
              );
              history[entry.key] = entry;
            } catch (_) {
              repairHistory = true;
            }
          }
        }
      } catch (_) {
        repairHistory = true;
      }
    }

    _favorites
      ..clear()
      ..addAll(favorites);
    _history
      ..clear()
      ..addAll(history);
    if (repairFavorites || repairHistory) {
      await _persistNow();
    }
    notifyListeners();
  }

  void toggleFavorite(AnimeFavoriteEntry entry) {
    if (_favorites.remove(entry.key) == null) {
      _favorites[entry.key] = entry;
    }
    _changed();
  }

  void saveProgress({
    required String sourceId,
    required String animeId,
    required String title,
    String? cover,
    required String episodeId,
    required String episodeName,
    required int episodeIndex,
    required Duration position,
    required Duration duration,
    int? updatedAt,
  }) {
    final key = '$sourceId:$animeId';
    final seconds = position.inSeconds.clamp(0, 1 << 30);
    final durationSeconds = duration.inSeconds.clamp(0, 1 << 30);
    final current = _history[key];
    if (current != null &&
        current.episodeId == episodeId &&
        current.positionSeconds == seconds &&
        current.durationSeconds == durationSeconds) {
      return;
    }
    // 还在同一集里往前走 = 只有位置变了,走节流那条路;换集 / 新开一部是
    // 结构性变化,该立刻通知也该尽快落盘。
    final positionOnly = current != null && current.episodeId == episodeId;
    _history[key] = AnimeHistoryEntry(
      sourceId: sourceId,
      animeId: animeId,
      title: title,
      // 离线播放没有封面可给,别拿 null 把已经记下的那张擦掉。
      cover: cover ?? current?.cover,
      episodeId: episodeId,
      episodeName: episodeName,
      episodeIndex: episodeIndex.clamp(0, 1 << 30),
      positionSeconds: seconds,
      durationSeconds: durationSeconds,
      updatedAt: updatedAt ?? DateTime.now().millisecondsSinceEpoch,
    );
    if (positionOnly) {
      _progressChanged();
    } else {
      _changed();
    }
  }

  void removeHistory(String sourceId, String animeId) {
    if (_history.remove('$sourceId:$animeId') != null) _changed();
  }

  void clearHistory() {
    if (_history.isEmpty) return;
    _history.clear();
    _changed();
  }

  Map<String, Object?> exportData() => {
        'version': 1,
        'favorites': [for (final entry in _favorites.values) entry.toJson()],
        'history': [for (final entry in _history.values) entry.toJson()],
      };

  void importData(Map<String, dynamic> data) {
    final favorites = <String, AnimeFavoriteEntry>{};
    final history = <String, AnimeHistoryEntry>{};
    for (final raw in data['favorites'] as List? ?? const []) {
      try {
        if (raw is! Map) continue;
        final entry =
            AnimeFavoriteEntry.fromJson(Map<String, dynamic>.from(raw));
        favorites[entry.key] = entry;
      } catch (_) {}
    }
    for (final raw in data['history'] as List? ?? const []) {
      try {
        if (raw is! Map) continue;
        final entry =
            AnimeHistoryEntry.fromJson(Map<String, dynamic>.from(raw));
        history[entry.key] = entry;
      } catch (_) {}
    }
    _favorites
      ..clear()
      ..addAll(favorites);
    _history
      ..clear()
      ..addAll(history);
    _changed();
  }

  /// 立刻落盘。暂停 / 切集 / 退出播放页 / 进后台都走这里 —— 节流丢掉的那几秒
  /// 就是在这些时刻补回来的,顺带把攒着的进度变化通知出去。
  Future<void> flushPending() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    if (_dirty) await _persistNow();
    if (_pendingWrites.isNotEmpty) {
      await Future.wait(_pendingWrites.toList(growable: false));
    }
    if (_progressNotifyPending && !_disposed) {
      _progressNotifyPending = false;
      notifyListeners();
    }
  }

  void _changed() {
    _dirty = true;
    _progressNotifyPending = false;
    _persistTimer?.cancel();
    _persistTimer = Timer(persistDelay, () {
      _persistTimer = null;
      unawaited(_persistNow());
    });
    notifyListeners();
  }

  /// 同一集里位置往前走。
  ///
  /// 内存立刻更新,写盘按 [progressPersistDelay] 节流,**不** notifyListeners:
  /// 每秒一次的位置更新会把挂在 scope 上的整棵树重建一遍,而没有任何一个界面
  /// 需要秒级的进度。攒下的这次变化留到 [flushPending] 时统一通知一次,
  /// 退出播放页后「继续观看」照样是新的。
  void _progressChanged() {
    _dirty = true;
    _progressNotifyPending = true;
    // 刻意**不**重置已经排上的定时器:每来一次进度就重排一次,等于「只要还在
    // 播就永远不写」——原来那条 600ms 的债正是反过来欠的。
    _persistTimer ??= Timer(progressPersistDelay, () {
      _persistTimer = null;
      unawaited(_persistNow());
    });
  }

  Future<void> _persistNow() async {
    final prefs = _prefs;
    if (prefs == null) return;
    persistCount++;
    _dirty = false;
    late final Future<void> write;
    write = Future.wait([
      prefs.setString(
        _favoritesKey,
        jsonEncode([for (final entry in _favorites.values) entry.toJson()]),
      ),
      prefs.setString(
        _historyKey,
        jsonEncode([for (final entry in _history.values) entry.toJson()]),
      ),
    ]).then((_) {}).whenComplete(() => _pendingWrites.remove(write));
    _pendingWrites.add(write);
    await write;
  }

  @override
  void dispose() {
    _disposed = true;
    _persistTimer?.cancel();
    if (_dirty) unawaited(_persistNow());
    super.dispose();
  }
}

class AnimeLibraryScope extends InheritedNotifier<AnimeLibraryStore> {
  const AnimeLibraryScope({
    super.key,
    required AnimeLibraryStore store,
    required super.child,
  }) : super(notifier: store);

  static AnimeLibraryStore of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<AnimeLibraryScope>();
    assert(scope != null, 'AnimeLibraryScope not found in context');
    return scope!.notifier!;
  }

  /// 订阅版可选查找:没挂 scope 时返回 null,挂了则登记依赖 ——
  /// 收藏/进度变化要能驱动调用方重建(详情页的收藏按钮、继续观看)。
  static AnimeLibraryStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AnimeLibraryScope>()?.notifier;

  static AnimeLibraryStore read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AnimeLibraryScope>();
    assert(scope != null, 'AnimeLibraryScope not found in context');
    return scope!.notifier!;
  }

  static AnimeLibraryStore? maybeRead(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AnimeLibraryScope>()?.notifier;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Missing $key');
  }
  return value;
}

String? _optionalString(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  return value;
}
