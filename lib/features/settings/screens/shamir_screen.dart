// lib/features/settings/screens/shamir_screen.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/crypto/shamir_service.dart';
import '../../../shared/theme/app_theme.dart';

class ShamirScreen extends StatefulWidget {
  const ShamirScreen({super.key});
  @override
  State<ShamirScreen> createState() => _ShamirScreenState();
}

class _ShamirScreenState extends State<ShamirScreen> with SingleTickerProviderStateMixin {
  late final TabController _tab;
  @override
  void initState() { super.initState(); _tab = TabController(length: 2, vsync: this); }
  @override
  void dispose() { _tab.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return Scaffold(
      backgroundColor: sc.bg,
      appBar: AppBar(
        backgroundColor: sc.bg,
        foregroundColor: sc.textPrimary,
        elevation: 0,
        title: const Text('碎片備份', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        bottom: TabBar(
          controller: _tab,
          indicatorColor: SanctumTheme.gold,
          labelColor: SanctumTheme.gold,
          unselectedLabelColor: sc.textTertiary,
          tabs: const [Tab(text: '生成碎片'), Tab(text: '還原密碼')],
        ),
      ),
      body: TabBarView(controller: _tab, children: const [_GenerateTab(), _RecoverTab()]),
    );
  }
}

// ── Generate Tab ──────────────────────────────────────────────────────────────

class _GenerateTab extends StatefulWidget {
  const _GenerateTab();
  @override
  State<_GenerateTab> createState() => _GenerateTabState();
}

class _GenerateTabState extends State<_GenerateTab> {
  final _pwCtrl = TextEditingController();
  bool _showPw = false;
  int _n = 5, _k = 3;
  List<String>? _shareCodes;
  bool _generating = false;

  @override
  void dispose() { _pwCtrl.dispose(); super.dispose(); }

  Future<void> _generate() async {
    final pw = _pwCtrl.text.trim();
    if (pw.isEmpty) { _snack('請輸入主密碼'); return; }
    setState(() => _generating = true);
    await Future.delayed(const Duration(milliseconds: 50));
    final raw = shamirService.split(utf8.encode(pw), _n, _k);
    setState(() { _shareCodes = raw.map(shamirService.encodeShare).toList(); _generating = false; });
  }

  void _reset() => setState(() { _shareCodes = null; _pwCtrl.clear(); });
  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: context.sc.bg3, behavior: SnackBarBehavior.floating, duration: Duration(seconds: 2))); }
  void _copy(String t) { Clipboard.setData(ClipboardData(text: t)); _snack('已複製'); }

  void _exportOne(int i) {
    if (_shareCodes == null) return;
    Share.share(shamirService.buildDocument(index: i+1, total: _n, threshold: _k, shareCode: _shareCodes![i], createdAt: DateTime.now()), subject: 'Sanctum 密閣 · 碎片 ${i+1}/$_n');
  }

  @override
  Widget build(BuildContext context) => _shareCodes != null ? _results() : _config();

  Widget _config() {
    final sc = context.sc;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _InfoBox('碎片備份將主密碼分成 N 份碎片，只需集齊任意 K 份即可還原。\n請將每份碎片分別交給不同的可信任人士保管。'),
        const SizedBox(height: 24),
        _Label('主密碼'), const SizedBox(height: 6),
        TextFormField(
          controller: _pwCtrl, obscureText: !_showPw,
          style: TextStyle(color: sc.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            hintText: '輸入您的主密碼', filled: true, fillColor: sc.bg2,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: SanctumTheme.gold)),
            suffixIcon: IconButton(icon: Icon(_showPw ? Icons.visibility_off : Icons.visibility, size: 18, color: sc.textTertiary), onPressed: () => setState(() => _showPw = !_showPw)),
          ),
        ),
        const SizedBox(height: 24),
        _SliderRow(label: '總碎片數 (N)', value: _n, min: 3, max: 10, onChanged: (v) => setState(() { _n = v; if (_k > _n) _k = _n; })),
        const SizedBox(height: 12),
        _SliderRow(label: '重建所需數 (K)', value: _k, min: 2, max: _n, onChanged: (v) => setState(() => _k = v)),
        const SizedBox(height: 8),
        Text('任意 $_k 份（共 $_n 份）即可還原主密碼', style: const TextStyle(fontSize: 12, color: SanctumTheme.gold)),
        const SizedBox(height: 32),
        SizedBox(width: double.infinity, child: ElevatedButton(
          onPressed: _generating ? null : _generate,
          style: ElevatedButton.styleFrom(backgroundColor: SanctumTheme.gold, foregroundColor: sc.bg, padding: EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          child: _generating ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: sc.bg)) : Text('生成碎片', style: TextStyle(fontWeight: FontWeight.w600)),
        )),
      ]),
    );
  }

  Widget _results() {
    final sc = context.sc;
    return Column(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        color: sc.bg2,
        child: Row(children: [
          const Icon(Icons.check_circle_outline, color: SanctumTheme.gold, size: 18), const SizedBox(width: 8),
          // V-07: no single "share all" action — each share must be distributed
          // to a separate destination via its own per-share export.
          Expanded(child: Text('已生成 $_n 份碎片（需 $_k 份還原）', style: TextStyle(fontSize: 13, color: sc.textPrimary))),
        ]),
      ),
      Expanded(child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _shareCodes!.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _ShareCard(index: i, total: _n, code: _shareCodes![i], onCopy: () => _copy(_shareCodes![i]), onExport: () => _exportOne(i)),
      )),
      SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: SizedBox(width: double.infinity, child: OutlinedButton(
          onPressed: _reset,
          style: OutlinedButton.styleFrom(foregroundColor: sc.textTertiary, side: BorderSide(color: sc.border), padding: EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          child: const Text('重新生成'),
        )),
      )),
    ]);
  }
}

