import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../shared/theme/app_theme.dart';
import '../services/transfer_service.dart';

enum _SendState { loading, ready, done, error }

class SendScreen extends StatefulWidget {
  const SendScreen({super.key});

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  _SendState _state = _SendState.loading;
  String  _qrData  = '';
  String  _error   = '';
  int     _secs    = 300; // 5 min countdown
  Timer?  _ticker;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    transferService.stop();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() { _state = _SendState.loading; _error = ''; });
    try {
      final key  = transferService.generateKey();
      final info = await transferService.startWifiSend(key);
      final ip   = info['ip']   as String;
      final port = info['port'] as int;
      final qr   = TransferService.buildWifiQr(ip, port, key);

      if (!mounted) return;
      setState(() { _qrData = qr; _state = _SendState.ready; _secs = 300; });
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _secs--);
        if (_secs <= 0) { _ticker?.cancel(); _checkDone(); }
        if (transferService.wasServed) { _ticker?.cancel(); _checkDone(); }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _state = _SendState.error; });
    }
  }

  void _checkDone() {
    if (!mounted) return;
    if (transferService.wasServed) {
      setState(() => _state = _SendState.done);
    } else if (_secs <= 0) {
      setState(() { _state = _SendState.error; _error = 'QR Code 已過期，請重新生成。'; });
    }
  }

  String get _countdown {
    final m = _secs ~/ 60;
    final s = _secs % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

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
        title: Text('舊手機：傳送資料',
            style: TextStyle(fontSize: 16, color: sc.textPrimary)),
      ),
      body: switch (_state) {
        _SendState.loading => Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(color: SanctumTheme.gold, strokeWidth: 2),
              const SizedBox(height: 16),
              Text('正在準備加密資料…', style: TextStyle(color: sc.textTertiary, fontSize: 13)),
            ])),
        _SendState.ready  => _buildReady(),
        _SendState.done   => _buildDone(),
        _SendState.error  => _buildError(),
      },
    );
  }

  Widget _buildReady() {
    final sc = context.sc;
    final urgent = _secs < 60;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(children: [
        // QR Code card
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: sc.bg2,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: SanctumTheme.gold.withValues(alpha: 0.3)),
            boxShadow: [BoxShadow(
              color: SanctumTheme.gold.withValues(alpha: 0.05),
              blurRadius: 30, spreadRadius: 2)],
          ),
          child: Column(children: [
            // QR code
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: _qrData,
                version: QrVersions.auto,
                size: 220,
                gapless: true,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Colors.black,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black,
                ),
              ),
            ).animate().fadeIn(duration: 600.ms).scale(begin: const Offset(0.9, 0.9)),

            const SizedBox(height: 16),

            // Countdown
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: (urgent ? SanctumTheme.red : SanctumTheme.gold).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: (urgent ? SanctumTheme.red : SanctumTheme.gold).withValues(alpha: 0.4)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.timer_outlined,
                    size: 14,
                    color: urgent ? SanctumTheme.red : SanctumTheme.gold),
                const SizedBox(width: 6),
                Text(_countdown, style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: urgent ? SanctumTheme.red : SanctumTheme.gold,
                )),
                const SizedBox(width: 6),
                Text('後過期', style: TextStyle(
                  fontSize: 12,
                  color: (urgent ? SanctumTheme.red : SanctumTheme.gold).withValues(alpha: 0.7),
                )),
              ]),
            ),

            const SizedBox(height: 12),

            // Status
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(
                width: 8, height: 8,
                decoration: const BoxDecoration(
                  color: SanctumTheme.green, shape: BoxShape.circle),
              ).animate(onPlay: (c) => c.repeat())
               .fadeOut(duration: 800.ms).then().fadeIn(duration: 800.ms),
              const SizedBox(width: 8),
              Text('等待新手機掃描…',
                style: TextStyle(fontSize: 12, color: sc.textSecondary)),
            ]),
          ]),
        ).animate().fadeIn(duration: 400.ms),

        const SizedBox(height: 24),

        // Instructions
        _Steps(steps: const [
          ('📱', '在新手機開啟 Sanctum → 設定 → 換機轉移 → 新手機'),
          ('📷', '點擊「掃描 QR 碼」，將鏡頭對準此 QR Code'),
          ('✅', '新手機下載完成後，輸入相同主密鑰即可解鎖'),
        ]),

        const SizedBox(height: 20),

        // Refresh button
        TextButton.icon(
          icon: Icon(Icons.refresh, size: 16, color: sc.textTertiary),
          label: Text('重新生成', style: TextStyle(fontSize: 13, color: sc.textTertiary)),
          onPressed: _start,
        ),
      ]),
    );
  }

  Widget _buildDone() {
    final sc = context.sc;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 72, height: 72,
          decoration: BoxDecoration(
            color: SanctumTheme.green.withValues(alpha: 0.1),
            shape: BoxShape.circle,
            border: Border.all(color: SanctumTheme.green.withValues(alpha: 0.4), width: 2),
          ),
          child: const Icon(Icons.check_rounded, size: 36, color: SanctumTheme.green),
        ).animate().scale(duration: 400.ms, curve: Curves.elasticOut),
        const SizedBox(height: 20),
        Text('傳送成功！', style: TextStyle(
          fontSize: 20, fontWeight: FontWeight.w600, color: sc.textPrimary)),
        const SizedBox(height: 8),
        Text('新手機已接收所有資料\n請在新手機輸入相同主密鑰解鎖',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: sc.textSecondary, height: 1.6)),
        const SizedBox(height: 32),
        ElevatedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ]),
    );
  }

  Widget _buildError() {
    final sc = context.sc;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, size: 48, color: SanctumTheme.red),
          const SizedBox(height: 16),
          Text(_error.isNotEmpty ? _error : '連接失敗',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: sc.textSecondary, height: 1.6)),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重試'),
            onPressed: _start,
          ),
        ]),
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  final List<(String, String)> steps;
  const _Steps({required this.steps});

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: sc.bg2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sc.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('操作步驟', style: TextStyle(
            fontSize: 11, color: sc.textTertiary, letterSpacing: 0.5)),
          const SizedBox(height: 12),
          ...steps.map((s) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.$1, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 10),
              Expanded(child: Text(s.$2, style: TextStyle(
                fontSize: 12, color: sc.textSecondary, height: 1.5))),
            ]),
          )),
        ],
      ),
    );
  }
}
