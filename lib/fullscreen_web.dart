import 'dart:js_interop';
import 'package:web/web.dart' as web;

Future<void> toggleFullscreen() async {
  final document = web.window.document;
  if (document.fullscreenElement != null) {
    await document.exitFullscreen().toDart;
  } else {
    final root = document.documentElement;
    if (root != null) await root.requestFullscreen().toDart;
  }
}
