import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

// ── Section header ────────────────────────────────────────────
class SectionHeader extends StatelessWidget {
  final String title;
  final int? count;
  final Widget? action;

  const SectionHeader({super.key, required this.title, this.count, this.action});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(children: [
      Text(title, style: const TextStyle(
        fontSize: 22, fontWeight: FontWeight.w600,
        color: SanctumTheme.textPrimary, letterSpacing: -0.3,
      )),
      if (count != null) ...[
        const SizedBox(width: 8),
        Text('$count', style: const TextStyle(
          fontSize: 14, color: SanctumTheme.textTertiary,
        )),
      ],
      const Spacer(),
      if (action != null) action!,
    ]),
  );
}

// ── Gold add button ───────────────────────────────────────────
class GoldAddButton extends StatelessWidget {
  final VoidCallback onTap;
  final String label;

  const GoldAddButton({super.key, required this.onTap, required this.label});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: SanctumTheme.goldDim,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: SanctumTheme.gold.withValues(alpha: 0.25)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: const TextStyle(
          fontSize: 13, color: SanctumTheme.gold2, fontWeight: FontWeight.w500,
        )),
      ]),
    ),
  );
}

// ── Vault card base ───────────────────────────────────────────
class VaultCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final Color accentColor;

  const VaultCard({
    super.key, required this.child, this.onTap,
    this.accentColor = SanctumTheme.purple,
  });

  @override
  State<VaultCard> createState() => _VaultCardState();
}

class _VaultCardState extends State<VaultCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit:  (_) => setState(() => _hovered = false),
    child: GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          color: SanctumTheme.bg2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _hovered ? SanctumTheme.border2 : SanctumTheme.border,
            width: 0.5,
          ),
          boxShadow: _hovered
            ? [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 16, offset: const Offset(0, 6))]
            : [],
        ),
        child: Column(children: [
          // Accent bar at top
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: 2,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [widget.accentColor.withValues(alpha: _hovered ? 1 : 0), Colors.transparent],
              ),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: widget.child,
          ),
        ]),
      ),
    ),
  );
}

// ── Avatar circle ─────────────────────────────────────────────
class AvatarIcon extends StatelessWidget {
  final String? emoji;
  final String fallback;
  final Color background;
  final double size;

  const AvatarIcon({
    super.key, this.emoji, required this.fallback,
    required this.background, this.size = 36,
  });

  @override
  Widget build(BuildContext context) => Container(
    width: size, height: size,
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(size * 0.25),
    ),
    alignment: Alignment.center,
    child: Text(
      emoji ?? fallback[0].toUpperCase(),
      style: TextStyle(fontSize: size * 0.45),
    ),
  );
}

// ── Copy button ───────────────────────────────────────────────
class CopyButton extends StatefulWidget {
  final String text;
  final String? label;

  const CopyButton({super.key, required this.text, this.label});

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: _copy,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _copied ? SanctumTheme.greenDim : SanctumTheme.bg3,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: _copied
            ? SanctumTheme.green.withValues(alpha: 0.3)
            : SanctumTheme.border,
        ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(
          _copied ? Icons.check : Icons.copy_outlined,
          size: 11,
          color: _copied ? SanctumTheme.green : SanctumTheme.textTertiary,
        ),
        const SizedBox(width: 4),
        Text(
          _copied ? 'Copied!' : (widget.label ?? 'Copy'),
          style: TextStyle(
            fontSize: 11,
            color: _copied ? SanctumTheme.green : SanctumTheme.textTertiary,
          ),
        ),
      ]),
    ),
  );
}

// ── Strength bar ──────────────────────────────────────────────
class PasswordStrengthBar extends StatelessWidget {
  final int strength; // 0–5
  static const labels = [
    'Very weak', 'Weak', 'Fair', 'Good', 'Strong', 'Excellent',
  ];
  static const colors = [
    SanctumTheme.red, SanctumTheme.red, SanctumTheme.amber,
    SanctumTheme.amber, SanctumTheme.green, SanctumTheme.green,
  ];

  const PasswordStrengthBar({super.key, required this.strength});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: strength / 5,
          backgroundColor: SanctumTheme.bg4,
          valueColor: AlwaysStoppedAnimation(
            strength == 0 ? Colors.transparent : colors[strength],
          ),
          minHeight: 3,
        ),
      ),
      if (strength > 0) ...[
        const SizedBox(height: 4),
        Text(
          labels[strength],
          style: TextStyle(fontSize: 11, color: colors[strength]),
        ),
      ],
    ],
  );
}

// ── Chip filter ───────────────────────────────────────────────
class FilterChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const FilterChip({
    super.key, required this.label, required this.active, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: active ? SanctumTheme.goldDim : SanctumTheme.bg2,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: active
            ? SanctumTheme.gold.withValues(alpha: 0.3)
            : SanctumTheme.border,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: active ? SanctumTheme.gold2 : SanctumTheme.textTertiary,
          fontWeight: active ? FontWeight.w500 : FontWeight.w400,
        ),
      ),
    ),
  );
}

// ── Empty state ───────────────────────────────────────────────
class EmptyState extends StatelessWidget {
  final String emoji;
  final String title;
  final String subtitle;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.emoji,
    required this.title,
    required this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 40)),
          const SizedBox(height: 16),
          Text(title, style: const TextStyle(
            fontSize: 16, color: SanctumTheme.textSecondary,
            fontWeight: FontWeight.w500,
          )),
          const SizedBox(height: 6),
          Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(
            fontSize: 13, color: SanctumTheme.textTertiary, height: 1.6,
          )),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    ),
  );
}

// ── Sanctum text field ────────────────────────────────────────
class SanctumField extends StatelessWidget {
  final String label;
  final String? hint;
  final TextEditingController controller;
  final bool obscure;
  final Widget? suffix;
  final int maxLines;
  final TextInputType? keyboardType;

  const SanctumField({
    super.key,
    required this.label,
    this.hint,
    required this.controller,
    this.obscure = false,
    this.suffix,
    this.maxLines = 1,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(
        fontSize: 12, color: SanctumTheme.textTertiary, letterSpacing: 0.3,
      )),
      const SizedBox(height: 5),
      TextFormField(
        controller: controller,
        obscureText: obscure,
        maxLines: maxLines,
        keyboardType: keyboardType,
        style: const TextStyle(color: SanctumTheme.textPrimary, fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          suffixIcon: suffix,
        ),
      ),
      const SizedBox(height: 12),
    ],
  );
}

// ── Bottom sheet wrapper ──────────────────────────────────────
class SanctumBottomSheet extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const SanctumBottomSheet({super.key, required this.title, required this.children});

  static Future<T?> show<T>(BuildContext context, {
    required String title,
    required List<Widget> children,
  }) => showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: SanctumTheme.bg2,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => SanctumBottomSheet(title: title, children: children),
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      left: 20, right: 20, top: 20,
      bottom: MediaQuery.of(context).viewInsets.bottom + 20,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(child: Container(
          width: 36, height: 4,
          decoration: BoxDecoration(
            color: SanctumTheme.border2,
            borderRadius: BorderRadius.circular(2),
          ),
        )),
        const SizedBox(height: 16),
        Text(title, style: const TextStyle(
          fontSize: 18, fontWeight: FontWeight.w600,
          color: SanctumTheme.textPrimary,
        )),
        const SizedBox(height: 16),
        ...children,
      ],
    ),
  );
}
