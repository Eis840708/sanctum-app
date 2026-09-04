// lib/features/settings/screens/shamir_screen.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/crypto/shamir_service.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/security/sensitive_clipboard.dart';
import '../../../core/storage/providers.dart';
import '../../../core/storage/vault_service.dart';
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
        title: Text(S.shamirBackup, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        bottom: TabBar(
          controller: _tab,
          indicatorColor: SanctumTheme.gold,
          labelColor: SanctumTheme.gold,
          unselectedLabelColor: sc.textTertiary,
          tabs: [Tab(text: S.get('genShards')), Tab(text: S.get('recoverPwTab'))],
        ),
      ),
      // v3 vaults branch to the DEK-recovery flow (splits a full-entropy key,
      // recovery sets a NEW master password); v2 vaults keep the legacy UI
      // (splits the master password itself) byte-for-byte unchanged.
      body: TabBarView(
        controller: _tab,
        children: vaultService.isV3Vault
            ? const [_V3GenerateTab(), _V3RecoverTab()]
            : const [_GenerateTab(), _RecoverTab()],
      ),
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
    if (pw.isEmpty) { _snack(S.get('enterMasterPw')); return; }
    setState(() => _generating = true);
    await Future.delayed(const Duration(milliseconds: 50));
    final raw = shamirService.split(utf8.encode(pw), _n, _k);
    setState(() { _shareCodes = raw.map(shamirService.encodeShare).toList(); _generating = false; });
  }

  void _reset() => setState(() { _shareCodes = null; _pwCtrl.clear(); });
  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: context.sc.bg3, behavior: SnackBarBehavior.floating, duration: Duration(seconds: 2))); }
  void _copy(String t) { SensitiveClipboard.instance.copy(t); _snack(S.copied); }

  void _exportOne(int i) {
    if (_shareCodes == null) return;
    Share.share(shamirService.buildDocument(index: i+1, total: _n, threshold: _k, shareCode: _shareCodes![i], createdAt: DateTime.now()), subject: S.get('shardDocSubject').replaceAll('{i}', '${i+1}').replaceAll('{n}', '$_n'));
  }

  @override
  Widget build(BuildContext context) => _shareCodes != null ? _results() : _config();

  Widget _config() {
    final sc = context.sc;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _InfoBox(S.get('shamirIntroV2')),
        const SizedBox(height: 24),
        _Label(S.masterPassword), const SizedBox(height: 6),
        TextFormField(
          controller: _pwCtrl, obscureText: !_showPw,
          style: TextStyle(color: sc.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            hintText: S.get('enterYourMasterPw'), filled: true, fillColor: sc.bg2,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: SanctumTheme.gold)),
            suffixIcon: IconButton(icon: Icon(_showPw ? Icons.visibility_off : Icons.visibility, size: 18, color: sc.textTertiary), onPressed: () => setState(() => _showPw = !_showPw)),
          ),
        ),
        const SizedBox(height: 24),
        _SliderRow(label: S.get('totalShardsN'), value: _n, min: 3, max: 10, onChanged: (v) => setState(() { _n = v; if (_k > _n) _k = _n; })),
        const SizedBox(height: 12),
        _SliderRow(label: S.get('thresholdK'), value: _k, min: 2, max: _n, onChanged: (v) => setState(() => _k = v)),
        const SizedBox(height: 8),
        Text(S.get('shamirKofNPw').replaceAll('{k}', '$_k').replaceAll('{n}', '$_n'), style: const TextStyle(fontSize: 12, color: SanctumTheme.gold)),
        const SizedBox(height: 32),
        SizedBox(width: double.infinity, child: ElevatedButton(
          onPressed: _generating ? null : _generate,
          style: ElevatedButton.styleFrom(backgroundColor: SanctumTheme.gold, foregroundColor: sc.bg, padding: EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          child: _generating ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: sc.bg)) : Text(S.get('genShards'), style: TextStyle(fontWeight: FontWeight.w600)),
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
          Expanded(child: Text(S.get('shardsGenerated').replaceAll('{n}', '$_n').replaceAll('{k}', '$_k'), style: TextStyle(fontSize: 13, color: sc.textPrimary))),
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
          child: Text(S.get('regenerate')),
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
      if (raw.isEmpty) { setState(() => _error = S.get('shardEmpty').replaceAll('{i}', '${i+1}')); return; }
      final b = shamirService.decodeShare(raw);
      if (b == null) { setState(() => _error = S.get('shardBadFormat').replaceAll('{i}', '${i+1}')); return; }
      decoded.add(b);
    }
    try {
      setState(() => _recovered = utf8.decode(shamirService.combine(decoded.cast())));
    } catch (_) {
      setState(() => _error = S.get('restoreFailShards'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _InfoBox(S.get('pasteShardsHint')),
        const SizedBox(height: 20),
        _SliderRow(label: S.get('shardCount'), value: _shareCount, min: 2, max: 10, onChanged: (v) => setState(() { _shareCount = v; _rebuild(v); _recovered = null; _error = null; })),
        const SizedBox(height: 20),
        for (int i = 0; i < _shareCount; i++) ...[
          _Label(S.get('shardN').replaceAll('{i}', '${i+1}')), const SizedBox(height: 6),
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
          child: Text(S.get('recoverMasterPw'), style: TextStyle(fontWeight: FontWeight.w600)),
        )),
        if (_recovered != null) ...[
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: sc.bg2, borderRadius: BorderRadius.circular(10), border: Border.all(color: SanctumTheme.gold.withValues(alpha: 0.4))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(S.get('recoverPwSuccess'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: SanctumTheme.gold)),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: Text(_showResult ? _recovered! : '•' * _recovered!.length.clamp(8, 20), style: TextStyle(fontSize: 14, color: sc.textPrimary, fontFamily: 'monospace'))),
                IconButton(icon: Icon(_showResult ? Icons.visibility_off : Icons.visibility, size: 18, color: sc.textTertiary), onPressed: () => setState(() => _showResult = !_showResult)),
                IconButton(icon: const Icon(Icons.copy, size: 18, color: SanctumTheme.gold), onPressed: () { SensitiveClipboard.instance.copy(_recovered!); _snack(S.get('copiedMasterPw')); }),
              ]),
              const SizedBox(height: 8),
              Text(S.get('copyPwWarn'), style: TextStyle(fontSize: 11, color: sc.textTertiary)),
            ]),
          ),
        ],
        const SizedBox(height: 40),
      ]),
    );
  }
}

