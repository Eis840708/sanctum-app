import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/crypto/v3/vault_v3_backup.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/i18n/lang_provider.dart';
import '../../../core/storage/providers.dart';
import '../../../core/storage/vault_service.dart';
import '../../../shared/theme/app_theme.dart';

// Conditional imports for mobile only
import 'backup_mobile.dart' if (dart.library.html) 'backup_web.dart';

class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});
  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _backingUp  = false;
  bool _restoring  = false;
  bool _localDone  = false;
  bool _cloudDone  = false;
  String? _error;
  DateTime? _lastBackup;

  @override
  Widget build(BuildContext context) {
    ref.watch(langProvider);
    final sc = context.sc;
    return Scaffold(
      backgroundColor: sc.bg,
      appBar: AppBar(
        backgroundColor: sc.bg2,
        title: Text(S.backup, style: TextStyle(color: sc.textPrimary)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: sc.textSecondary),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ── Header card ──────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [SanctumTheme.gold.withValues(alpha: 0.15), sc.bg2],
                begin: Alignment.topLeft, end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: SanctumTheme.gold.withValues(alpha: 0.2)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('🔐', style: TextStyle(fontSize: 32)),
              const SizedBox(height: 12),
              Text(S.get('backup2Layer'), style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w600, color: sc.textPrimary)),
              const SizedBox(height: 6),
              Text(
                S.get('backupHeaderDesc'),
                style: TextStyle(fontSize: 13, color: sc.textSecondary, height: 1.6)),
              if (_lastBackup != null) ...[
                const SizedBox(height: 10),
                Row(children: [
                  const Icon(Icons.check_circle, size: 14, color: SanctumTheme.green),
                  const SizedBox(width: 6),
                  Text('${S.get('backupLast')}: ${_fmt(_lastBackup!)}',
                    style: const TextStyle(fontSize: 12, color: SanctumTheme.green)),
                ]),
              ],
            ]),
          ),

          const SizedBox(height: 24),

          // ── Web notice ───────────────────────────────────
          if (kIsWeb) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: SanctumTheme.amberDim,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: SanctumTheme.amber.withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                const Text('⚠️', style: TextStyle(fontSize: 20)),
                const SizedBox(width: 12),
                Expanded(child: Text(
                  S.get('backupWebNotice'),
                  style: const TextStyle(fontSize: 13, color: SanctumTheme.amber, height: 1.5),
                )),
              ]),
            ),
            const SizedBox(height: 20),
          ],

          // ── Step 1: Local backup ─────────────────────────
          _StepCard(
            number: '1',
            title: S.get('backupLocalTitle'),
            subtitle: S.get('backupLocalSub'),
            done: _localDone,
          ),
          const SizedBox(height: 10),
          _StepCard(
            number: '2',
            title: S.get('backupCloudTitle'),
            subtitle: S.get('backupCloudSub'),
            done: _cloudDone,
          ),

          const SizedBox(height: 24),

          // ── Backup button ────────────────────────────────
          if (!_localDone && !_backingUp)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: kIsWeb ? null : _startBackup,
                icon: const Icon(Icons.backup_outlined, size: 18),
                label: Text(S.get('backupStart')),
              ),
            ),

          if (_backingUp)
            Center(child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                const CircularProgressIndicator(color: SanctumTheme.gold),
                const SizedBox(height: 12),
                Text(S.get('backupEncrypting'), style: TextStyle(color: sc.textSecondary, fontSize: 13)),
              ]),
            )),

          // ── Cloud options (after local done) ─────────────
          if (_localDone && !_cloudDone) ...[
            Text(S.get('backupStep2'), style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600, color: sc.textPrimary)),
            const SizedBox(height: 12),
            ..._cloudOptions.map((opt) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _CloudCard(
                emoji: opt['emoji']!,
                title: opt['title']!,
                subtitle: opt['subtitle']!,
                onTap: () => _shareCloud(),
              ),
            )),
          ],

          // ── Success ──────────────────────────────────────
          if (_localDone && _cloudDone)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: SanctumTheme.greenDim,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: SanctumTheme.green.withValues(alpha: 0.3)),
              ),
              child: Column(children: [
                const Text('✅', style: TextStyle(fontSize: 32)),
                const SizedBox(height: 10),
                Text(S.get('backupDone'), style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: SanctumTheme.green)),
                const SizedBox(height: 6),
                Text(S.get('backupDoneSub'),
                  style: TextStyle(fontSize: 13, color: sc.textSecondary)),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => setState(() { _localDone = false; _cloudDone = false; _error = null; }),
                  child: Text(S.get('backupAgain'), style: const TextStyle(color: SanctumTheme.gold)),
                ),
              ]),
            ),

          // ── Error ────────────────────────────────────────
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: SanctumTheme.redDim,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: SanctumTheme.red.withValues(alpha: 0.3)),
                ),
                child: Row(children: [
                  const Icon(Icons.error_outline, color: SanctumTheme.red, size: 16),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_error!, style: const TextStyle(fontSize: 12, color: SanctumTheme.red))),
                ]),
              ),
            ),

          const SizedBox(height: 32),

          // ── Restore section ──────────────────────────────
          Text(S.get('restoreSection'), style: TextStyle(
            fontSize: 10, color: sc.textTertiary, letterSpacing: 0.8)),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: sc.bg2,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sc.border),
            ),
            child: Column(children: [
              _RestoreRow(
                icon: Icons.file_open_outlined,
                iconColor: SanctumTheme.blue,
                label: S.get('restoreFromFile'),
                onTap: _restoring ? null : _restoreFromFile,
                loading: _restoring,
              ),
            ]),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: sc.bg3,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: sc.border),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline, size: 13, color: sc.textTertiary),
              const SizedBox(width: 8),
              Expanded(child: Text(
                S.get('restoreWarn'),
                style: TextStyle(fontSize: 12, color: sc.textTertiary, height: 1.5),
              )),
            ]),
          ),

          const SizedBox(height: 16),

          // ── Info box ─────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: sc.bg3,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: sc.border),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(S.get('backupHowTitle'), style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: sc.textSecondary)),
              const SizedBox(height: 8),
              _InfoRow(icon: '🔐', text: S.get('backupHow1')),
              _InfoRow(icon: '📱', text: S.get('backupHow2')),
              _InfoRow(icon: '☁️', text: S.get('backupHow3')),
              _InfoRow(icon: '🔑', text: S.get('backupHow4')),
            ]),
          ),
        ]),
      ),
    );
  }

  Future<void> _startBackup() async {
    setState(() { _backingUp = true; _error = null; });
    try {
      final date = DateTime.now();
      if (vaultService.isV3Vault) {
        // v3: binary SNCB3 two-layer container (inner per-field envelopes +
        // outer backup_key). No plaintext is written to disk.
        final bytes = await vaultService.exportVaultV3Backup();
        await BackupHelper.saveLocalBytes(bytes, date);
      } else {
        // v2: existing JSON path (unchanged).
        final data = await vaultService.exportVaultJson();
        final json = const JsonEncoder.withIndent('  ').convert(data);
        await BackupHelper.saveLocal(json, date);
      }
      setState(() { _localDone = true; _backingUp = false; _lastBackup = date; });
    } catch (e) {
      setState(() { _backingUp = false; _error = '${S.get('backupFailed')}${S.colon}$e'; });
    }
  }

  Future<void> _shareCloud() async {
    try {
      await BackupHelper.shareFile();
      setState(() => _cloudDone = true);
    } catch (e) {
      setState(() => _error = '${S.get('shareFailed')}${S.colon}$e');
    }
  }

  Future<void> _restoreFromFile() async {
    final sc = context.sc;
    // Confirm before overwriting existing data
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: sc.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(S.restore, style: TextStyle(color: sc.textPrimary, fontWeight: FontWeight.w600)),
        content: Text(
          S.get('restoreConfirmBody'),
          style: TextStyle(color: sc.textSecondary, fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false),
            child: Text(S.cancel, style: TextStyle(color: sc.textSecondary))),
          TextButton(onPressed: () => Navigator.pop(d, true),
            child: Text(S.get('restoreConfirmYes'), style: const TextStyle(color: SanctumTheme.red, fontWeight: FontWeight.w600))),
        ],
      ),
    ) ?? false;

    if (!confirmed) return;

    setState(() { _restoring = true; _error = null; });
    try {
      // Read the raw bytes ONCE, then detect format by magic (never by trial).
      final bytes = await BackupHelper.readBackupBytes();
      if (VaultV3Backup.isBackupV3(bytes)) {
        await _restoreV3(bytes); // owns its password prompt + unified errors
      } else {
        await _restoreV2FromBytes(bytes); // v2 JSON path (unchanged behaviour)
      }
    } catch (e) {
      // Reached only for v2 / file-read errors; v3 handles its own messaging.
      if (mounted) setState(() => _error = '${S.get('restoreFailed')}${S.colon}$e');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  /// v3 restore: prompt the master password (the decryption key), then import
  /// transactionally. On ANY failure show a single unified message (no oracle)
  /// and leave the existing vault intact; on success force a re-lock (B.4).
  Future<void> _restoreV3(Uint8List bytes) async {
    final pw = await _promptMasterPassword();
    if (pw == null) return; // cancelled — abort quietly, existing vault intact
    try {
      await vaultService.importV3Backup(bytes, masterPassword: pw);
    } catch (_) {
      // B3-a: wrong password / tampered / truncated -> ONE message, no detail.
      // B3-d: service is transactional (pre-commit reject) -> no partial state.
      if (mounted) setState(() => _error = S.get('restoreBadPw'));
      return;
    }
    if (!mounted) return;
    // B.4: forced re-lock — no prefilled password.
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: context.sc.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          const Text('✅ ', style: TextStyle(fontSize: 20)),
          Text(S.get('restoreDone'), style: TextStyle(color: context.sc.textPrimary, fontWeight: FontWeight.w600)),
        ]),
        content: Text(
          S.get('restoreDoneReunlock'),
          style: TextStyle(color: context.sc.textSecondary, fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context); // close dialog
              ref.read(authProvider.notifier).lock();
            },
            child: Text(S.confirm, style: const TextStyle(color: SanctumTheme.gold, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  /// v2 restore from raw bytes. Applies the SAME sanity check as
  /// BackupHelper.readBackupFile (B5-b: not weakened) before importing.
  Future<void> _restoreV2FromBytes(Uint8List bytes) async {
    final sc = context.sc;
    late final Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } on FormatException {
      throw Exception(S.get('restoreBadFormat'));
    }
    if (!json.containsKey('passwords') && !json.containsKey('diary')) {
      throw Exception(S.get('restoreBadFormat'));
    }
    final needsReunlock = await vaultService.importFromBackup(json);
    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: sc.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          const Text('✅ ', style: TextStyle(fontSize: 20)),
          Text(S.get('restoreDone'), style: TextStyle(color: sc.textPrimary, fontWeight: FontWeight.w600)),
        ]),
        content: Text(
          needsReunlock
            ? S.get('restoreDoneReunlock2')
            : S.get('restoreDoneSimple'),
          style: TextStyle(color: sc.textSecondary, fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context); // close dialog
              if (needsReunlock) {
                ref.read(authProvider.notifier).lock();
              } else {
                Navigator.pop(context); // back to settings
              }
            },
            child: Text(S.confirm, style: const TextStyle(color: SanctumTheme.gold, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  /// Master-password prompt for a v3 restore. Returns the entered password, or
  /// null on cancel. The controller lives in [_MasterPasswordDialog]'s State and
  /// is disposed with it (after the route is removed), avoiding a use-after-dispose
  /// during the dialog's dismiss animation. B3-b preserved: obscure, no
  /// autofill/suggestions, and the value never enters app state/provider.
  Future<String?> _promptMasterPassword() => showDialog<String>(
        context: context,
        builder: (_) => const _MasterPasswordDialog(),
      );

  List<Map<String, String>> get _cloudOptions => [
    {'emoji': '📦', 'title': 'Google Drive', 'subtitle': S.get('cloudDriveSub')},
    {'emoji': '📧', 'title': S.get('cloudEmailTitle'), 'subtitle': S.get('cloudEmailSub')},
    {'emoji': '💬', 'title': 'WhatsApp / LINE', 'subtitle': S.get('cloudMsgSub')},
    {'emoji': '📋', 'title': S.get('cloudLocalTitle'), 'subtitle': S.get('cloudLocalSub')},
  ];

  String _fmt(DateTime d) =>
    '${d.year}/${d.month.toString().padLeft(2,'0')}/${d.day.toString().padLeft(2,'0')} '
    '${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
}

// ── Sub-widgets ───────────────────────────────────────────

/// Master-password prompt for a v3 restore. The password is used solely as the
/// decryption key and is never stored (B3-b): no autofill/suggestions, the
/// controller is owned by this State and disposed with it, and the value never
/// enters app state/provider.
class _MasterPasswordDialog extends StatefulWidget {
  const _MasterPasswordDialog();
  @override
  State<_MasterPasswordDialog> createState() => _MasterPasswordDialogState();
}

class _MasterPasswordDialogState extends State<_MasterPasswordDialog> {
  final _ctrl = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _ctrl.dispose(); // after the route is removed — no dismiss-animation race
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return AlertDialog(
      backgroundColor: sc.bg2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(S.get('enterMasterPw'), style: TextStyle(color: sc.textPrimary, fontWeight: FontWeight.w600)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(S.get('restorePwPrompt'),
          style: TextStyle(color: sc.textSecondary, fontSize: 13, height: 1.5)),
        const SizedBox(height: 16),
        TextField(
          controller: _ctrl,
          obscureText: _obscure,
          autofocus: true,
          enableSuggestions: false,
          autocorrect: false,
          style: TextStyle(color: sc.textPrimary),
          decoration: InputDecoration(
            hintText: S.masterPassword,
            filled: true, fillColor: sc.bg3,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off, size: 18, color: sc.textTertiary),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          onSubmitted: (_) => Navigator.pop(context, _ctrl.text),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, null),
          child: Text(S.cancel, style: TextStyle(color: sc.textSecondary))),
        TextButton(onPressed: () => Navigator.pop(context, _ctrl.text),
          child: Text(S.get('restoreConfirmYes'), style: const TextStyle(color: SanctumTheme.gold, fontWeight: FontWeight.w600))),
      ],
    );
  }
}

