import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/haptics.dart';
import '../scanner/domain/filters.dart';

/// Overridden in main() with the instance loaded before runApp.
final prefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('prefsProvider not overridden'),
);

@immutable
class AppSettings {
  const AppSettings({
    this.theme = ThemeMode.system,
    this.defaultFilter = ScanFilter.magic,
    this.haptics = true,
  });
  final ThemeMode theme;
  final ScanFilter defaultFilter;
  final bool haptics;

  AppSettings copyWith({
    ThemeMode? theme,
    ScanFilter? defaultFilter,
    bool? haptics,
  }) => AppSettings(
    theme: theme ?? this.theme,
    defaultFilter: defaultFilter ?? this.defaultFilter,
    haptics: haptics ?? this.haptics,
  );
}

class SettingsNotifier extends Notifier<AppSettings> {
  SharedPreferences get _p => ref.read(prefsProvider);

  @override
  AppSettings build() {
    final p = ref.watch(prefsProvider);
    final s = AppSettings(
      theme:
          ThemeMode.values.asNameMap()[p.getString('theme')] ??
          ThemeMode.system,
      defaultFilter:
          ScanFilter.values.asNameMap()[p.getString('defaultFilter')] ??
          ScanFilter.magic,
      haptics: p.getBool('haptics') ?? true,
    );
    Haptics.enabled = s.haptics;
    return s;
  }

  void setTheme(ThemeMode m) {
    _p.setString('theme', m.name);
    state = state.copyWith(theme: m);
  }

  void setDefaultFilter(ScanFilter f) {
    _p.setString('defaultFilter', f.name);
    state = state.copyWith(defaultFilter: f);
  }

  void setHaptics(bool on) {
    _p.setBool('haptics', on);
    Haptics.enabled = on;
    state = state.copyWith(haptics: on);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
