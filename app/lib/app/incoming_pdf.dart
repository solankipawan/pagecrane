import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/widgets/common.dart';
import 'router.dart';

/// "Open with Pagecrane" (Android MainActivity / iOS OpenPdfHandler) copies the incoming PDF into the
/// app cache (after validating it) and reports it on `pagecrane/open`; this opens
/// it in the reader. A cold start's file is collected with `takePending`.
class IncomingPdf {
  static const _channel = MethodChannel('pagecrane/open');
  static String? _lastPath;

  static void init() {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'opened') _handle(call.arguments);
      return true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final pending = await _channel.invokeMethod<Object?>('takePending');
        if (pending != null) _handle(pending);
      } on PlatformException {
        // Nothing to open.
      }
    });
  }

  static void _handle(Object? args) {
    if (args is! Map) return;
    final m = args.cast<Object?, Object?>();
    final error = m['error'];
    if (error is String) {
      rootMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(error)),
      );
      return;
    }
    final path = m['path'];
    // A cold start may deliver the same file twice (event + takePending).
    if (path is! String || path == _lastPath) return;
    _lastPath = path;
    final name = m['name'] is String ? m['name']! as String : 'Document';
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => router.push('/open', extra: (path: path, name: name)),
    );
    WidgetsBinding.instance.scheduleFrame();
  }
}
