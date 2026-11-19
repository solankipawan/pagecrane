import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/glass.dart';
import '../../app/theme/tokens.dart';
import '../../features/scanner/presentation/capture_sheet.dart';
import '../haptics.dart';

/// Bottom navigation: Home · Files · [Scan FAB] · Tools · Settings, on glass.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  static const _tabs = [
    (Icons.home_rounded, 'Home'),
    (Icons.folder_rounded, 'Files'),
    (Icons.grid_view_rounded, 'Tools'),
    (Icons.settings_rounded, 'Settings'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      // Cards on the tab pages only ever sit over the static aurora, so they skip the
      // blur (FlatGlassScope). The tab bar sits outside and keeps a real blur for
      // content scrolling under it, switched on after the first frame.
      body: AuroraBackground(child: FlatGlassScope(child: shell)),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.fromLTRB(14, 0, 14, bottom > 0 ? bottom : 14),
        child: SizedBox(
          height: 96,
          child: Stack(
            alignment: Alignment.bottomCenter,
            clipBehavior: Clip.none,
            children: [
              SizedBox(
                height: 68,
                child: DeferredGlassSurface(
                  radius: 26,
                  child: Row(
                    children: [
                      _tab(context, 0),
                      _tab(context, 1),
                      const Expanded(child: SizedBox()),
                      _tab(context, 2),
                      _tab(context, 3),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: 0,
                child: _ScanFab(onTap: () => startScan(context, ref)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tab(BuildContext context, int i) {
    final (icon, label) = _tabs[i];
    final on = shell.currentIndex == i;
    final color = on ? context.cs.primary : context.px.muted;
    return Expanded(
      child: Semantics(
        selected: on,
        button: true,
        label: label,
        child: InkResponse(
          onTap: () {
            Haptics.select();
            shell.goBranch(i, initialLocation: i == shell.currentIndex);
          },
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedScale(
                scale: on ? 1.08 : 1,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutBack,
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScanFab extends StatefulWidget {
  const _ScanFab({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_ScanFab> createState() => _ScanFabState();
}

class _ScanFabState extends State<_ScanFab> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Scan document',
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? 0.92 : 1,
          duration: const Duration(milliseconds: 160),
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF5B6BFF), Color(0xFF8B5CFF)],
              ),
              border: Border.all(
                color: Theme.of(context).scaffoldBackgroundColor,
                width: 5,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x8C4C5BFF),
                  blurRadius: 28,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: const Icon(
              Icons.document_scanner_rounded,
              color: Colors.white,
              size: 26,
            ),
          ),
        ),
      ),
    );
  }
}
