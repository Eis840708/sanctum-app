import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../../core/i18n/strings.dart';
import '../../../shared/theme/app_theme.dart';
import '../services/transfer_service.dart';

enum _RecvState { scan, downloading, done, error }

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  _RecvState _state    = _RecvState.scan;
  double     _progress = 0.0;
  String     _error    = '';
  bool       _scanned  = false;

  MobileScannerController? _camCtrl;

  @override
  void initState() {
    super.initState();
    _camCtrl = MobileScannerController(
      facing: CameraFacing.back,
    );
  }

  @override
  void dispose() {
    _camCtrl?.dispose();
    super.dispose();
  }

  Future<void> _onQr(String raw) async {
    if (_scanned) return;
    _scanned = true;
    await _camCtrl?.stop();

    setState(() { _state = _RecvState.downloading; _progress = 0; });

    try {
      final d = TransferService.parseQr(raw);
      if (d['m'] != 'w') throw Exception(S.get('qrTypeUnsupported'));

      final ip  = d['h'] as String;
      final pt  = d['p'] as int;
      final key = d['k'] as String;

      await transferService.receiveWifi(ip, pt, key,
          onProgress: (p) {
            if (!mounted) return;
            setState(() => _progress = p);
          });

      if (!mounted) return;
      setState(() => _state = _RecvState.done);
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _state = _RecvState.error; });
    }
  }

  void _retry() {
    _scanned = false;
    _camCtrl?.start();
    setState(() { _state = _RecvState.scan; _error = ''; _progress = 0; });
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
        title: Text(S.get('receiveDataTitle'),
            style: TextStyle(fontSize: 16, color: sc.textPrimary)),
      ),
      body: switch (_state) {
        _RecvState.scan        => _buildScanner(),
        _RecvState.downloading => _buildDownloading(),
        _RecvState.done        => _buildDone(),
        _RecvState.error       => _buildError(),
      },
    );
  }

  Widget _buildScanner() {
    final sc = context.sc;
    return Column(children: [
      // Warning banner
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: SanctumTheme.amber.withValues(alpha: 0.1),
        child: Row(children: [
          const Icon(Icons.wifi, size: 13, color: SanctumTheme.amber),
          const SizedBox(width: 8),
          Expanded(child: Text(
            S.get('sameWifiNote'),
            style: const TextStyle(fontSize: 11, color: SanctumTheme.amber),
          )),
        ]),
      ),

      // Camera viewfinder
      Expanded(
        flex: 3,
        child: Stack(children: [
          MobileScanner(
            controller: _camCtrl!,
            onDetect: (capture) {
              final code = capture.barcodes.firstOrNull?.rawValue;
              if (code != null) _onQr(code);
            },
          ),

          // Overlay with scanning rect
          CustomPaint(
            painter: _ScanOverlayPainter(),
            child: const SizedBox.expand(),
          ),

          // "Scanning…" label
          Positioned(
            bottom: 24, left: 0, right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const SizedBox(
                    width: 10, height: 10,
                    child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 1.5),
                  ),
                  const SizedBox(width: 8),
                  Text(S.get('scanningQr'),
                    style: const TextStyle(color: Colors.white, fontSize: 12)),
                ]),
              ),
            ),
          ),
        ]),
      ),

      // Bottom tips
      Expanded(
        flex: 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(S.get('aimCamera'),
                style: TextStyle(fontSize: 14, color: sc.textPrimary)),
              const SizedBox(height: 6),
              Text(S.get('qrValidity'),
                style: TextStyle(fontSize: 12, color: sc.textTertiary)),
            ],
          ),
        ),
      ),
    ]);
  }

  Widget _buildDownloading() {
    final sc = context.sc;
    final pct = (_progress * 100).toInt();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Animated icon
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
              color: SanctumTheme.blue.withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border: Border.all(color: SanctumTheme.blue.withValues(alpha: 0.3), width: 2),
            ),
            child: const Icon(Icons.download_rounded, size: 32, color: SanctumTheme.blue),
          ).animate(onPlay: (c) => c.repeat())
           .shimmer(duration: 1200.ms, color: SanctumTheme.blue.withValues(alpha: 0.3)),

          const SizedBox(height: 24),
          Text(S.get('encryptingTransfer'),
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
                color: sc.textPrimary)),
          const SizedBox(height: 24),

          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _progress > 0 ? _progress : null,
              backgroundColor: sc.bg2,
              valueColor: const AlwaysStoppedAnimation(SanctumTheme.blue),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _progress > 0 ? '$pct%' : S.get('connecting'),
            style: TextStyle(fontSize: 12, color: sc.textTertiary),
          ),
          const SizedBox(height: 20),
          Text(S.get('dontLeavePage'),
            style: TextStyle(fontSize: 11, color: sc.textTertiary)),
        ]),
      ),
    );
  }

  Widget _buildDone() {
    final sc = context.sc;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
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
          Text(S.get('receiveSuccess'),
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600,
                color: sc.textPrimary)),
          const SizedBox(height: 8),
          Text(S.get('receiveSuccessMsg'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: sc.textSecondary, height: 1.6)),
          const SizedBox(height: 32),

          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: SanctumTheme.green,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              // Pop back to root so lock screen is shown
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
            child: Text(S.get('goUnlockVault'),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
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
          Text(_error.isNotEmpty ? _error : S.get('receiveFailed'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: sc.textSecondary, height: 1.6)),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            icon: const Icon(Icons.qr_code_scanner, size: 16),
            label: Text(S.get('rescan')),
            onPressed: _retry,
          ),
        ]),
      ),
    );
  }
}

/// Custom painter for QR scanning overlay (darkened corners + bright scan rect)
class _ScanOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const double side = 220;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final rect = Rect.fromCenter(center: Offset(cx, cy), width: side, height: side);

    // Darken everything outside scan rect
    final dark = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(12)));
    canvas.drawPath(path..fillType = PathFillType.evenOdd, dark);

    // Corner brackets
    const cLen = 22.0;
    const cW   = 3.0;
    final cp = Paint()
      ..color = SanctumTheme.gold
      ..strokeWidth = cW
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final r = rect;

    // Top-left
    canvas.drawLine(r.topLeft, r.topLeft.translate(cLen, 0), cp);
    canvas.drawLine(r.topLeft, r.topLeft.translate(0, cLen), cp);
    // Top-right
    canvas.drawLine(r.topRight, r.topRight.translate(-cLen, 0), cp);
    canvas.drawLine(r.topRight, r.topRight.translate(0, cLen), cp);
    // Bottom-left
    canvas.drawLine(r.bottomLeft, r.bottomLeft.translate(cLen, 0), cp);
    canvas.drawLine(r.bottomLeft, r.bottomLeft.translate(0, -cLen), cp);
    // Bottom-right
    canvas.drawLine(r.bottomRight, r.bottomRight.translate(-cLen, 0), cp);
    canvas.drawLine(r.bottomRight, r.bottomRight.translate(0, -cLen), cp);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