class _StepCard extends StatelessWidget {
  final String number, title, subtitle;
  final bool done;
  const _StepCard({required this.number, required this.title, required this.subtitle, required this.done});

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: done ? SanctumTheme.greenDim : sc.bg2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: done ? SanctumTheme.green.withValues(alpha: 0.3) : sc.border),
      ),
      child: Row(children: [
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: done ? SanctumTheme.green : sc.bg3,
            shape: BoxShape.circle,
          ),
          child: Center(child: done
            ? const Icon(Icons.check, size: 16, color: Colors.white)
            : Text(number, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: sc.textTertiary))),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500,
            color: done ? SanctumTheme.green : sc.textPrimary)),
          Text(subtitle, style: TextStyle(fontSize: 12, color: sc.textTertiary)),
        ])),
      ]),
    );
  }
}

class _CloudCard extends StatelessWidget {
  final String emoji, title, subtitle;
  final VoidCallback onTap;
  const _CloudCard({required this.emoji, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: sc.bg2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sc.border),
        ),
        child: Row(children: [
          Text(emoji, style: const TextStyle(fontSize: 24)),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: sc.textPrimary)),
            Text(subtitle, style: TextStyle(fontSize: 12, color: sc.textTertiary)),
          ])),
          Icon(Icons.chevron_right, size: 18, color: sc.textTertiary),
        ]),
      ),
    );
  }
}

class _RestoreRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final VoidCallback? onTap;
  final bool loading;
  const _RestoreRow({required this.icon, required this.iconColor, required this.label, this.onTap, this.loading = false});

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(children: [
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(color: iconColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(7)),
            child: Icon(icon, size: 15, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: TextStyle(
            fontSize: 14, color: onTap != null ? sc.textPrimary : sc.textTertiary))),
          if (loading)
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: SanctumTheme.gold))
          else
            Icon(Icons.chevron_right, size: 18, color: onTap != null ? sc.textTertiary : sc.bg4),
        ]),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String icon, text;
  const _InfoRow({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(icon, style: const TextStyle(fontSize: 13)),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: context.sc.textTertiary, height: 1.5))),
    ]),
  );
}