// ── v3 Generate Tab (DEK recovery — splits a full-entropy key, not the pw) ──────

class _V3GenerateTab extends StatefulWidget {
  const _V3GenerateTab();
  @override
  State<_V3GenerateTab> createState() => _V3GenerateTabState();
}

class _V3GenerateTabState extends State<_V3GenerateTab> {
  final _pwCtrl = TextEditingController();
  bool _showPw = false;
  int _n = 5, _k = 3;
  List<String>? _shareCodes; // base64 of the v3 share envelopes
  bool _generating = false;
  String? _error;

  @override
  void dispose() { _pwCtrl.dispose(); super.dispose(); }

  Future<void> _generate() async {
    // Master password is the DEK-unwrap key; do NOT trim (must match exactly).
    final pw = _pwCtrl.text;
    if (pw.isEmpty) { setState(() => _error = S.get('enterMasterPw')); return; }
    setState(() { _generating = true; _error = null; });
    try {
      final shares = await vaultService.enableV3Recovery(pw, n: _n, k: _k);
      setState(() {
        _shareCodes = shares.map(base64Encode).toList();
        _generating = false;
      });
    } catch (_) {
      // Only failure here is a wrong master password (fail-closed).
      setState(() { _generating = false; _error = S.get('wrongPwGen'); });
    }
  }

