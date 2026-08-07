import 'dart:collection';

import 'novel_reader_models.dart';

class NovelPageCache {
  NovelPageCache({required this.byteBudget}) {
    if (byteBudget <= 0) {
      throw ArgumentError.value(byteBudget, 'byteBudget', 'Must be positive.');
    }
  }

  final int byteBudget;
  final LinkedHashMap<NovelPageKey, NovelPageFrame> _frames =
      LinkedHashMap<NovelPageKey, NovelPageFrame>();

  NovelPageKey? _currentKey;
  int _totalBytes = 0;

  int get length => _frames.length;
  int get totalBytes => _totalBytes;

  NovelPageFrame? get(NovelPageKey key) {
    final frame = _frames.remove(key);
    if (frame == null) return null;
    _frames[key] = frame;
    return frame;
  }

  void put(NovelPageFrame frame) {
    final replaced = _frames.remove(frame.key);
    if (replaced != null) {
      _totalBytes -= replaced.byteSize;
    }
    _frames[frame.key] = frame;
    _totalBytes += frame.byteSize;
    _evictToBudget();
  }

  void pinCurrent(NovelPageKey key) {
    _currentKey = key;
    _evictToBudget();
  }

  void invalidateLayout(String layoutFingerprint) {
    final staleKeys = _frames.keys
        .where(
          (key) =>
              key.layoutFingerprint != layoutFingerprint && key != _currentKey,
        )
        .toList(growable: false);
    for (final key in staleKeys) {
      _remove(key);
    }
  }

  void shrinkForMemoryPressure() {
    final currentKey = _currentKey;
    final removable =
        _frames.keys.where((key) => key != currentKey).toList(growable: false);
    for (final key in removable) {
      _remove(key);
    }
  }

  void _evictToBudget() {
    while (_totalBytes > byteBudget && _frames.length > 1) {
      NovelPageKey? candidate;
      for (final key in _frames.keys) {
        if (key != _currentKey) {
          candidate = key;
          break;
        }
      }
      if (candidate == null) return;
      _remove(candidate);
    }
  }

  void _remove(NovelPageKey key) {
    final removed = _frames.remove(key);
    if (removed != null) {
      _totalBytes -= removed.byteSize;
    }
  }
}
