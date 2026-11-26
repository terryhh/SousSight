import 'dart:async';

import 'package:web/web.dart' as web;

Stream<void> connectivityChanges() {
  try {
    final online = web.EventStreamProviders.onlineEvent.forTarget(web.window);
    final offline = web.EventStreamProviders.offlineEvent.forTarget(web.window);
    late final StreamController<void> controller;
    final subscriptions = <StreamSubscription<web.Event>>[];
    controller = StreamController<void>(
      onListen: () {
        subscriptions
          ..add(online.listen((_) => controller.add(null)))
          ..add(offline.listen((_) => controller.add(null)));
      },
      onCancel: () async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        subscriptions.clear();
      },
    );
    return controller.stream;
  } catch (_) {
    return const Stream.empty();
  }
}