  void _reset() => setState(() { _shareCodes = null; _pwCtrl.clear(); _error = null; });
  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: context.sc.bg3, behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2))); }
  void _copy(String t) { SensitiveClipboard.instance.copy(t); _snack(S.copied); }

  // V-07: per-share export only — one share, one destination. No aggregate action.
  void _exportOne(int i) {
    if (_shareCodes == null) return;
    Share.share(_shareCodes![i], subject: S.get('shardDocSubject').replaceAll('{i}', '${i+1}').replaceAll('{n}', '$_n'));
  }

  @override
  Widget build(BuildContext context) => _shareCodes != null ? _results() : _config();

  Widget _config() {
    final sc = context.sc;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _InfoBox(S.get('shamirIntroV3')),
        const SizedBox(height: 12),
        // C-a: mandatory semantic notice — recovery does NOT reveal the password.
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: SanctumTheme.amber.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: SanctumTheme.amber.withValues(alpha: 0.3)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('⚠️', style: TextStyle(fontSize: 16)),
            const SizedBox(width: 8),
            Expanded(child: Text(
              S.get('recoverNoRevealHint'),
              style: const TextStyle(fontSize: 12, color: SanctumTheme.amber, height: 1.5),
            )),
          ]),
        ),
        const SizedBox(height: 20),
        _Label(S.masterPassword), const SizedBox(height: 6),
        TextField(
          controller: _pwCtrl, obscureText: !_showPw,
          enableSuggestions: false, autocorrect: false,
          style: TextStyle(color: sc.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            hintText: S.get('enterCurrentMasterPw'), filled: true, fillColor: sc.bg2,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: SanctumTheme.gold)),
            suffixIcon: IconButton(icon: Icon(_showPw ? Icons.visibility_off : Icons.visibility, size: 18, color: sc.textTertiary), onPressed: () => setState(() => _showPw = !_showPw)),
          ),
        ),
        const SizedBox(height: 20),
        _SliderRow(label: S.get('totalShardsN'), value: _n, min: 3, max: 10, onChanged: (v) => setState(() { _n = v; if (_k > _n) _k = _n; })),
        const SizedBox(height: 12),
        _SliderRow(label: S.get('thresholdK'), value: _k, min: 2, max: _n, onChanged: (v) => setState(() => _k = v)),
        const SizedBox(height: 8),
        Text(S.get('shamirKofN').replaceAll('{k}', '$_k').replaceAll('{n}', '$_n'), style: const TextStyle(fontSize: 12, color: SanctumTheme.gold)),
        if (_error != null) ...[
          const SizedBox(height: 16),
          _ErrorBox(_error!),
        ],
        const SizedBox(height: 24),
        SizedBox(width: double.infinity, child: ElevatedButton(
          onPressed: _generating ? null : _generate,
          style: ElevatedButton.styleFrom(backgroundColor: SanctumTheme.gold, foregroundColor: sc.bg, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          child: _generating ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: sc.bg)) : Text(S.get('genShards'), style: TextStyle(fontWeight: FontWeight.w600)),
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
          Expanded(child: Text(S.get('shardsGenerated').replaceAll('{n}', '$_n').replaceAll('{k}', '$_k'), style: TextStyle(fontSize: 13, color: sc.textPrimary))),
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
          style: OutlinedButton.styleFrom(foregroundColor: sc.textTertiary, side: BorderSide(color: sc.border), padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          child: Text(S.get('doneBtn')),
        )),
      )),
    ]);
  }
}

// ── v3 Recover Tab (reconstruct DEK, force a NEW master password) ────────────────

class _V3RecoverTab extends ConsumerStatefulWidget {
  const _V3RecoverTab();
  @override
  ConsumerState<_V3RecoverTab> createState() => _V3RecoverTabState();
}

class _V3RecoverTabState extends ConsumerState<_V3RecoverTab> {
  final List<TextEditingController> _ctrls = [];
  final _newPw1 = TextEditingController();
  final _newPw2 = TextEditingController();
  int _shareCount = 3;
  bool _showPw = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() { super.initState(); _rebuild(_shareCount); }
  @override
  void dispose() {
    for (final c in _ctrls) { c.dispose(); }
    _newPw1.dispose();
    _newPw2.dispose();
    super.dispose();
  }

  void _rebuild(int count) {
    while (_ctrls.length > count) { _ctrls.removeLast().dispose(); }
    while (_ctrls.length < count) { _ctrls.add(TextEditingController()); }
  }

