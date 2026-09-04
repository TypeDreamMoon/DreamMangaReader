import 'dart:async';

class HlsSession {
  HlsSession({
    required this.localUri,
    required Future<void> Function() onClose,
    Future<void> Function()? onClearCache,
    required void Function(Duration buffer) onBuffer,
    required void Function() onSeek,
  })  : _onClose = onClose,
        _onClearCache = onClearCache ?? (() async {}),
        _onBuffer = onBuffer,
        _onSeek = onSeek;

  final Uri localUri;
  final Future<void> Function() _onClose;
  final Future<void> Function() _onClearCache;
  final void Function(Duration buffer) _onBuffer;
  final void Function() _onSeek;
  bool _closed = false;

  void reportBuffer(Duration buffer) {
    if (!_closed) _onBuffer(buffer);
  }

  void notifySeek() {
    if (!_closed) _onSeek();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _onClose();
  }

  Future<void> clearCache() => _onClearCache();
}
