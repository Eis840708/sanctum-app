import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/i18n/lang_provider.dart';
import '../../../core/i18n/theme_provider.dart';
import '../../../core/storage/providers.dart';
import '../../../shared/theme/app_theme.dart';
import 'backup_screen.dart';
import 'shamir_screen.dart';
import '../../transfer/screens/transfer_screen.dart';
import '../../../core/storage/vault_service.dart';
import '../../passwords/screens/import_passwords_screen.dart';
import '../../../main.dart' show LangSelector;

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(langProvider);
    final sc = context.sc;
    final autoLockSecs = ref.watch(inactivityTimeoutProvider);
    final themeMode = ref.watch(themeProvider);

    return CustomScrollView(slivers: [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        sliver: SliverToBoxAdapter(child: Text(S.settings, style: TextStyle(
          fontSize: 22, fontWeight: FontWeight.w600,
          color: sc.textPrimary, letterSpacing: -0.3,
        ))),
      ),
      SliverPadding(
        padding: const EdgeInsets.all(16),
        sliver: SliverList(delegate: SliverChildListDelegate([

          _Section(title: S.security, rows: [
            _Row(icon: Icons.shield_outlined, iconColor: SanctumTheme.purple,
              label: S.encryption,
              trailing: Text('AES-256-GCM', style: TextStyle(fontSize: 12, color: sc.textTertiary))),
            _Row(icon: Icons.key_outlined, iconColor: SanctumTheme.gold,
              label: S.keyDerivation,
              // v3 vaults derive the KEK with Argon2id; legacy v2 uses PBKDF2.
              // Show the value that matches the current vault (A-1 accuracy).
              trailing: Text(vaultService.isV3Vault ? 'Argon2id' : 'PBKDF2-SHA256',
                  style: TextStyle(fontSize: 12, color: sc.textTertiary))),
            _Row(
              icon: Icons.shield_moon_outlined, iconColor: SanctumTheme.gold,
              label: S.shamirBackup,
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => ShamirScreen())),
            ),
            _Row(
              icon: Icons.lock_clock, iconColor: SanctumTheme.purple,
              label: S.autoLock,
              trailing: Text(
                autoLockSecs == 0 ? S.never : S.lockSecs(autoLockSecs),
                style: TextStyle(fontSize: 12, color: sc.textTertiary),
              ),
              onTap: () {
                int cur = ref.read(inactivityTimeoutProvider);
                showDialog(
                  context: context,
                  builder: (_) => StatefulBuilder(
                    builder: (ctx, ss) => AlertDialog(
                      backgroundColor: sc.bg2,
                      title: Text(S.autoLock, style: TextStyle(color: sc.textPrimary)),
                      content: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(cur == 0 ? S.never : S.lockSecs(cur),
                          style: const TextStyle(color: SanctumTheme.gold, fontSize: 20)),
                        Slider(
                          value: cur.toDouble(), min: 0, max: 120, divisions: 12,
                          activeColor: SanctumTheme.gold,
                          inactiveColor: sc.border,
                          onChanged: (v) => ss(() => cur = v.round()),
                        ),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(S.never, style: TextStyle(color: sc.textTertiary, fontSize: 11)),
                            Text('120 ${S.secsUnit}', style: TextStyle(color: sc.textTertiary, fontSize: 11)),
                          ]),
                      ]),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx),
                          child: Text(S.cancel, style: TextStyle(color: sc.textTertiary))),
                        TextButton(
                          onPressed: () {
                            ref.read(inactivityTimeoutProvider.notifier).state = cur;
                            if (cur > 0) ref.read(inactivityProvider.notifier).resetTimer();
                            else ref.read(inactivityProvider.notifier).cancel();
                            Navigator.pop(ctx);
                          },
                          child: Text(S.confirm, style: TextStyle(color: SanctumTheme.gold))),
                      ],
                    ),
                  ),
                );
              },
            ),
            // NOT const: a const child is canonicalised and skipped on parent
            // rebuild, so its S.get(...) label would stay in the previous locale
            // until toggled (W-C reactive-label fix). Rebuild it on lang change.
            // ignore: prefer_const_constructors
            _BiometricTile(),
          ]),

          const SizedBox(height: 20),

          _Section(title: S.backup, rows: [
            _Row(
              icon: Icons.backup_outlined, iconColor: SanctumTheme.blue,
              label: S.backupVault, sublabel: S.backupSublabel,
              trailing: Icon(Icons.chevron_right, size: 18, color: sc.textTertiary),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BackupScreen())),
            ),
            _Row(
              icon: Icons.download_outlined, iconColor: SanctumTheme.amber,
              label: S.restore,
              trailing: Icon(Icons.chevron_right, size: 18, color: sc.textTertiary),
              onTap: () => _showRestoreInfo(context),
            ),
            _Row(
              icon: Icons.swap_horiz_rounded, iconColor: SanctumTheme.gold,
              label: S.deviceTransfer, sublabel: S.deviceTransferSub,
              trailing: Icon(Icons.chevron_right, size: 18, color: sc.textTertiary),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const TransferScreen())),
            ),
          ]),

          const SizedBox(height: 20),

          _Section(title: S.dataManagement, rows: [
            _Row(
              icon: Icons.download_outlined, iconColor: sc.textSecondary,
              label: S.importCsv,
              trailing: Icon(Icons.chevron_right, size: 18, color: sc.textTertiary),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ImportPasswordsScreen())),
            ),
            _Row(
              icon: Icons.delete_forever_outlined, iconColor: SanctumTheme.red,
              label: S.clearData, labelColor: SanctumTheme.red,
              trailing: Icon(Icons.chevron_right, size: 18, color: SanctumTheme.red),
              onTap: () => _clearAll(context, ref),
            ),
          ]),

          const SizedBox(height: 20),

          // ── Appearance ───────────────────────────────────────
          _Section(title: S.themeMode, rows: [
            _ThemeRow(current: themeMode, onChanged: (m) => ref.read(themeProvider.notifier).setTheme(m)),
          ]),

          const SizedBox(height: 20),

          // ── Language ─────────────────────────────────────────
          _Section(title: S.language, rows: [
            _Row(
              icon: Icons.language, iconColor: SanctumTheme.blue,
              label: S.language,
              trailing: const LangSelector(),
            ),
          ]),

          const SizedBox(height: 20),

          _Section(title: S.about, rows: [
            _Row(icon: Icons.info_outline, iconColor: sc.textTertiary,
              label: S.version,
              trailing: Text('Sanctum 1.5.0', style: TextStyle(fontSize: 12, color: sc.textTertiary))),
            _Row(icon: Icons.cloud_off, iconColor: sc.textTertiary,
              label: S.storage,
              trailing: Text(S.localOnly, style: const TextStyle(fontSize: 12, color: SanctumTheme.green))),
            _Row(icon: Icons.wifi_off, iconColor: sc.textTertiary,
              label: S.network,
              trailing: Text(S.zeroRequests, style: const TextStyle(fontSize: 12, color: SanctumTheme.green))),
          ]),

          const SizedBox(height: 20),

          GestureDetector(
            onTap: () => ref.read(authProvider.notifier).lock(),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: sc.bg2,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: sc.border),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.lock_outline, size: 16, color: sc.textSecondary),
                const SizedBox(width: 8),
                Text(S.lockVault, style: TextStyle(fontSize: 15, color: sc.textSecondary)),
              ]),
            ),
          ),
          const SizedBox(height: 32),
        ])),
      ),
    ]);
  }

  void _showRestoreInfo(BuildContext context) {
    final sc = context.sc;
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: sc.bg2,
      title: Text(S.restore, style: TextStyle(color: sc.textPrimary, fontSize: 16)),
      content: Text(S.get('restoreDesc'),
        style: TextStyle(color: sc.textSecondary, fontSize: 13, height: 1.6)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context),
          child: const Text('OK', style: TextStyle(color: SanctumTheme.gold))),
      ],
    ));
  }

  void _clearAll(BuildContext context, WidgetRef ref) {
    final sc = context.sc;
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: sc.bg2,
      title: Text(S.clearData, style: TextStyle(color: sc.textPrimary)),
      content: Text(S.clearConfirm, style: TextStyle(color: sc.textSecondary, fontSize: 14, height: 1.5)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context),
          child: Text(S.cancel, style: TextStyle(color: sc.textSecondary))),
        TextButton(
          onPressed: () async {
            Navigator.pop(context);
            await vaultService.clearVault();
            ref.read(authProvider.notifier).lock();
          },
          child: Text(S.delete, style: const TextStyle(color: SanctumTheme.red))),
      ],
    ));
  }
}