  Future<void> _recover() async {
    setState(() => _error = null);
    // 1. All share fields filled (pure UI validation, no crypto).
    final shares = <Uint8List>[];
    for (var i = 0; i < _ctrls.length; i++) {
      final raw = _ctrls[i].text.trim();
      if (raw.isEmpty) { setState(() => _error = S.get('shardEmpty').replaceAll('{i}', '${i+1}')); return; }
      Uint8List? bytes;
      try { bytes = base64Decode(raw); } catch (_) { bytes = null; }
      if (bytes == null) {
        // C-e: parse failure merges into the single tamper message.
        setState(() => _error = S.get('shardTampered')); return;
      }
      shares.add(bytes);
    }
    // 2. New master password — SAME strength rule as vault creation (>= 12);
    //    not loosened, not tightened (C-d).
    final pw1 = _newPw1.text, pw2 = _newPw2.text;
    if (pw1.length < 12) { setState(() => _error = S.get('newPwMinLen')); return; }
    if (pw1 != pw2) { setState(() => _error = S.get('newPwMismatch')); return; }

    setState(() => _busy = true);
    try {
      await vaultService.recoverV3(shares, pw1);
    } on StateError {
      // Recovery was never enabled for this vault — a config state, not a crypto
      // failure. Distinct, non-leaking message.
      if (mounted) setState(() { _busy = false; _error = S.get('shamirNotEnabled'); });
      return;
    } catch (_) {
      // C-e: insufficient / mixed / duplicate index / MAC / commit / wrong R —
      // ALL merged into one message. No partial result is surfaced or kept.
      if (mounted) setState(() { _busy = false; _error = S.get('shardTampered'); });
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    // C-f: forced re-lock with the NEW master password (never displayed).
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
        content: Text(S.get('recoverDoneMsg'),
          style: TextStyle(color: context.sc.textSecondary, fontSize: 13, height: 1.6)),
        actions: [
          TextButton(
            onPressed: () { Navigator.pop(context); ref.read(authProvider.notifier).lock(); },
            child: Text(S.confirm, style: TextStyle(color: SanctumTheme.gold, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _InfoBox(S.get('pasteShardsV3Hint')),
        const SizedBox(height: 20),
        _SliderRow(label: S.get('shardCount'), value: _shareCount, min: 2, max: 10, onChanged: (v) => setState(() { _shareCount = v; _rebuild(v); _error = null; })),
        const SizedBox(height: 20),
        for (int i = 0; i < _shareCount; i++) ...[
          _Label(S.get('shardN').replaceAll('{i}', '${i+1}')), const SizedBox(height: 6),
          TextField(
            controller: _ctrls[i],
            style: TextStyle(color: sc.textPrimary, fontSize: 12, fontFamily: 'monospace'),
            maxLines: 2,
            enableSuggestions: false, autocorrect: false,
            decoration: InputDecoration(
              hintText: S.get('pasteShardCode'), hintStyle: const TextStyle(fontSize: 11),
              filled: true, fillColor: sc.bg2,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: SanctumTheme.gold)),
            ),
            onChanged: (_) => setState(() => _error = null),
          ),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 4),
        _Label(S.get('newPwLabel')), const SizedBox(height: 6),
        TextField(
          controller: _newPw1, obscureText: !_showPw,
          enableSuggestions: false, autocorrect: false,
          style: TextStyle(color: sc.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            hintText: S.get('setNewPw'), filled: true, fillColor: sc.bg2,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: SanctumTheme.gold)),
            suffixIcon: IconButton(icon: Icon(_showPw ? Icons.visibility_off : Icons.visibility, size: 18, color: sc.textTertiary), onPressed: () => setState(() => _showPw = !_showPw)),
          ),
        ),
        const SizedBox(height: 12),
        _Label(S.get('confirmNewPw')), const SizedBox(height: 6),
        TextField(
          controller: _newPw2, obscureText: !_showPw,
          enableSuggestions: false, autocorrect: false,
          style: TextStyle(color: sc.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            hintText: S.get('reenterNewPw'), filled: true, fillColor: sc.bg2,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: SanctumTheme.gold)),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          _ErrorBox(_error!),
        ],
        const SizedBox(height: 20),
        SizedBox(width: double.infinity, child: ElevatedButton(
          onPressed: _busy ? null : _recover,
          style: ElevatedButton.styleFrom(backgroundColor: SanctumTheme.gold, foregroundColor: sc.bg, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          child: _busy ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: sc.bg)) : Text(S.get('recoverSetNewPw'), style: TextStyle(fontWeight: FontWeight.w600)),
        )),
        const SizedBox(height: 40),
      ]),
    );
  }
}

// ── Shared Widgets ────────────────────────────────────────────────────────────

class _ErrorBox extends StatelessWidget {
  final String text; const _ErrorBox(this.text);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(color: SanctumTheme.red.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
    child: Row(children: [
      const Icon(Icons.error_outline, color: SanctumTheme.red, size: 16), const SizedBox(width: 8),
      Expanded(child: Text(text, style: const TextStyle(fontSize: 12, color: SanctumTheme.red))),
    ]),
  );
}

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
            child: Text(S.get('shardIofN').replaceAll('{i}', '${index+1}').replaceAll('{n}', '$total'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: SanctumTheme.gold))),
          const Spacer(),
          _MiniBtn(label: S.copy, icon: Icons.copy, onTap: onCopy),
          const SizedBox(width: 6),
          _MiniBtn(label: S.get('shareBtn'), icon: Icons.share, onTap: onExport),
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
