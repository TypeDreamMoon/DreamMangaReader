import 'dart:async';

class HlsSession {
  HlsSession({
    required this.localUri,
    required Future<void> Function({required bool discardCache}) onClose,
    required void Function(Duration buffer) onBuffer,
    required void Function() onSeek,
  })  : _onClose = onClose,
        _onBuffer = onBuffer,
        _onSeek = onSeek;

  final Uri localUri;
  final Future<void> Function({required bool discardCache}) _onClose;
  final void Function(Duration buffer) _onBuffer;
  final void Function() _onSeek;
  bool _closed = false;

  void reportBuffer(Duration buffer) {
    if (!_closed) _onBuffer(buffer);
  }

  void notifySeek() {
    if (!_closed) _onSeek();
  }

  /// [discardCache] = 这一集的分片不用留了(换了一集/换了一部片)。
  ///
  /// 丢弃发生在会话关完之后:预读停了、租约还回去了,缓存条目才删得掉。反过来
  /// 先删再关,正在用的那些条目会被跳过,删了个寂寞。
  Future<void> close({bool discardCache = false}) async {
    if (_closed) return;
    _closed = true;
    await _onClose(discardCache: discardCache);
  }
}
