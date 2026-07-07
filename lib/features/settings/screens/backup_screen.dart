import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    return Scaffold(
      backgroundColor: SanctumTheme.bg,
      appBar: AppBar(
        backgroundColor: SanctumTheme.bg2,
        title: Text(S.backup, style: const TextStyle(color: SanctumTheme.textPrimary)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: SanctumTheme.textSecondary),
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
                colors: [SanctumTheme.gold.withValues(alpha: 0.15), SanctumTheme.bg2],
                begin: Alignment.topLeft, end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: SanctumTheme.gold.withValues(alpha: 0.2)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('🔐', style: TextStyle(fontSize: 32)),
              const SizedBox(height: 12),
              const Text('2-Layer Backup', style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w600, color: SanctumTheme.textPrimary)),
              const SizedBox(height: 6),
              const Text(
                'Your vault is encrypted before saving. No one can read it without your master password.',
                style: TextStyle(fontSize: 13, color: SanctumTheme.textSecondary, height: 1.6)),
              if (_lastBackup != null) ...[
                const SizedBox(height: 10),
                Row(children: [
                  const Icon(Icons.check_circle, size: 14, color: SanctumTheme.green),
                  const SizedBox(width: 6),
                  Text('Last backup: ${_fmt(_lastBackup!)}',
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
              child: const Row(children: [
                Text('⚠️', style: TextStyle(fontSize: 20)),
                SizedBox(width: 12),
                Expanded(child: Text(
                  'Backup & restore require the mobile app (APK). Install the app on your Android device to use these features.',
                  style: TextStyle(fontSize: 13, color: SanctumTheme.amber, height: 1.5),
                )),
              ]),
            ),
            const SizedBox(height: 20),
          ],

          // ── Step 1: Local backup ─────────────────────────
          _StepCard(
            number: '1',
            title: 'Local backup',
            subtitle: 'Save encrypted .vault file on this device',
            done: _localDone,
          ),
          const SizedBox(height: 10),
          _StepCard(
            number: '2',
            title: 'Cloud backup',
            subtitle: 'Share to Google Drive, Email, WhatsApp…',
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
                label: const Text('Start Backup'),
              ),
            ),

          if (_backingUp)
            const Center(child: Padding(
              padding: EdgeInsets.all(20),
              child: Column(children: [
                CircularProgressIndicator(color: SanctumTheme.gold),
                SizedBox(height: 12),
                Text('Encrypting and saving…', style: TextStyle(color: SanctumTheme.textSecondary, fontSize: 13)),
              ]),
            )),

          // ── Cloud options (after local done) ─────────────
          if (_localDone && !_cloudDone) ...[
            const Text('Step 2 — Choose where to share', style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600, color: SanctumTheme.textPrimary)),
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
                const Text('備份完成！', style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: SanctumTheme.green)),
                const SizedBox(height: 6),
                const Text('本地副本已儲存 · 雲端副本已傳送',
                  style: TextStyle(fontSize: 13, color: SanctumTheme.textSecondary)),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => setState(() { _localDone = false; _cloudDone = false; _error = null; }),
                  child: const Text('再次備份', style: TextStyle(color: SanctumTheme.gold)),
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
          const Text('還原', style: TextStyle(
            fontSize: 10, color: SanctumTheme.textTertiary, letterSpacing: 0.8)),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: SanctumTheme.bg2,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: SanctumTheme.border),
            ),
            child: Column(children: [
              _RestoreRow(
                icon: Icons.file_open_outlined,
                iconColor: SanctumTheme.blue,
                label: '從 .vault 檔案還原',
                onTap: _restoring ? null : _restoreFromFile,
                loading: _restoring,
              ),
            ]),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: SanctumTheme.bg3,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: SanctumTheme.border),
            ),
            child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline, size: 13, color: SanctumTheme.textTertiary),
              SizedBox(width: 8),
              Expanded(child: Text(
                '還原將覆蓋現有所有資料。還原完成後需重新輸入主密碼解鎖。',
                style: TextStyle(fontSize: 12, color: SanctumTheme.textTertiary, height: 1.5),
              )),
            ]),
          ),

          const SizedBox(height: 16),

          // ── Info box ─────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: SanctumTheme.bg3,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: SanctumTheme.border),
            ),
            child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('運作方式', style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: SanctumTheme.textSecondary)),
              SizedBox(height: 8),
              _InfoRow(icon: '🔐', text: '儲存前以 AES-256-GCM 加密'),
              _InfoRow(icon: '📱', text: '本地副本保留在你的裝置上'),
              _InfoRow(icon: '☁️', text: '雲端副本與本地為同一加密檔案'),
              _InfoRow(icon: '🔑', text: '只有你的主密鑰才能還原'),
            ]),
          ),
        ]),
      ),
    );
  }

  Future<void> _startBackup() async {
    setState(() { _backingUp = true; _error = null; });
    try {
      final data = await vaultService.exportVaultJson();
      final json = const JsonEncoder.withIndent('  ').convert(data);
      final date = DateTime.now();
      await BackupHelper.saveLocal(json, date);
      setState(() { _localDone = true; _backingUp = false; _lastBackup = date; });
    } catch (e) {
      setState(() { _backingUp = false; _error = '備份失敗：$e'; });
    }
  }

  Future<void> _shareCloud() async {
    try {
      await BackupHelper.shareFile();
      setState(() => _cloudDone = true);
    } catch (e) {
      setState(() => _error = '分享失敗：$e');
    }
  }

  Future<void> _restoreFromFile() async {
    // Confirm before overwriting existing data
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: SanctumTheme.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('還原備份', style: TextStyle(color: SanctumTheme.textPrimary, fontWeight: FontWeight.w600)),
        content: const Text(
          '這將覆蓋現有所有密碼、記事及財務資料。\n\n還原完成後需重新輸入主密碼解鎖。\n\n確定繼續嗎？',
          style: TextStyle(color: SanctumTheme.textSecondary, fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false),
            child: const Text('取消', style: TextStyle(color: SanctumTheme.textSecondary))),
          TextButton(onPressed: () => Navigator.pop(d, true),
            child: const Text('確定還原', style: TextStyle(color: SanctumTheme.red, fontWeight: FontWeight.w600))),
        ],
      ),
    ) ?? false;

    if (!confirmed) return;

    setState(() { _restoring = true; _error = null; });
    try {
      final json     = await BackupHelper.readBackupFile();
      final needsReunlock = await vaultService.importFromBackup(json);
      if (!mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          backgroundColor: SanctumTheme.bg2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(children: [
            Text('✅ ', style: TextStyle(fontSize: 20)),
            Text('還原完成', style: TextStyle(color: SanctumTheme.textPrimary, fontWeight: FontWeight.w600)),
          ]),
          content: Text(
            needsReunlock
              ? '所有資料已還原。\n\n請重新輸入主密碼解鎖 Vault。'
              : '所有資料已還原。',
            style: const TextStyle(color: SanctumTheme.textSecondary, fontSize: 13, height: 1.6),
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
              child: const Text('確定', style: TextStyle(color: SanctumTheme.gold, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
    } catch (e) {
      setState(() => _error = '還原失敗：$e');
    } finally {
      setState(() => _restoring = false);
    }
  }

  static const _cloudOptions = [
    {'emoji': '📦', 'title': 'Google Drive', 'subtitle': 'Save to your Google Drive'},
    {'emoji': '📧', 'title': 'Email to myself', 'subtitle': 'Send the file to your email'},
    {'emoji': '💬', 'title': 'WhatsApp / LINE', 'subtitle': 'Send to your saved messages'},
    {'emoji': '📋', 'title': 'Local only', 'subtitle': 'Skip cloud — keep only on device'},
  ];

  String _fmt(DateTime d) =>
    '${d.year}/${d.month.toString().padLeft(2,'0')}/${d.day.toString().padLeft(2,'0')} '
    '${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
}

// ── Sub-widgets ───────────────────────────────────────────
class _StepCard extends StatelessWidget {
  final String number, title, subtitle;
  final bool done;
  const _StepCard({required this.number, required this.title, required this.subtitle, required this.done});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: done ? SanctumTheme.greenDim : SanctumTheme.bg2,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: done ? SanctumTheme.green.withValues(alpha: 0.3) : SanctumTheme.border),
    ),
    child: Row(children: [
      Container(
        width: 32, height: 32,
        decoration: BoxDecoration(
          color: done ? SanctumTheme.green : SanctumTheme.bg3,
          shape: BoxShape.circle,
        ),
        child: Center(child: done
          ? const Icon(Icons.check, size: 16, color: Colors.white)
          : Text(number, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: SanctumTheme.textTertiary))),
      ),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500,
          color: done ? SanctumTheme.green : SanctumTheme.textPrimary)),
        Text(subtitle, style: const TextStyle(fontSize: 12, color: SanctumTheme.textTertiary)),
      ])),
    ]),
  );
}

