import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'update_models.dart';
import 'update_resolver.dart';

enum UpdateTransferStage {
  idle,
  downloading,
  retrying,
  verifying,
  assembling,
  ready,
  error,
}

@immutable
class UpdateTransferState {
  const UpdateTransferState({
    required this.stage,
    this.taskKey,
    this.versionName,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.progress = 0,
    this.message,
    this.packagePath,
    this.errorCode,
    this.retryAttempt,
  });

  const UpdateTransferState.idle() : this(stage: UpdateTransferStage.idle);

  final UpdateTransferStage stage;
  final String? taskKey;
  final String? versionName;
  final int downloadedBytes;
  final int totalBytes;
  final double progress;
  final String? message;
  final String? packagePath;
  final String? errorCode;
  final int? retryAttempt;

  bool get busy => switch (stage) {
        UpdateTransferStage.downloading ||
        UpdateTransferStage.retrying ||
        UpdateTransferStage.verifying ||
        UpdateTransferStage.assembling =>
          true,
        _ => false,
      };
}

abstract interface class UpdateTransferCoordinator {
  bool get supportsBackground;
  Stream<UpdateTransferState> get states;
  Future<UpdateTransferState> current();
  Future<void> start({
    required UpdateCandidate candidate,
    required ResolvedUpdateAsset asset,
  });
  Future<void> cancel();
  Future<void> install({Future<void> Function()? onBeforeExit});
  Future<void> dispose();
}

typedef WindowsUpdateDownload = Future<File> Function(
  ResolvedUpdateAsset asset, {
  required CancelToken cancelToken,
  required void Function(double progress) onProgress,
});

typedef WindowsUpdateInstall = Future<void> Function(
  File package, {
  Future<void> Function()? onBeforeExit,
});

class WindowsUpdateTransferCoordinator implements UpdateTransferCoordinator {
  WindowsUpdateTransferCoordinator({
    required WindowsUpdateDownload download,
    required WindowsUpdateInstall install,
  })  : _download = download,
        _install = install;

  final WindowsUpdateDownload _download;
  final WindowsUpdateInstall _install;
  final _controller = StreamController<UpdateTransferState>.broadcast(
    sync: true,
  );

  UpdateTransferState _state = const UpdateTransferState.idle();
  CancelToken? _cancelToken;
  File? _package;
  bool _disposed = false;

  @override
  bool get supportsBackground => false;

  @override
  Stream<UpdateTransferState> get states => _controller.stream;

  @override
  Future<UpdateTransferState> current() async => _state;

  @override
  Future<void> start({
    required UpdateCandidate candidate,
    required ResolvedUpdateAsset asset,
  }) async {
    if (_disposed) throw StateError('Update transfer coordinator is disposed.');
    if (_state.busy) throw StateError('An update download is already active.');

    final taskKey = '${asset.sha256.toLowerCase()}:${candidate.version}';
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    _package = null;
    _emit(UpdateTransferState(
      stage: UpdateTransferStage.downloading,
      taskKey: taskKey,
      versionName: candidate.version,
      totalBytes: asset.sizeBytes,
    ));

    try {
      final package = await _download(
        asset,
        cancelToken: cancelToken,
        onProgress: (progress) {
          if (cancelToken.isCancelled || _disposed) return;
          final normalized = progress.clamp(0.0, 1.0);
          _emit(UpdateTransferState(
            stage: normalized >= 1
                ? UpdateTransferStage.verifying
                : UpdateTransferStage.downloading,
            taskKey: taskKey,
            versionName: candidate.version,
            downloadedBytes: (asset.sizeBytes * normalized).round(),
            totalBytes: asset.sizeBytes,
            progress: normalized,
          ));
        },
      );
      if (cancelToken.isCancelled || _disposed) return;
      _package = package;
      _emit(UpdateTransferState(
        stage: UpdateTransferStage.ready,
        taskKey: taskKey,
        versionName: candidate.version,
        downloadedBytes: asset.sizeBytes,
        totalBytes: asset.sizeBytes,
        progress: 1,
        packagePath: package.path,
      ));
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel || cancelToken.isCancelled) {
        if (!_disposed) _emit(const UpdateTransferState.idle());
      } else if (!_disposed) {
        _emit(UpdateTransferState(
          stage: UpdateTransferStage.error,
          taskKey: taskKey,
          versionName: candidate.version,
          totalBytes: asset.sizeBytes,
          message: '$error',
        ));
      }
    } catch (error) {
      if (cancelToken.isCancelled) {
        if (!_disposed) _emit(const UpdateTransferState.idle());
      } else if (!_disposed) {
        _emit(UpdateTransferState(
          stage: UpdateTransferStage.error,
          taskKey: taskKey,
          versionName: candidate.version,
          totalBytes: asset.sizeBytes,
          message: '$error',
        ));
      }
    } finally {
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
    }
  }

  @override
  Future<void> cancel() async {
    _cancelToken?.cancel('user');
    _package = null;
    if (!_disposed) _emit(const UpdateTransferState.idle());
  }

  @override
  Future<void> install({Future<void> Function()? onBeforeExit}) async {
    final package = _package;
    if (package == null || _state.stage != UpdateTransferStage.ready) {
      throw StateError('No verified update package is ready.');
    }
    await _install(package, onBeforeExit: onBeforeExit);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelToken?.cancel('dispose');
    _cancelToken = null;
    await _controller.close();
  }

  void _emit(UpdateTransferState state) {
    _state = state;
    if (!_controller.isClosed) _controller.add(state);
  }
}
