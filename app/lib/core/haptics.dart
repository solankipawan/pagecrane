import 'package:flutter/services.dart';

/// Thin wrapper so every call site respects the user's Haptics setting.
class Haptics {
  static bool enabled = true;

  static void select() {
    if (enabled) HapticFeedback.selectionClick();
  }

  static void light() {
    if (enabled) HapticFeedback.lightImpact();
  }

  static void medium() {
    if (enabled) HapticFeedback.mediumImpact();
  }

  static void success() {
    if (enabled) HapticFeedback.heavyImpact();
  }
}
