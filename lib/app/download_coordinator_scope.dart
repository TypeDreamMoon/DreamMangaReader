import 'package:flutter/widgets.dart';

import '../core/downloads/download_coordinator.dart';

class DownloadCoordinatorScope extends InheritedNotifier<DownloadCoordinator> {
  const DownloadCoordinatorScope({
    super.key,
    required DownloadCoordinator coordinator,
    required super.child,
  }) : super(notifier: coordinator);

  static DownloadCoordinator of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<DownloadCoordinatorScope>();
    assert(scope != null, 'DownloadCoordinatorScope not found');
    return scope!.notifier!;
  }

  static DownloadCoordinator read(BuildContext context) {
    final scope =
        context.getInheritedWidgetOfExactType<DownloadCoordinatorScope>();
    assert(scope != null, 'DownloadCoordinatorScope not found');
    return scope!.notifier!;
  }
}
