import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/novel/models.dart';

enum NovelReaderMode { paged, scroll }

enum NovelReaderTheme { dark, black, white, sepia }

class NovelReaderPreferences {
  const NovelReaderPreferences({
    this.mode = NovelReaderMode.paged,
    this.fontFamily = '',
    this.fontSize = 18,
    this.lineHeight = 1.7,
    this.paragraphSpacing = 10,
    this.horizontalMargin = 22,
    this.theme = NovelReaderTheme.sepia,
    this.keepScreenOn = true,
    this.toolbarAutoHideSeconds = 4,
  });

  final NovelReaderMode mode;
  final String fontFamily;
  final double fontSize;
  final double lineHeight;
  final double paragraphSpacing;
  final double horizontalMargin;
  final NovelReaderTheme theme;
  final bool keepScreenOn;
  final int toolbarAutoHideSeconds;

  NovelReaderPreferences copyWith({
    NovelReaderMode? mode,
    String? fontFamily,
    double? fontSize,
    double? lineHeight,
    double? paragraphSpacing,
    double? horizontalMargin,
    NovelReaderTheme? theme,
    bool? keepScreenOn,
    int? toolbarAutoHideSeconds,
  }) {
    return NovelReaderPreferences(
      mode: mode ?? this.mode,
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      horizontalMargin: horizontalMargin ?? this.horizontalMargin,
      theme: theme ?? this.theme,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      toolbarAutoHideSeconds:
          toolbarAutoHideSeconds ?? this.toolbarAutoHideSeconds,
    );
  }

  Map<String, Object?> toJson() => {
        'mode': mode.name,
        'fontFamily': fontFamily,
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'paragraphSpacing': paragraphSpacing,
        'horizontalMargin': horizontalMargin,
        'theme': theme.name,
        'keepScreenOn': keepScreenOn,
        'toolbarAutoHideSeconds': toolbarAutoHideSeconds,
      };

  factory NovelReaderPreferences.fromJson(Map<String, dynamic> json) {
    return NovelReaderPreferences(
      mode: NovelReaderMode.values.firstWhere(
        (value) => value.name == json['mode'],
        orElse: () => NovelReaderMode.paged,
      ),
      fontFamily: json['fontFamily'] as String? ?? '',
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 18,
      lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.7,
      paragraphSpacing: (json['paragraphSpacing'] as num?)?.toDouble() ?? 10,
      horizontalMargin: (json['horizontalMargin'] as num?)?.toDouble() ?? 22,
      theme: NovelReaderTheme.values.firstWhere(
        (value) => value.name == json['theme'],
        orElse: () => NovelReaderTheme.sepia,
      ),
      keepScreenOn: json['keepScreenOn'] as bool? ?? true,
      toolbarAutoHideSeconds:
          ((json['toolbarAutoHideSeconds'] as num?)?.toInt() ?? 4)
              .clamp(0, 10)
              .toInt(),
    );
  }
}

class NovelLibraryEntry {
  const NovelLibraryEntry._({
    required this.key,
    required this.origin,
    required this.title,
    required this.authors,
    required this.favorite,
    required this.addedAt,
    this.sourceId,
    this.novelId,
    this.fingerprint,
    this.cover,
    this.privatePath,
    this.available = false,
  });

