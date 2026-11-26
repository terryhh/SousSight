import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';

/// The app-lifetime handle that keeps the semantics tree on (SS-118).
///
/// Never disposed in production: disposing the last handle would switch the
/// tree off again.
SemanticsHandle? _webSemanticsHandle;

/// Turns Flutter's semantics tree on at startup on web (SS-118, A11Y-06).
///
/// By default Flutter web renders no accessibility DOM. It shows only a 1×1
/// px "Enable accessibility" placeholder, which a screen reader must find
/// and press first. Voice control, switch access, Lighthouse and axe never
/// press it, so they see an app with no named controls. Holding a
/// [SemanticsHandle] makes the framework send semantics updates. On the
/// first update the web engine turns its own semantics on and removes the
/// placeholder.
///
/// Call once from `main()` after `WidgetsFlutterBinding.ensureInitialized()`.
/// It is idempotent: later calls return the same handle. Off web it does
/// nothing and returns null, because Android and iOS already enable
/// semantics whenever TalkBack, VoiceOver or Switch Control is running.
///
/// [isWeb] and [binding] are injectable for tests.
SemanticsHandle? enableWebSemantics({
  bool isWeb = kIsWeb,
  SemanticsBinding? binding,
}) {
  if (!isWeb) return null;
  return _webSemanticsHandle ??= (binding ?? SemanticsBinding.instance)
      .ensureSemantics();
}

/// Releases the handle taken by [enableWebSemantics], for tests only.
@visibleForTesting
void debugResetWebSemantics() {
  _webSemanticsHandle?.dispose();
  _webSemanticsHandle = null;
}
