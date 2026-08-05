import 'dart:async';

import 'package:flutter/services.dart';

import 'update_models.dart';
import 'update_transfer.dart';

class AndroidUpdatePlan {
  AndroidUpdatePlan._(this._json);

  static final _sha256 = RegExp(r'^[0-9a-fA-F]{64}$');

  final Map<String, Object?> _json;

  factory AndroidUpdatePlan.fromAsset({
    required String versionName,
    required ResolvedUpdateAsset asset,
  }) {
    if (asset.platform != UpdatePlatform.android) {
      throw const FormatException(
          'Android update plan requires Android asset.');
    }
    if (versionName.trim().isEmpty) {
      throw const FormatException('Update version must not be empty.');
    }
    _validateFileName(asset.fileName);
    _validateSha256(asset.sha256);
    if (asset.sizeBytes <= 0) {
      throw const FormatException('Update size must be positive.');
    }

    final json = <String, Object?>{
      'schemaVersion': 1,
      'taskKey': '${asset.sha256.toLowerCase()}:$versionName',
      'versionName': versionName,
      'fileName': asset.fileName,
      'sizeBytes': asset.sizeBytes,
      'sha256': asset.sha256.toLowerCase(),
    };
    if (asset.isChunked) {
      var total = 0;
      final parts = <Map<String, Object?>>[];
      for (final part in asset.parts) {
        _validateFileName(part.fileName);
        _validateSha256(part.sha256);
        _validateUrl(part.url);
        if (part.sizeBytes <= 0) {
          throw const FormatException('Update part size must be positive.');
        }
        total += part.sizeBytes;
        parts.add({
          'fileName': part.fileName,
          'url': part.url,
          'sizeBytes': part.sizeBytes,
          'sha256': part.sha256.toLowerCase(),
        });
      }
      if (total != asset.sizeBytes) {
        throw const FormatException(
            'Update part sizes do not match total size.');
      }
      json['parts'] = List<Map<String, Object?>>.unmodifiable(parts);
    } else {
      final url = asset.url;
      if (url == null) {
        throw const FormatException('Update asset has no download URL.');
      }
      _validateUrl(url);
      json['url'] = url;
    }
    return AndroidUpdatePlan._(Map<String, Object?>.unmodifiable(json));
  }

  Map<String, Object?> toJson() => Map<String, Object?>.of(_json);

  static void _validateFileName(String value) {
    if (value.trim().isEmpty ||
        value.contains('/') ||
        value.contains(r'\') ||
        value.contains('..')) {
      throw const FormatException('Update file name is unsafe.');
    }
  }

  static void _validateSha256(String value) {
    if (!_sha256.hasMatch(value)) {
      throw const FormatException('Update SHA-256 is invalid.');
    }
  }

  static void _validateUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('Update URL must use HTTPS.');
    }
  }
}

class AndroidUpdateState extends UpdateTransferState {
  const AndroidUpdateState({
    required super.stage,
    super.taskKey,
    super.versionName,
    super.downloadedBytes,
    super.totalBytes,
    super.progress,
    super.message,
    super.packagePath,
    super.errorCode,
    super.retryAttempt,
  });