// ── Recover Tab ───────────────────────────────────────────────────────────────

class _RecoverTab extends StatefulWidget {
  const _RecoverTab();
  @override
  State<_RecoverTab> createState() => _RecoverTabState();
}

class _RecoverTabState extends State<_RecoverTab> {
  final List<TextEditingController> _ctrls = [];
  int _shareCount = 3;
  String? _recovered;
  bool _showResult = false;
  String? _error;

  @override
  void initState() { super.initState(); _rebuild(_shareCount); }
  @override
  void dispose() { for (final c in _ctrls) c.dispose(); super.dispose(); }

  void _rebuild(int count) {
    while (_ctrls.length > count) _ctrls.removeLast().dispose();
    while (_ctrls.length < count) _ctrls.add(TextEditingController());
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: context.sc.bg3, behavior: SnackBarBehavior.floating, duration: Duration(seconds: 2))); }

  void _recover() {
    setState(() { _error = null; _recovered = null; });
    final decoded = <dynamic>[];
    for (int i = 0; i < _ctrls.length; i++) {
      final raw = _ctrls[i].text.trim();
      if (raw.isEmpty) { setState(() => _error = '碎片 ${i+1} 未填寫'); return; }
      final b = shamirService.decodeShare(raw);
      if (b == null) { setState(() => _error = '碎片 ${i+1} 格式錯誤'); return; }
      decoded.add(b);
    }
    try {
      setState(() => _recovered = utf8.decode(shamirService.combine(decoded.cast())));
    } catch (_) {
      setState(() => _error = '還原失敗：碎片不足或有誤');
    }
  }

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _InfoBox('請貼上您收集到的碎片代碼（至少需要建立時設定的 K 份）。'),
        const SizedBox(height: 20),
        _SliderRow(label: '碎片數量', value: _shareCount, min: 2, max: 10, onChanged: (v) => setState(() { _shareCount = v; _rebuild(v); _recovered = null; _error = null; })),
        const SizedBox(height: 20),
        for (int i = 0; i < _shareCount; i++) ...[
          _Label('碎片 ${i+1}'), const SizedBox(height: 6),
          TextFormField(
            controller: _ctrls[i],
            style: TextStyle(color: sc.textPrimary, fontSize: 12, fontFamily: 'monospace'),
            maxLines: 2,
            decoration: InputDecoration(
              hintText: 'XXXX-XXXX-XXXX-…', hintStyle: const TextStyle(fontSize: 11),
              filled: true, fillColor: sc.bg2,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: SanctumTheme.gold)),
            ),
            onChanged: (_) => setState(() { _error = null; _recovered = null; }),
          ),
          const SizedBox(height: 12),
        ],
        if (_error != null) ...[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: SanctumTheme.red.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              const Icon(Icons.error_outline, color: SanctumTheme.red, size: 16), const SizedBox(width: 8),
              Expanded(child: Text(_error!, style: const TextStyle(fontSize: 12, color: SanctumTheme.red))),
            ]),
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(width: double.infinity, child: ElevatedButton(
          onPressed: _recover,
          style: ElevatedButton.styleFrom(backgroundColor: SanctumTheme.gold, foregroundColor: sc.bg, padding: EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          child: const Text('還原主密碼', style: TextStyle(fontWeight: FontWeight.w600)),
        )),
        if (_recovered != null) ...[
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: sc.bg2, borderRadius: BorderRadius.circular(10), border: Border.all(color: SanctumTheme.gold.withValues(alpha: 0.4))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('✅  已成功還原主密碼', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: SanctumTheme.gold)),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: Text(_showResult ? _recovered! : '•' * _recovered!.length.clamp(8, 20), style: TextStyle(fontSize: 14, color: sc.textPrimary, fontFamily: 'monospace'))),
                IconButton(icon: Icon(_showResult ? Icons.visibility_off : Icons.visibility, size: 18, color: sc.textTertiary), onPressed: () => setState(() => _showResult = !_showResult)),
                IconButton(icon: const Icon(Icons.copy, size: 18, color: SanctumTheme.gold), onPressed: () { Clipboard.setData(ClipboardData(text: _recovered!)); _snack('已複製主密碼'); }),
              ]),
              const SizedBox(height: 8),
              Text('⚠️  複製後請立即使用，不要截圖或儲存。', style: TextStyle(fontSize: 11, color: sc.textTertiary)),
            ]),
          ),
        ],
        const SizedBox(height: 40),
      ]),
    );
  }
}