  factory NovelLibraryEntry.local({
    required String sha256,
    required String title,
    List<String> authors = const [],
    String? cover,
    required String privatePath,
    NovelOrigin origin = NovelOrigin.localEpub,
    int? addedAt,
  }) {
    if (origin == NovelOrigin.remote) {
      throw ArgumentError.value(origin, 'origin', 'expected local origin');
    }
    final fingerprint = sha256.toLowerCase();
    return NovelLibraryEntry._(
      key: NovelIdentity.local(fingerprint).key,
      origin: origin,
      title: title,
      authors: List.unmodifiable(authors),
      fingerprint: fingerprint,
      cover: cover,
      privatePath: privatePath,
      available: _pathExists(privatePath),
      favorite: true,
      addedAt: addedAt ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  factory NovelLibraryEntry.remote({
    required String sourceId,
    required String novelId,
    required String title,
    List<String> authors = const [],
    String? cover,
    bool favorite = false,
    int? addedAt,
  }) {
    return NovelLibraryEntry._(
      key: NovelIdentity.remote(sourceId, novelId).key,
      origin: NovelOrigin.remote,
      sourceId: sourceId,
      novelId: novelId,
      title: title,
      authors: List.unmodifiable(authors),
      cover: cover,
      available: true,
      favorite: favorite,
      addedAt: addedAt ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  final String key;
  final NovelOrigin origin;
  final String? sourceId;
  final String? novelId;
  final String? fingerprint;
  final String title;
  final List<String> authors;
  final String? cover;
  final String? privatePath;
  final bool available;
  final bool favorite;
  final int addedAt;

  bool get isLocal => origin != NovelOrigin.remote;

  NovelLibraryEntry copyWith({
    String? privatePath,
    bool? available,
    bool? favorite,
    int? addedAt,
  }) {
    return NovelLibraryEntry._(
      key: key,
      origin: origin,
      sourceId: sourceId,
      novelId: novelId,
      fingerprint: fingerprint,
      title: title,
      authors: authors,
      cover: cover,
      privatePath: privatePath ?? this.privatePath,
      available: available ?? this.available,
      favorite: favorite ?? this.favorite,
      addedAt: addedAt ?? this.addedAt,
    );
  }

  Map<String, Object?> toJson({required bool includeLocalPaths}) => {
        'key': key,
        'origin': origin.name,
        if (sourceId != null) 'sourceId': sourceId,
        if (novelId != null) 'novelId': novelId,
        if (fingerprint != null) 'fingerprint': fingerprint,
        'title': title,
        'authors': authors,
        if (cover != null &&
            (includeLocalPaths || !isLocal || _isShareSafeCover(cover!)))
          'cover': cover,
        if (includeLocalPaths && privatePath != null) 'path': privatePath,
        'favorite': favorite,
        'addedAt': addedAt,
      };

  factory NovelLibraryEntry.fromJson(Map<String, dynamic> json) {
    final originName = json['origin'];
    if (originName is! String) {
      throw const FormatException('novel origin must be a string');
    }
    final origin = NovelOrigin.values.where((value) {
      return value.name == originName;
    }).firstOrNull;
    if (origin == null) {
      throw FormatException('unknown novel origin: $originName');
    }
    final sourceId = json['sourceId'] as String?;
    final novelId = json['novelId'] as String?;
    final rawFingerprint = json['fingerprint'] as String?;
    late final String key;
    String? fingerprint;
    if (origin == NovelOrigin.remote) {
      if (rawFingerprint != null) {
        throw const FormatException(
          'remote novel cannot have a local fingerprint',
        );
      }
      key = NovelIdentity.remote(sourceId ?? '', novelId ?? '').key;
    } else {
      if (sourceId != null || novelId != null) {
        throw const FormatException(
          'local novel cannot have remote identity fields',
        );
      }
      fingerprint = rawFingerprint?.toLowerCase();
      key = NovelIdentity.local(fingerprint ?? '').key;
    }
    final path = json['path'] as String?;
    return NovelLibraryEntry._(
      key: key,
      origin: origin,
      sourceId: sourceId,
      novelId: novelId,
      fingerprint: fingerprint,
      title: json['title'] as String? ?? '',
      authors: List.unmodifiable(
        (json['authors'] as List? ?? const []).map((value) => value.toString()),
      ),
      cover: json['cover'] as String?,
      privatePath: path,
      available:
          origin == NovelOrigin.remote || (path != null && _pathExists(path)),
      favorite: json['favorite'] as bool? ?? origin != NovelOrigin.remote,
      addedAt: (json['addedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class NovelReadingProgress {
  const NovelReadingProgress({
    required this.locator,
    required this.updatedAt,
  });

  final NovelLocator locator;
  final int updatedAt;

  Map<String, Object?> toJson() => {
        'chapterId': locator.chapterId,
        if (locator.blockId != null) 'blockId': locator.blockId,
        'fraction': locator.fraction,
        'updatedAt': updatedAt,
      };

  factory NovelReadingProgress.fromJson(Map<String, dynamic> json) {
    return NovelReadingProgress(
      locator: NovelLocator(
        chapterId: json['chapterId'] as String,
        blockId: json['blockId'] as String?,
        fraction: (json['fraction'] as num?)?.toDouble() ?? 0,
      ),
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class NovelLibraryStore extends ChangeNotifier {
  static const _libraryKey = 'novel.library.v1';
  static const _historyKey = 'novel.history.v1';
  static const _settingsKey = 'novel.settings.v1';

  final Map<String, NovelLibraryEntry> _entries = {};
  final Map<String, NovelReadingProgress> _history = {};
  final ValueNotifier<NovelReaderPreferences> preferencesNotifier =
      ValueNotifier(const NovelReaderPreferences());

  SharedPreferences? _prefs;
  Timer? _progressTimer;
  final Set<Future<void>> _pendingWrites = {};
  bool _disposed = false;

  List<NovelLibraryEntry> get entries => List.unmodifiable(_entries.values);
  NovelReaderPreferences get preferences => preferencesNotifier.value;

  NovelLibraryEntry? entryFor(String key) => _entries[key];
  NovelLocator? progressFor(String key) => _history[key]?.locator;
  NovelReadingProgress? progressStateFor(String key) => _history[key];

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    if (_disposed) return;

    final entries = <String, NovelLibraryEntry>{};
    final history = <String, NovelReadingProgress>{};
    var loadedPreferences = const NovelReaderPreferences();
    var repairLibrary = false;
    var repairHistory = false;
    var repairSettings = false;

    final libraryJson = prefs.getString(_libraryKey);
    if (libraryJson != null) {
      try {
        final decoded = jsonDecode(libraryJson);
        if (decoded is! List) {
          repairLibrary = true;
        } else {
          for (final value in decoded) {
            if (value is! Map) {
              repairLibrary = true;
              continue;
            }
            try {
              final json = value.cast<String, dynamic>();
              final entry = NovelLibraryEntry.fromJson(json);
              if (json['key'] != entry.key || entries.containsKey(entry.key)) {
                repairLibrary = true;
              }
              entries[entry.key] = entry;
            } catch (_) {
              repairLibrary = true;
            }
          }
        }
      } catch (_) {
        repairLibrary = true;
      }
    }
    final historyJson = prefs.getString(_historyKey);
    if (historyJson != null) {
      try {
        final decoded = jsonDecode(historyJson);
        if (decoded is! Map) {
          repairHistory = true;
        } else {
          for (final item in decoded.entries) {
            if (item.key is! String || item.value is! Map) {
              repairHistory = true;
              continue;
            }
            try {
              history[item.key as String] = NovelReadingProgress.fromJson(
                (item.value as Map).cast<String, dynamic>(),
              );
            } catch (_) {
              repairHistory = true;
            }
          }
        }
      } catch (_) {
        repairHistory = true;
      }
    }
    final settingsJson = prefs.getString(_settingsKey);
    if (settingsJson != null) {
      try {
        final decoded = jsonDecode(settingsJson);
        if (decoded is! Map) {
          repairSettings = true;
        } else {
          loadedPreferences = NovelReaderPreferences.fromJson(
            decoded.cast<String, dynamic>(),
          );
        }
      } catch (_) {
        repairSettings = true;
      }
    }

    _prefs = prefs;
    _entries
      ..clear()
      ..addAll(entries);
    _history
      ..clear()
      ..addAll(history);
    preferencesNotifier.value = loadedPreferences;
    if (repairLibrary) _persistLibrary();
    if (repairHistory) _persistHistory();
    if (repairSettings) _persistSettings();
    notifyListeners();
  }

  void addLocal(NovelLibraryEntry entry) {
    if (!entry.isLocal) {
      throw ArgumentError.value(entry.key, 'entry', 'expected local novel');
    }
    final path = entry.privatePath;
    _entries[entry.key] = entry.copyWith(
      available: path != null && _pathExists(path),
    );
    _persistLibrary();
    notifyListeners();
  }

  void removeLocal(String key, {bool removeHistory = false}) {
    final entry = _entries[key];
    if (entry == null) return;
    if (!entry.isLocal) {
      throw ArgumentError.value(key, 'key', 'expected local novel');
    }
    _entries.remove(key);
    if (removeHistory) _history.remove(key);
    _persistLibrary();
    if (removeHistory) _persistHistory();
    notifyListeners();
  }

  void removeHistory(String key) {
    if (_history.remove(key) == null) return;
    _persistHistory();
    notifyListeners();
  }

  void clearHistory() {
    if (_history.isEmpty) return;
    _history.clear();
    _persistHistory();
    notifyListeners();
  }

  List<MapEntry<String, NovelReadingProgress>> get history {
    final values = _history.entries.toList(growable: false);
    values.sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
    return List.unmodifiable(values);
  }

  void toggleRemoteFavorite(NovelLibraryEntry entry) {
    if (entry.origin != NovelOrigin.remote) {
      throw ArgumentError.value(entry.key, 'entry', 'expected remote novel');
    }
    final current = _entries[entry.key];
    if (current == null) {
      _entries[entry.key] = entry.copyWith(
        favorite: true,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      );
    } else if (current.favorite && !_history.containsKey(entry.key)) {
      _entries.remove(entry.key);
    } else {
      _entries[entry.key] = current.copyWith(favorite: !current.favorite);
    }
    _persistLibrary();
    notifyListeners();
  }

  void saveProgress(String key, NovelLocator locator, {int? updatedAt}) {
    _history[key] = NovelReadingProgress(
      locator: locator,
      updatedAt: updatedAt ?? DateTime.now().millisecondsSinceEpoch,
    );
    _progressTimer?.cancel();
    _progressTimer = Timer(
      const Duration(milliseconds: 600),
      () {
        _progressTimer = null;
        _persistHistory();
      },
    );
    notifyListeners();
  }

  void setPreferences(NovelReaderPreferences value) {
    preferencesNotifier.value = value;
    _persistSettings();
    notifyListeners();
  }

  Map<String, Object?> exportData({bool includeLocalPaths = false}) => {
        'schema': 1,
        'entries': _entries.values
            .map((entry) => entry.toJson(
                  includeLocalPaths: includeLocalPaths,
                ))
            .toList(growable: false),
        'history': {
          for (final item in _history.entries) item.key: item.value.toJson(),
        },
        'settings': preferences.toJson(),
      };

  Future<void> importData(
    Map<String, dynamic> data, {
    bool replaceEntries = true,
    bool replaceHistory = true,
    bool replaceSettings = true,
  }) async {
    if (replaceEntries && data['entries'] is List) {
      final incoming = <String, NovelLibraryEntry>{};
      for (final value in data['entries'] as List) {
        if (value is! Map) continue;
        try {
          final entry = NovelLibraryEntry.fromJson(
            value.cast<String, dynamic>(),
          );
          incoming[entry.key] = _reattachLocalPath(entry, _entries[entry.key]);
        } catch (_) {}
      }
      for (final entry in _entries.values) {
        if (entry.isLocal) incoming.putIfAbsent(entry.key, () => entry);
      }
      _entries
        ..clear()
        ..addAll(incoming);
      _persistLibrary();
    }

    if (replaceHistory && data['history'] is Map) {
      final incoming = <String, NovelReadingProgress>{};
      for (final item in (data['history'] as Map).entries) {
        if (item.key is! String || item.value is! Map) continue;
        try {
          incoming[item.key as String] = NovelReadingProgress.fromJson(
            (item.value as Map).cast<String, dynamic>(),
          );
        } catch (_) {}
      }
      _history
        ..clear()
        ..addAll(incoming);
      _persistHistory();
    }

    if (replaceSettings && data['settings'] is Map) {
      try {
        preferencesNotifier.value = NovelReaderPreferences.fromJson(
          (data['settings'] as Map).cast<String, dynamic>(),
        );
        _persistSettings();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> flushPending() async {
    _progressTimer?.cancel();
    _progressTimer = null;
    _persistLibrary();
    _persistHistory();
    _persistSettings();
    while (_pendingWrites.isNotEmpty) {
      await Future.wait(_pendingWrites.toList(growable: false));
    }
  }

  void _persistLibrary() {
    final prefs = _prefs;
    if (prefs == null) return;
    _trackWrite(prefs.setString(
      _libraryKey,
      jsonEncode(
        _entries.values
            .map((entry) => entry.toJson(includeLocalPaths: true))
            .toList(growable: false),
      ),
    ));
  }

  void _persistHistory() {
    final prefs = _prefs;
    if (prefs == null) return;
    _trackWrite(prefs.setString(
      _historyKey,
      jsonEncode({
        for (final item in _history.entries) item.key: item.value.toJson(),
      }),
    ));
  }

  void _persistSettings() {
    final prefs = _prefs;
    if (prefs == null) return;
    _trackWrite(prefs.setString(
      _settingsKey,
      jsonEncode(preferences.toJson()),
    ));
  }

  void _trackWrite(Future<bool> write) {
    late final Future<void> tracked;
    tracked = write.then<void>((_) {}).whenComplete(() {
      _pendingWrites.remove(tracked);
    });
    _pendingWrites.add(tracked);
  }

  @override
  void dispose() {
    _disposed = true;
    _progressTimer?.cancel();
    _progressTimer = null;
    _persistLibrary();
    _persistHistory();
    _persistSettings();
    preferencesNotifier.dispose();
    super.dispose();
  }
}

class NovelLibraryScope extends InheritedNotifier<NovelLibraryStore> {
  const NovelLibraryScope({
    super.key,
    required NovelLibraryStore store,
    required super.child,
  }) : super(notifier: store);

  static NovelLibraryStore of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<NovelLibraryScope>();
    assert(scope != null, 'NovelLibraryScope not found in context');
    return scope!.notifier!;
  }

  static NovelLibraryStore read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<NovelLibraryScope>();
    assert(scope != null, 'NovelLibraryScope not found in context');
    return scope!.notifier!;
  }
}

bool _pathExists(String path) {
  try {
    return FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
  } catch (_) {
    return false;
  }
}

bool _isShareSafeCover(String cover) {
  final uri = Uri.tryParse(cover);
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
}

NovelLibraryEntry _reattachLocalPath(
  NovelLibraryEntry incoming,
  NovelLibraryEntry? current,
) {
  if (!incoming.isLocal || current?.privatePath == null) return incoming;
  return NovelLibraryEntry.local(
    sha256: incoming.fingerprint!,
    title: incoming.title,
    authors: incoming.authors,
    cover: incoming.cover,
    privatePath: current!.privatePath!,
    origin: incoming.origin,
    addedAt: incoming.addedAt,
  );
}