// ── Theme selector row ────────────────────────────────────────
class _ThemeRow extends StatelessWidget {
  final ThemeMode current;
  final ValueChanged<ThemeMode> onChanged;
  const _ThemeRow({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(children: [
        Container(width: 28, height: 28,
          decoration: BoxDecoration(
            color: SanctumTheme.gold.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(7)),
          child: const Icon(Icons.contrast, size: 15, color: SanctumTheme.gold)),
        const SizedBox(width: 12),
        Expanded(child: Text(S.themeMode, style: TextStyle(fontSize: 14, color: sc.textPrimary))),
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(color: sc.bg3, borderRadius: BorderRadius.circular(8)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _ThemeBtn(icon: Icons.brightness_auto, label: S.themeSystem,
              active: current == ThemeMode.system,
              onTap: () => onChanged(ThemeMode.system)),
            _ThemeBtn(icon: Icons.light_mode_outlined, label: S.themeLight,
              active: current == ThemeMode.light,
              onTap: () => onChanged(ThemeMode.light)),
            _ThemeBtn(icon: Icons.dark_mode_outlined, label: S.themeDark,
              active: current == ThemeMode.dark,
              onTap: () => onChanged(ThemeMode.dark)),
          ]),
        ),
      ]),
    );
  }
}

class _ThemeBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _ThemeBtn({required this.icon, required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: active ? sc.bg2 : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: active ? Border.all(color: SanctumTheme.gold.withValues(alpha: 0.4)) : null,
          boxShadow: active ? [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 4)] : null,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: active ? SanctumTheme.gold : sc.textTertiary),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(
            fontSize: 11, fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? SanctumTheme.gold : sc.textTertiary)),
        ]),
      ),
    );
  }
}

