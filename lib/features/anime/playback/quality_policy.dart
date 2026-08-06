typedef QualityClock = DateTime Function();

class QualityLevel {
  const QualityLevel({required this.id, required this.bandwidth});

  final String id;
  final int bandwidth;
}

class QualityPolicy {
  QualityPolicy({
    required List<QualityLevel> levels,
    QualityClock? now,
  })  : _levels = List.unmodifiable(
          List<QualityLevel>.of(levels)
            ..sort((left, right) => left.bandwidth.compareTo(right.bandwidth)),
        ),
        _now = now ?? DateTime.now {
    if (_levels.isEmpty) throw ArgumentError.value(levels, 'levels', '不能为空');
  }

  final List<QualityLevel> _levels;
  final QualityClock _now;
  final List<DateTime> _stalls = [];
  late QualityLevel _current;
  DateTime? _selectedAt;
  DateTime? _lastSwitchAt;
  bool _selected = false;
  bool _manual = false;

  QualityLevel get current {
    if (!_selected) return selectInitial();
    return _current;
  }

  QualityLevel selectInitial() {
    final middle = (_levels.length - 1) ~/ 2;
    _select(_levels[middle], manual: false, switched: false);
    return _current;
  }

  QualityLevel selectManual(String id) {
    final level = _levels.where((candidate) => candidate.id == id).firstOrNull;
    if (level == null) throw ArgumentError.value(id, 'id', '未知清晰度');
    _select(level, manual: true, switched: true);
    return _current;
  }

  void selectAutomatic() {
    _manual = false;
    _selectedAt = _now();
  }

  QualityLevel? recordThroughput(int bitsPerSecond) {
    _ensureSelected();
    if (_manual || bitsPerSecond >= _current.bandwidth * 1.2) return null;
    return _lower();
  }

  QualityLevel? recordStall() {
    _ensureSelected();
    if (_manual) return null;
    final currentTime = _now();
    _stalls.removeWhere(
      (time) => currentTime.difference(time) > const Duration(seconds: 30),
    );
    _stalls.add(currentTime);
    if (_stalls.length < 2) return null;
    _stalls.clear();
    return _lower();
  }

  QualityLevel? recordStableThroughput(int bitsPerSecond) {
    _ensureSelected();
    if (_manual) return null;
    final index = _levels.indexOf(_current);
    if (index < 0 || index >= _levels.length - 1) return null;
    final currentTime = _now();
    if (currentTime.difference(_selectedAt!) < const Duration(seconds: 90)) {
      return null;
    }
    if (_lastSwitchAt != null &&
        currentTime.difference(_lastSwitchAt!) < const Duration(seconds: 60)) {
      return null;
    }
    final next = _levels[index + 1];
    if (bitsPerSecond <= next.bandwidth * 1.8) return null;
    _select(next, manual: false, switched: true);
    return next;
  }

  QualityLevel? _lower() {
    final index = _levels.indexOf(_current);
    if (index <= 0) return null;
    final lower = _levels[index - 1];
    _select(lower, manual: false, switched: true);
    return lower;
  }

  void _ensureSelected() {
    if (!_selected) selectInitial();
  }

  void _select(
    QualityLevel level, {
    required bool manual,
    required bool switched,
  }) {
    final currentTime = _now();
    _current = level;
    _selected = true;
    _manual = manual;
    _selectedAt = currentTime;
    if (switched) _lastSwitchAt = currentTime;
    _stalls.clear();
  }
}
