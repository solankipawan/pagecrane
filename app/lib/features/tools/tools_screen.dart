import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/glass.dart';
import '../../app/theme/tokens.dart';
import '../../core/widgets/common.dart';
import 'tool_catalog.dart';

class ToolsScreen extends ConsumerWidget {
  const ToolsScreen({super.key});

  static const _groups = [
    ('PDF', ['merge', 'split', 'compress', 'sign']),
    ('Image', ['target', 'resize']),
    ('Convert', ['convert', 'pdf2img', 'importpdf']),
    ('Capture', ['scan']),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final px = context.px;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        20,
        MediaQuery.paddingOf(context).top + 12,
        20,
        140,
      ),
      children: [
        Text('Tools', style: context.tt.headlineLarge),
        for (final (group, ids) in _groups) ...[
          SectionLabel(group),
          GlassSurface(
            child: Column(
              children: [
                for (final (k, id) in ids.indexed)
                  InkWell(
                    onTap: () => openTool(context, ref, tools[id]!),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        border: k < ids.length - 1
                            ? Border(bottom: BorderSide(color: px.hairline))
                            : null,
                      ),
                      child: Row(
                        children: [
                          ToolIcon(
                            tools[id]!.icon,
                            context.categoryColor(tools[id]!.cat),
                            size: 36,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  tools[id]!.name,
                                  style: context.tt.titleMedium,
                                ),
                                Text(
                                  tools[id]!.desc,
                                  style: context.tt.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          if (!tools[id]!.available)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: px.hairline,
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Text(
                                'Soon',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: px.muted,
                                ),
                              ),
                            ),
                          Icon(Icons.chevron_right_rounded, color: px.muted),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