// ── Shared Widgets ────────────────────────────────────────────────────────────

class _ShareCard extends StatelessWidget {
  final int index, total;
  final String code;
  final VoidCallback onCopy, onExport;
  const _ShareCard({required this.index, required this.total, required this.code, required this.onCopy, required this.onExport});
  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: sc.bg2, borderRadius: BorderRadius.circular(10), border: Border.all(color: sc.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: SanctumTheme.gold.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
            child: Text('碎片 ${index+1} / $total', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: SanctumTheme.gold))),
          const Spacer(),
          _MiniBtn(label: '複製', icon: Icons.copy, onTap: onCopy),
          const SizedBox(width: 6),
          _MiniBtn(label: '分享', icon: Icons.share, onTap: onExport),
        ]),
        const SizedBox(height: 10),
        SelectableText(code, style: TextStyle(fontSize: 11, color: sc.textPrimary, fontFamily: 'monospace', letterSpacing: 1.0)),
      ]),
    );
  }
}

class _MiniBtn extends StatelessWidget {
  final String label; final IconData icon; final VoidCallback onTap;
  const _MiniBtn({required this.label, required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: sc.bg3, borderRadius: BorderRadius.circular(6), border: Border.all(color: sc.border)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: sc.textTertiary),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: sc.textTertiary)),
        ]),
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  final String text; const _InfoBox(this.text);
  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: sc.bg2, borderRadius: BorderRadius.circular(8), border: Border.all(color: sc.border)),
      child: Text(text, style: TextStyle(fontSize: 12, color: sc.textTertiary, height: 1.5)),
    );
  }
}

class _Label extends StatelessWidget {
  final String text; const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(text, style: TextStyle(fontSize: 12, color: context.sc.textTertiary));
}

class _SliderRow extends StatelessWidget {
  final String label; final int value, min, max; final ValueChanged<int> onChanged;
  const _SliderRow({required this.label, required this.value, required this.min, required this.max, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return Row(children: [
      SizedBox(width: 120, child: Text(label, style: TextStyle(fontSize: 12, color: sc.textTertiary))),
      Expanded(child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: SanctumTheme.gold,
          inactiveTrackColor: sc.border,
          thumbColor: SanctumTheme.gold,
          overlayColor: SanctumTheme.gold.withValues(alpha: 0.12),
          trackHeight: 2,
        ),
        child: Slider(value: value.toDouble(), min: min.toDouble(), max: max.toDouble(), divisions: max - min, onChanged: (v) => onChanged(v.round())),
      )),
      SizedBox(width: 28, child: Text('$value', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: sc.textPrimary))),
    ]);
  }
}
