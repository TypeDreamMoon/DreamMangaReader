import 'dart:async';

class HlsSession {
  HlsSession({
    required this.localUri,
    required Future<void> Function() onClose,
    required void Function(Duration buffer) onBuffer,
    required void Function() onSeek,
  })  : _onClose = onClose,
        _onBuffer = onBuffer,
        _onSeek = onSeek;

  final Uri localUri;
  final Future<void> Function() _onClose;
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
}
