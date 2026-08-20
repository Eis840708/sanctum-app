import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/storage/vault_service.dart';
import '../../../shared/theme/app_theme.dart';
import 'send_screen.dart';
import 'receive_screen.dart';

class TransferScreen extends StatelessWidget {
  const TransferScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return Scaffold(
      backgroundColor: sc.bg,
      appBar: AppBar(
        backgroundColor: sc.bg2,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: sc.textSecondary),
          onPressed: () => Navigator.pop(context),
        ),
        title: ShaderMask(
          shaderCallback: (b) => SanctumDecor.goldGradient().createShader(b),
          child: Text(S.get('deviceTransfer'), style: const TextStyle(
            fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white)),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Security badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: SanctumTheme.green.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: SanctumTheme.green.withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.shield_outlined, size: 14, color: SanctumTheme.green),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  S.get('transferBadges'),
                  style: const TextStyle(fontSize: 11, color: SanctumTheme.green, height: 1.4),
                )),
              ]),
            ).animate().fadeIn(duration: 400.ms),

            const SizedBox(height: 28),

            // DEV-P0-03-UI 子項 D (方案 A): v3 vaults cannot use network transfer
            // (transfer is v2-only). Gate the role cards here so a v3 vault can
            // never reach the send/receive flow. Users use backup/restore instead.
            // TODO(DEV-P0-03-D-ext): full v3 transfer + receiver password confirm.
            if (vaultService.isV3Vault) ...[
              const _V3TransferDisabledCard(),
              const SizedBox(height: 28),
            ] else ...[
              Text(S.get('selectRole'), style: TextStyle(
                fontSize: 11, color: sc.textTertiary, letterSpacing: 0.8)),
              const SizedBox(height: 12),

              // Send card
              _RoleCard(
                icon: Icons.phone_android,
                iconColor: SanctumTheme.gold,
                title: S.get('oldPhoneSender'),
                subtitle: S.get('oldPhoneSenderSub'),
                steps: [S.get('stepOpenPage'), S.get('stepTapSend'), S.get('stepLetScan')],
                onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const SendScreen())),
              ).animate().fadeIn(duration: 500.ms, delay: 100.ms).slideY(begin: 0.05),

              const SizedBox(height: 14),

              // Receive card
              _RoleCard(
                icon: Icons.phone_iphone,
                iconColor: SanctumTheme.blue,
                title: S.get('newPhoneReceiver'),
                subtitle: S.get('newPhoneReceiverSub'),
                steps: [S.get('stepOpenPage'), S.get('stepTapScan'), S.get('stepWaitImport')],
                onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const ReceiveScreen())),
              ).animate().fadeIn(duration: 500.ms, delay: 200.ms).slideY(begin: 0.05),

              const SizedBox(height: 28),
            ],

            // How it works
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: sc.bg2,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: sc.border, width: 0.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.info_outline, size: 14, color: sc.textTertiary),
                    const SizedBox(width: 6),
                    Text(S.get('transferHow'), style: TextStyle(
                      fontSize: 12, color: sc.textTertiary, fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 12),
                  ...[
                    ('🔑', S.get('principle1')),
                    ('📡', S.get('principle2')),
                    ('🔒', S.get('principle3')),
                    ('⚡', S.get('principle4')),
                    ('🔐', S.get('principle5')),
                  ].map((item) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(item.$1, style: const TextStyle(fontSize: 13)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(item.$2, style: TextStyle(
                        fontSize: 12, color: sc.textSecondary, height: 1.5))),
                    ]),
                  )),
                  Divider(color: sc.border, height: 20),
                  Row(children: [
                    const Icon(Icons.wifi, size: 13, color: SanctumTheme.amber),
                    const SizedBox(width: 6),
                    Expanded(child: Text(
                      S.get('wifiNote'),
                      style: const TextStyle(fontSize: 11, color: SanctumTheme.amber, height: 1.4),
                    )),
                  ]),
                ],
              ),
            ).animate().fadeIn(duration: 500.ms, delay: 300.ms),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

/// v3 vaults: network transfer is disabled (transfer is v2-only). Shown instead
/// of the send/receive role cards. Directs users to backup/restore (.vault).
class _V3TransferDisabledCard extends StatelessWidget {
  const _V3TransferDisabledCard();

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SanctumTheme.amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SanctumTheme.amber.withValues(alpha: 0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.info_outline, size: 16, color: SanctumTheme.amber),
          const SizedBox(width: 8),
          Expanded(child: Text(S.get('netTransferUnsupported'), style: TextStyle(
            fontSize: 14, fontWeight: FontWeight.w600, color: sc.textPrimary))),
        ]),
        const SizedBox(height: 8),
        Text(S.get('netTransferV3Msg'),
          style: TextStyle(fontSize: 12, color: sc.textSecondary, height: 1.6)),
      ]),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final List<String> steps;
  final VoidCallback onTap;

  const _RoleCard({
    required this.icon, required this.iconColor,
    required this.title, required this.subtitle,
    required this.steps, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: sc.bg2,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: sc.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 20, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600, color: sc.textPrimary)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(
                fontSize: 12, color: sc.textTertiary)),
            ])),
            Icon(Icons.arrow_forward_ios, size: 14, color: iconColor.withValues(alpha: 0.6)),
          ]),
          const SizedBox(height: 14),
          Divider(color: sc.border, height: 1),
          const SizedBox(height: 12),
          Row(children: steps.asMap().entries.map((e) => Expanded(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 18, height: 18,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Center(child: Text('${e.key + 1}', style: TextStyle(
                  fontSize: 10, color: iconColor, fontWeight: FontWeight.w600))),
              ),
              const SizedBox(width: 6),
              Expanded(child: Text(e.value, style: TextStyle(
                fontSize: 10, color: sc.textSecondary, height: 1.3))),
              if (e.key < steps.length - 1)
                Icon(Icons.chevron_right, size: 12, color: sc.border),
            ]),
          )).toList()),
        ]),
      ),
    );
  }
}