  factory AndroidUpdateState.fromJson(Map<String, Object?> json) {
    final status = json['status'];
    if (status is! String) {
      throw const FormatException('Native update state has no status.');
    }
    final stage = switch (status) {
      'idle' => UpdateTransferStage.idle,
      'downloading' => UpdateTransferStage.downloading,
      'retrying' => UpdateTransferStage.retrying,
      'verifying' => UpdateTransferStage.verifying,
      'assembling' => UpdateTransferStage.assembling,
      'ready' => UpdateTransferStage.ready,
      'error' => UpdateTransferStage.error,
      _ => throw FormatException('Unknown native update status: $status'),
    };
    final downloaded = _integer(json, 'downloadedBytes');
    final total = _integer(json, 'totalBytes');
    final rawPercent = json['percent'] ?? 0;
    if (rawPercent is! num) {
      throw const FormatException('Native update percent is invalid.');
    }
    final percent = rawPercent.toDouble();
    if (downloaded < 0 ||
        total < 0 ||
        downloaded > total ||
        percent < 0 ||
        percent > 100) {
      throw const FormatException('Native update progress is inconsistent.');
    }
    final apkPath = _optionalString(json, 'apkPath');
    if (stage == UpdateTransferStage.ready &&
        (apkPath == null || apkPath.isEmpty)) {
      throw const FormatException('Ready update state has no APK path.');
    }
    final attempt = json['retryAttempt'];
    if (attempt != null && (attempt is! int || attempt < 1)) {
      throw const FormatException('Native retry attempt is invalid.');
    }
    return AndroidUpdateState(
      stage: stage,
      taskKey: _optionalString(json, 'taskKey'),
      versionName: _optionalString(json, 'versionName'),
      downloadedBytes: downloaded,
      totalBytes: total,
      progress: percent / 100,
      message: sanitizeUpdateError(_optionalString(json, 'message') ?? ''),
      packagePath: apkPath,
      errorCode: _optionalString(json, 'errorCode'),
      retryAttempt: attempt as int?,
    );
  }

  static int _integer(Map<String, Object?> json, String key) {
    final value = json[key] ?? 0;
    if (value is! int) {
      throw FormatException('Native update $key is invalid.');
    }
    return value;
  }

  static String? _optionalString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String) {
      throw FormatException('Native update $key is invalid.');
    }
    return value;
  }
}

abstract interface class AndroidUpdateBridgeApi {
  Future<void> start(AndroidUpdatePlan plan);
  Future<void> cancel();
  Future<AndroidUpdateState> current();
  Future<void> installReady();
  Stream<AndroidUpdateState> get states;
}

class AndroidUpdateBridge implements AndroidUpdateBridgeApi {
  static const methodChannel = MethodChannel('dream_manga_reader/update');
  static const eventChannel = EventChannel('dream_manga_reader/update_events');

  @override
  Future<void> start(AndroidUpdatePlan plan) =>
      _invoke('startUpdateDownload', plan.toJson());

  @override
  Future<void> cancel() => _invoke('cancelUpdateDownload');

  @override
  Future<AndroidUpdateState> current() async {
    try {
      final value = await methodChannel
          .invokeMapMethod<String, Object?>('getUpdateDownloadState');
      return AndroidUpdateState.fromJson(
        value ?? const <String, Object?>{'status': 'idle'},
      );
    } on PlatformException catch (error) {
      throw AndroidUpdateBridgeException(
        error.code,
        sanitizeUpdateError(error.message ?? error.toString()),
      );
    }
  }

  @override
  Future<void> installReady() => _invoke('installReadyUpdate');

  @override
  Stream<AndroidUpdateState> get states => eventChannel
      .receiveBroadcastStream()
      .map((value) => AndroidUpdateState.fromJson(
            Map<String, Object?>.from(value as Map),
          ));

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await methodChannel.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      throw AndroidUpdateBridgeException(
        error.code,
        sanitizeUpdateError(error.message ?? error.toString()),
      );
    }
  }
}

class AndroidUpdateBridgeException implements Exception {
  const AndroidUpdateBridgeException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

String sanitizeUpdateError(String value) {
  final withoutQueries = value.replaceAllMapped(
    RegExp(r'https?://[^\s<>"' ']+'),
    (match) {
      final raw = match.group(0)!;
      final trailing = RegExp(r'[),.;:]+$').firstMatch(raw)?.group(0) ?? '';
      final url = trailing.isEmpty
          ? raw
          : raw.substring(0, raw.length - trailing.length);
      final uri = Uri.tryParse(url);
      if (uri == null) return '[download URL]$trailing';
      return uri.replace(query: null).toString() + trailing;
    },
  );
  return withoutQueries
      .replaceAll(
        RegExp(r'(token|ts)=[^\s&]+', caseSensitive: false),
        r'$1=[redacted]',
      )
      .trim();
}
