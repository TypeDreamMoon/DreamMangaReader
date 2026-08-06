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
  });

  static const _favoritesKey = 'anime.library.v1';
  static const _historyKey = 'anime.history.v1';

  final Duration persistDelay;
  final Map<String, AnimeFavoriteEntry> _favorites = {};
  final Map<String, AnimeHistoryEntry> _history = {};
  final Set<Future<void>> _pendingWrites = {};

  SharedPreferences? _prefs;
  Timer? _persistTimer;
  bool _dirty = false;
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
    _history[key] = AnimeHistoryEntry(
      sourceId: sourceId,
      animeId: animeId,
      title: title,
      cover: cover,
      episodeId: episodeId,
      episodeName: episodeName,
      episodeIndex: episodeIndex.clamp(0, 1 << 30),
      positionSeconds: seconds,
      durationSeconds: durationSeconds,
      updatedAt: updatedAt ?? DateTime.now().millisecondsSinceEpoch,
    );
    _changed();
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

  Future<void> flushPending() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    if (_dirty) await _persistNow();
    if (_pendingWrites.isNotEmpty) {
      await Future.wait(_pendingWrites.toList(growable: false));
    }
  }

  void _changed() {
    _dirty = true;
    _persistTimer?.cancel();
    _persistTimer = Timer(persistDelay, () {
      _persistTimer = null;
      unawaited(_persistNow());
    });
    notifyListeners();
  }

  Future<void> _persistNow() async {
    final prefs = _prefs;
    if (prefs == null) return;
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
