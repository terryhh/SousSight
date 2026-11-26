import 'package:web/web.dart' as web;

bool deviceOnline() {
  try {
    return web.window.navigator.onLine;
  } catch (_) {
    return true;
  }
}