// ── Section card ──────────────────────────────────────────────
class _Section extends StatelessWidget {
  final String title;
  final List<Widget> rows;
  const _Section({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(title.toUpperCase(), style: TextStyle(
          fontSize: 10, color: sc.textTertiary, letterSpacing: 0.8)),
      ),
      Container(
        decoration: BoxDecoration(
          color: sc.bg2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sc.border, width: 0.5),
        ),
        child: Column(children: rows.asMap().entries.map((e) => Column(children: [
          e.value,
          if (e.key < rows.length - 1) Divider(height: 0.5, color: sc.border, indent: 48),
        ])).toList()),
      ),
    ]);
  }
}

// ── Settings row ──────────────────────────────────────────────
class _Row extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String? sublabel;
  final Color? labelColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _Row({
    required this.icon, required this.iconColor, required this.label,
    this.sublabel, this.labelColor, this.trailing, this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(color: iconColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(7)),
            child: Icon(icon, size: 15, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 14, color: labelColor ?? sc.textPrimary)),
            if (sublabel != null)
              Text(sublabel!, style: TextStyle(fontSize: 11, color: sc.textTertiary)),
          ])),
          if (trailing != null) trailing!,
        ]),
      ),
    );
  }
}

// ── Biometric opt-in (V-05) ──────────────────────────────────
// Explicit opt-in toggle: biometric unlock is never auto-enabled. Hidden when the
// device has no biometric hardware. (Auth-bound key binding + protection-level
// display land in B2-5a; this toggle governs enablement only.)
class _BiometricTile extends StatefulWidget {
  const _BiometricTile();
  @override
  State<_BiometricTile> createState() => _BiometricTileState();
}

class _BiometricTileState extends State<_BiometricTile> {
  bool _loaded = false;
  bool _supported = false;
  bool _enabled = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final supported = await vaultService.canUseBiometric();
    final enabled = await vaultService.hasBiometricEnabled();
    if (!mounted) return;
    setState(() { _supported = supported; _enabled = enabled; _loaded = true; });
  }

  Future<void> _set(bool on) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (on) {
        await vaultService.enableBiometric();
      } else {
        await vaultService.disableBiometric();
      }
      if (mounted) setState(() => _enabled = on);
    } catch (_) {
      // Leave state unchanged on failure (e.g. vault locked).
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || !_supported) return const SizedBox.shrink();
    return _Row(
      icon: Icons.fingerprint,
      iconColor: SanctumTheme.purple,
      label: S.get('bioUnlock'),
      trailing: Switch(
        value: _enabled,
        activeThumbColor: SanctumTheme.gold,
        onChanged: _busy ? null : _set,
      ),
    );
  }
}
