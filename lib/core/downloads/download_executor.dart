import 'download_task.dart';

abstract interface class DownloadExecutor {
  DownloadContentKind get kind;

  Future<void> execute(
    DownloadExecutionContext context,
    DownloadTask task,
  );
}

final class DownloadExecutionContext {
  DownloadExecutionContext({
    required this.cancellation,
    required Future<void> Function(int completedBytes, int totalBytes)
        reportProgress,
    required Future<void> Function() checkpoint,
  })  : _reportProgress = reportProgress,
        _checkpoint = checkpoint;

  final DownloadCancellation cancellation;
  final Future<void> Function(int completedBytes, int totalBytes)
      _reportProgress;
  final Future<void> Function() _checkpoint;

  int _completedBytes = 0;
  int _totalBytes = 0;

  Future<void> reportProgress(int completedBytes, int totalBytes) {
    cancellation.throwIfCancelled();
    if (completedBytes < 0) {
      throw ArgumentError.value(completedBytes, 'completedBytes');
    }
    if (totalBytes < 0) {
      throw ArgumentError.value(totalBytes, 'totalBytes');
    }
    _completedBytes =
        completedBytes < _completedBytes ? _completedBytes : completedBytes;
    _totalBytes = totalBytes < _totalBytes ? _totalBytes : totalBytes;
    if (_totalBytes < _completedBytes) _totalBytes = _completedBytes;
    return _reportProgress(_completedBytes, _totalBytes);
  }

  Future<void> checkpoint() {
    cancellation.throwIfCancelled();
    return _checkpoint();
  }
}

final class DownloadCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }

  void throwIfCancelled() {
    if (_cancelled) throw const DownloadCancelledException();
  }
}

final class DownloadCancelledException implements Exception {
  const DownloadCancelledException();

  @override
  String toString() => 'DownloadCancelledException';
}