class _CloudCard extends StatelessWidget {
  final String emoji, title, subtitle;
  final VoidCallback onTap;
  const _CloudCard({required this.emoji, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: SanctumTheme.bg2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SanctumTheme.border),
      ),
      child: Row(children: [
        Text(emoji, style: const TextStyle(fontSize: 24)),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: SanctumTheme.textPrimary)),
          Text(subtitle, style: const TextStyle(fontSize: 12, color: SanctumTheme.textTertiary)),
        ])),
        const Icon(Icons.chevron_right, size: 18, color: SanctumTheme.textTertiary),
      ]),
    ),
  );
}

class _RestoreRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final VoidCallback? onTap;
  final bool loading;
  const _RestoreRow({required this.icon, required this.iconColor, required this.label, this.onTap, this.loading = false});

  @override
  Widget build(BuildContext context) => GestureDetector(
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
          fontSize: 14, color: onTap != null ? SanctumTheme.textPrimary : SanctumTheme.textTertiary))),
        if (loading)
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: SanctumTheme.gold))
        else
          Icon(Icons.chevron_right, size: 18, color: onTap != null ? SanctumTheme.textTertiary : SanctumTheme.bg4),
      ]),
    ),
  );
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
      Expanded(child: Text(text, style: const TextStyle(fontSize: 12, color: SanctumTheme.textTertiary, height: 1.5))),
    ]),
  );
}
