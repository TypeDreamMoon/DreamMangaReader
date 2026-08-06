import 'dart:collection';

import 'download_failure.dart';

enum DownloadContentKind { anime, manga, novel, appUpdate }

enum DownloadTaskState {
  resolving,
  queued,
  running,
  verifying,
  completed,
  paused,
  failed,
  cancelled,
}

enum DownloadPauseReason {
  user,
  wifi,
  roaming,
  battery,
  storage,
  auth,
  sourceRefresh,
  system,
  externalStorage,
}

final class DownloadTask {
  DownloadTask({
    required this.id,
    required this.kind,
    required this.title,
    required this.itemTitle,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    required this.completedBytes,
    required this.totalBytes,
    required this.priority,
    required Map<String, Object?> payload,
    this.pauseReason,
    this.failure,
    this.completedAt,
  }) : payload = _validatedPayload(payload) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'must not be empty');
    if (completedBytes < 0) {
      throw ArgumentError.value(completedBytes, 'completedBytes');
    }
    if (totalBytes < 0) throw ArgumentError.value(totalBytes, 'totalBytes');
    if (state == DownloadTaskState.completed && completedAt == null) {
      throw ArgumentError('completed tasks require completedAt');
    }
  }

  final String id;
  final DownloadContentKind kind;
  final String title;
  final String itemTitle;
  final DownloadTaskState state;
  final int createdAt;
  final int updatedAt;
  final int completedBytes;
  final int totalBytes;
  final int priority;
  final Map<String, Object?> payload;
  final DownloadPauseReason? pauseReason;
  final DownloadFailure? failure;
  final int? completedAt;

  double get progress {
    if (totalBytes <= 0) return 0;
    return (completedBytes / totalBytes).clamp(0.0, 1.0).toDouble();
  }

  DownloadTask copyWith({
    String? id,
    DownloadContentKind? kind,
    String? title,
    String? itemTitle,
    DownloadTaskState? state,
    int? createdAt,
    int? updatedAt,
    int? completedBytes,
    int? totalBytes,
    int? priority,
    Map<String, Object?>? payload,
    DownloadPauseReason? pauseReason,
    bool clearPauseReason = false,
    DownloadFailure? failure,
    bool clearFailure = false,
    int? completedAt,
    bool clearCompletedAt = false,
  }) {
    return DownloadTask(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      itemTitle: itemTitle ?? this.itemTitle,
      state: state ?? this.state,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      completedBytes: completedBytes ?? this.completedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      priority: priority ?? this.priority,
      payload: payload ?? this.payload,
      pauseReason: clearPauseReason ? null : (pauseReason ?? this.pauseReason),
      failure: clearFailure ? null : (failure ?? this.failure),
      completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'itemTitle': itemTitle,
        'state': state.name,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'completedBytes': completedBytes,
        'totalBytes': totalBytes,
        'priority': priority,
        'payload': _mutableJson(payload),
        if (pauseReason != null) 'pauseReason': pauseReason!.name,
        if (failure != null) 'failure': failure!.toJson(),
        if (completedAt != null) 'completedAt': completedAt,
      };

  factory DownloadTask.fromJson(Map<String, Object?> json) {
    final rawPayload = json['payload'];
    if (rawPayload is! Map) throw const FormatException('invalid payload');
    return DownloadTask(
      id: _string(json, 'id'),
      kind: _enumValue(DownloadContentKind.values, _string(json, 'kind')),
      title: _string(json, 'title'),
      itemTitle: _string(json, 'itemTitle'),
      state: _enumValue(DownloadTaskState.values, _string(json, 'state')),
      createdAt: _integer(json, 'createdAt'),
      updatedAt: _integer(json, 'updatedAt'),
      completedBytes: _integer(json, 'completedBytes'),
      totalBytes: _integer(json, 'totalBytes'),
      priority: _integer(json, 'priority'),
      payload: rawPayload.cast<String, Object?>(),
      pauseReason: json['pauseReason'] == null
          ? null
          : _enumValue(
              DownloadPauseReason.values,
              _string(json, 'pauseReason'),
            ),
      failure: json['failure'] == null
          ? null
          : DownloadFailure.fromJson(
              (json['failure'] as Map).cast<String, Object?>(),
            ),
      completedAt:
          json['completedAt'] == null ? null : _integer(json, 'completedAt'),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadTask &&
          id == other.id &&
          kind == other.kind &&
          title == other.title &&
          itemTitle == other.itemTitle &&
          state == other.state &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt &&
          completedBytes == other.completedBytes &&
          totalBytes == other.totalBytes &&
          priority == other.priority &&
          _deepEquals(payload, other.payload) &&
          pauseReason == other.pauseReason &&
          failure == other.failure &&
          completedAt == other.completedAt;

  @override
  int get hashCode => Object.hash(
        id,
        kind,
        title,
        itemTitle,
        state,
        createdAt,
        updatedAt,
        completedBytes,
        totalBytes,
        priority,
        _deepHash(payload),
        pauseReason,
        failure,
        completedAt,
      );
}

const _reservedPayloadKeys = {
  'url',
  'urls',
  'headers',
  'cookie',
  'token',
  'key',
  'authorization',
};

Map<String, Object?> _validatedPayload(Map<String, Object?> value) {
  return UnmodifiableMapView(_freezeMap(value));
}

Map<String, Object?> _freezeMap(Map<String, Object?> value) {
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (_reservedPayloadKeys.contains(entry.key.toLowerCase())) {
      throw ArgumentError('payload contains reserved key: ${entry.key}');
    }
    result[entry.key] = _freezeJson(entry.value);
  }
  return result;
}

Object? _freezeJson(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezeJson));
  }
  if (value is Map) {
    return UnmodifiableMapView(
      _freezeMap(value.cast<String, Object?>()),
    );
  }
  throw ArgumentError.value(value, 'payload', 'must contain JSON values');
}

Object? _mutableJson(Object? value) {
  if (value is Map<String, Object?>) {
    return {
      for (final entry in value.entries) entry.key: _mutableJson(entry.value)
    };
  }
  if (value is List) return value.map(_mutableJson).toList();
  return value;
}

T _enumValue<T extends Enum>(List<T> values, String name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('unknown enum value: $name');
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('invalid $key');
}

int _integer(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw FormatException('invalid $key');
}

bool _deepEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_deepEquals(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_deepEquals(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}

int _deepHash(Object? value) {
  if (value is Map) {
    return Object.hashAllUnordered(
      value.entries
          .map((entry) => Object.hash(entry.key, _deepHash(entry.value))),
    );
  }
  if (value is List) return Object.hashAll(value.map(_deepHash));
  return value.hashCode;
}
