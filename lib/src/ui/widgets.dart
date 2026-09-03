import 'package:flutter/material.dart';

import 'theme.dart';

/// Small pill used for chip type, link speed, verification state.
class SyncnChip extends StatelessWidget {
  const SyncnChip({
    super.key,
    required this.label,
    this.color,
    this.icon,
  });

  final String label;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = SyncnPalette.of(context);
    final c = color ?? p.accent;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: p.isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: c),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: c,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

/// A label/value row. Values that are addresses, hashes or IDs are set in a
/// mono stack with tabular figures so columns line up.
class DetailRow extends StatelessWidget {
  const DetailRow({
    super.key,
    required this.label,
    required this.value,
    this.mono = false,
    this.valueColor,
  });

  final String label;
  final String value;
  final bool mono;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final p = SyncnPalette.of(context);
    final t = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(label, style: t.bodySmall?.copyWith(color: p.muted)),
          ),
          Expanded(
            child: Text(
              value,
              style: (mono ? t.bodySmall : t.bodyMedium)?.copyWith(
                color: valueColor ?? p.ink,
                fontFamily: mono ? 'monospace' : null,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Section heading with an overline label.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = SyncnPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: p.muted,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// A banner that states a problem and what to do about it.
///
/// The copy rule is deliberate: never surface a raw protocol error on its own,
/// always pair it with the next action.
class AdviceBanner extends StatelessWidget {
  const AdviceBanner({
    super.key,
    required this.message,
    this.advice,
    this.tone = AdviceTone.warning,
  });

  final String message;
  final String? advice;
  final AdviceTone tone;

  @override
  Widget build(BuildContext context) {
    final p = SyncnPalette.of(context);
    final color = switch (tone) {
      AdviceTone.warning => p.warning,
      AdviceTone.danger => p.danger,
      AdviceTone.success => p.success,
      AdviceTone.info => p.accent,
    };
    final icon = switch (tone) {
      AdviceTone.warning => Icons.warning_amber_rounded,
      AdviceTone.danger => Icons.error_outline_rounded,
      AdviceTone.success => Icons.check_circle_outline_rounded,
      AdviceTone.info => Icons.info_outline_rounded,
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: p.isDark ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(SyncnRadius.def),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: p.ink,
                        fontWeight: FontWeight.w600,
                      ),
                ),
                if (advice != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    advice!,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: p.muted),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum AdviceTone { info, success, warning, danger }
