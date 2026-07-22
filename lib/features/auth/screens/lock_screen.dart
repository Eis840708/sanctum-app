import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/i18n/lang_provider.dart';
import '../../../core/storage/providers.dart';
import '../../../core/storage/vault_service.dart';
import '../../../core/crypto/crypto_service.dart';
import '../../../shared/theme/app_theme.dart';
import 'onboarding_screen.dart';

class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});
  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  bool _isSetup = false;
  bool _showOnboarding = false;
  bool _loading = false;
  bool _showPw  = false;
  String _error = '';
  final _pw1 = TextEditingController();
  final _pw2 = TextEditingController();
  String _generatedKey = '';
  int _setupMethod = 0;
  bool _biometricAvailable = false;

  Future<void> _checkBiometric() async {
    final hasHardware = await vaultService.canUseBiometric();
    if (mounted) {
      setState(() => _biometricAvailable = hasHardware);
    }
  }

  Future<void> _unlockWithBiometric() async {
    setState(() => _loading = true);
    try {
      final ok = await ref.read(authProvider.notifier).unlockWithBiometric();
      if (!ok) {
        if (mounted) setState(() { _loading = false; _error = S.get('bioFail'); });
        return;
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      String msg = S.get('bioError');
      final str = e.toString();
      if (str.contains('biometric_key_missing')) {
        msg = S.get('bioKeyMissing');
      } else if (str.contains('not_enrolled') || str.contains('NotEnrolled')) {
        msg = S.get('bioNotEnrolled');
      } else if (str.contains('not_available') || str.contains('NotAvailable')) {
        msg = S.get('bioNotAvailable');
      } else if (str.contains('locked_out') || str.contains('LockedOut')) {
        msg = S.get('bioLockedOut');
      }
      if (mounted) setState(() { _loading = false; _error = msg; });
    }
  }

  @override
  void initState() {
    super.initState();
    _isSetup = !vaultService.hasVault;
    _showOnboarding = _isSetup; // show onboarding only on first setup
    _checkBiometric();
  }

  @override
  void dispose() { _pw1.dispose(); _pw2.dispose(); super.dispose(); }

  Future<void> _submit() async {
    setState(() { _error = ''; _loading = true; });
    if (_isSetup) {
      if (_generatedKey.isEmpty && _pw1.text.length < 12) { setState(() { _error = S.get('generateKeyOrLongPw'); _loading = false; }); return; }
      if (_generatedKey.isNotEmpty && _pw1.text.trim() != _generatedKey) { setState(() { _error = S.get('keyMismatch'); _loading = false; }); return; }
      final vaultKey = _generatedKey.isNotEmpty ? _generatedKey : _pw1.text;
      await ref.read(authProvider.notifier).createVault(vaultKey);
    } else {
      final ok = await ref.read(authProvider.notifier).unlock(_pw1.text);
      if (!ok) { setState(() { _error = S.get('wrongPassword'); _loading = false; }); return; }
    }
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(langProvider);
    final sc = context.sc;
    if (_showOnboarding) {
      return OnboardingScreen(
        onDone: () => setState(() => _showOnboarding = false),
      );
    }
    return Scaffold(
    backgroundColor: sc.bg,
    body: Stack(children: [
      Positioned(
        top: MediaQuery.of(context).size.height * 0.3,
        left: MediaQuery.of(context).size.width * 0.5 - 150,
        child: Container(
          width: 300, height: 300,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [SanctumTheme.gold.withValues(alpha: 0.06), Colors.transparent]),
          ),
        ),
      ),
      SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(children: [
              _buildLogo().animate().fadeIn(duration: 600.ms).slideY(begin: -0.1),
              const SizedBox(height: 40),
              Container(
                constraints: const BoxConstraints(maxWidth: 380),
                decoration: BoxDecoration(
                  color: sc.bg2,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: sc.border),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 40, offset: const Offset(0, 20))],
                ),
                padding: const EdgeInsets.all(24),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // 僅在「無 vault（首次啟動）」時顯示 tab
                  if (!vaultService.hasVault) ...[
                    _buildTabs(),
                    const SizedBox(height: 20),
                  ],
                  // 換機引導：無 vault 且選了「解鎖」時，顯示指引而非密碼欄
                  if (!vaultService.hasVault && !_isSetup) ...[
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: sc.bg3,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: SanctumTheme.gold.withValues(alpha: 0.25)),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          const Icon(Icons.devices_outlined, color: SanctumTheme.gold, size: 16),
                          const SizedBox(width: 6),
                          Text(S.get('newDeviceTitle'), style: const TextStyle(fontSize: 13, color: SanctumTheme.gold, fontWeight: FontWeight.w600)),
                        ]),
                        const SizedBox(height: 10),
                        _StepItem(n: '1', text: S.get('newDeviceStep1')),
                        const SizedBox(height: 6),
                        _StepItem(n: '2', text: S.get('newDeviceStep2')),
                        const SizedBox(height: 6),
                        _StepItem(n: '3', text: S.get('newDeviceStep3')),
                        const SizedBox(height: 6),
                        _StepItem(n: '4', text: S.get('newDeviceStep4')),
                      ]),
                    ),
                  ] else ...[
                  Text(_isSetup ? (_generatedKey.isEmpty ? S.get('selectKeyType') : S.get('confirmKeyEntry')) : S.masterPassword,
                    style: TextStyle(fontSize: 12, color: sc.textTertiary)),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _pw1,
                    obscureText: !_showPw,
                    autofocus: true,
                    style: TextStyle(color: sc.textPrimary, fontSize: 16, letterSpacing: 2),
                    decoration: InputDecoration(
                      hintText: '••••••••••••',
                      hintStyle: const TextStyle(letterSpacing: 0),
                      suffixIcon: IconButton(
                        icon: Icon(_showPw ? Icons.visibility_off : Icons.visibility,
                          color: sc.textTertiary, size: 18),
                        onPressed: () => setState(() => _showPw = !_showPw),
                      ),
                    ),
                    onFieldSubmitted: (_) => !_isSetup ? _submit() : null,
                  ),
                  if (_isSetup) ...[
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _MethodBtn(label: S.get('randomKey'), sub: 'SK-XXXXXX-XXXXXX', icon: Icons.vpn_key, onTap: () => setState(() { _generatedKey = cryptoService.generateSecretKey(); _setupMethod = 1; _pw1.clear(); }))),
                const SizedBox(width: 8),
                Expanded(child: _MethodBtn(label: S.get('randomPhrase'), sub: '蘋果 火車 月亮…', icon: Icons.translate, onTap: () => setState(() { _generatedKey = cryptoService.generatePassphrase(); _setupMethod = 2; _pw1.clear(); }))),
              ]),
              if (_generatedKey.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(width: double.infinity, padding: EdgeInsets.all(14), decoration: BoxDecoration(color: sc.bg3, borderRadius: BorderRadius.circular(10), border: Border.all(color: SanctumTheme.gold.withValues(alpha: 0.4))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(Icons.key, color: SanctumTheme.gold, size: 14), const SizedBox(width: 6),
                    Text(_setupMethod == 1 ? S.get('yourKey') : S.get('yourPhrase'), style: const TextStyle(fontSize: 11, color: SanctumTheme.gold)),
                    const Spacer(),
                    GestureDetector(onTap: () { Clipboard.setData(ClipboardData(text: _generatedKey)); }, child: Icon(Icons.copy, color: sc.textTertiary, size: 14)),
                    const SizedBox(width: 8),
                    GestureDetector(onTap: () => setState(() { _generatedKey = _setupMethod == 1 ? cryptoService.generateSecretKey() : cryptoService.generatePassphrase(); _pw1.clear(); }), child: Icon(Icons.refresh, color: sc.textTertiary, size: 14)),
                  ]),
                  const SizedBox(height: 8),
                  SelectableText(_generatedKey, style: TextStyle(fontSize: 14, color: sc.textPrimary, fontWeight: FontWeight.w600, height: 1.5)),
                ])),
                const SizedBox(height: 10),
                Text(S.get('confirmKeyHint'), style: TextStyle(fontSize: 12, color: sc.textTertiary)),
              ],
              const SizedBox(height: 12),
              Container(padding: EdgeInsets.all(10), decoration: BoxDecoration(color: sc.bg3, borderRadius: BorderRadius.circular(8)), child: Text(S.get('keyWarning'), style: TextStyle(fontSize: 12, color: sc.textTertiary, height: 1.5))),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                        ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1A1400)))
                        : Text(_isSetup ? S.get('createVaultBtn') : S.unlockBtn),
                    ),
                  ),
                  if (!_isSetup && _biometricAvailable) ...[
                    const SizedBox(height: 16),
                    GestureDetector(
                      onTap: _loading ? null : _unlockWithBiometric,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.fingerprint, color: SanctumTheme.gold, size: 32),
                          const SizedBox(width: 8),
                          Text(S.get('bioUnlock'), style: const TextStyle(color: SanctumTheme.gold, fontSize: 14)),
                        ],
                      ),
                    ),
                  ],
                  if (_error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Center(child: Text(_error, style: const TextStyle(fontSize: 12, color: SanctumTheme.red))),
                    ),
                  ], // end else (password + buttons)
                ]),
              ).animate().fadeIn(duration: 500.ms, delay: 200.ms).slideY(begin: 0.05),
            ]),
          ),
        ),
      ),
    ]),
  );
  } // end build

  Widget _buildLogo() => Column(children: [
    Container(
      width: 72, height: 72,
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF1E1C2A), Color(0xFF2A2838)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: SanctumTheme.gold.withValues(alpha: 0.3)),
        boxShadow: [BoxShadow(color: SanctumTheme.gold.withValues(alpha: 0.1), blurRadius: 20)],
      ),
      child: const Center(child: Text('🔐', style: TextStyle(fontSize: 32))),
    ),
    const SizedBox(height: 14),
    ShaderMask(
      shaderCallback: (b) => SanctumDecor.goldGradient().createShader(b),
      child: const Text('Sanctum', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: Colors.white, letterSpacing: -0.5)),
    ),
    const SizedBox(height: 4),
    Text(S.tagline, style: TextStyle(fontSize: 13, color: context.sc.textTertiary)),
  ]);

  // 僅在無 vault 時呼叫此方法（換機引導 + 首次設定切換）
  Widget _buildTabs() => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(color: context.sc.bg3, borderRadius: BorderRadius.circular(8)),
    child: Row(children: [
      _Tab(label: S.get('tabFirstSetup'), active: _isSetup,  onTap: () => setState(() { _isSetup = true;  _error = ''; })),
      _Tab(label: S.get('tabDeviceRestore'), active: !_isSetup, onTap: () => setState(() { _isSetup = false; _error = ''; })),
    ]),
  );
}

class _StepItem extends StatelessWidget {
  final String n, text;
  const _StepItem({required this.n, required this.text});
  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Container(
      width: 18, height: 18,
      margin: const EdgeInsets.only(top: 1, right: 8),
      decoration: BoxDecoration(
        color: SanctumTheme.goldDim,
        shape: BoxShape.circle,
        border: Border.all(color: SanctumTheme.gold.withValues(alpha: 0.3)),
      ),
      child: Center(child: Text(n, style: const TextStyle(fontSize: 10, color: SanctumTheme.gold, fontWeight: FontWeight.w700))),
    ),
    Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: context.sc.textSecondary, height: 1.5))),
  ]);
}

class _Tab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _Tab({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return Expanded(child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: active ? sc.bg4 : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label, textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: active ? sc.textPrimary : sc.textTertiary)),
      ),
    ));
  }
}

class _MethodBtn extends StatelessWidget {
  final String label, sub;
  final IconData icon;
  final VoidCallback onTap;
  const _MethodBtn({required this.label, required this.sub, required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: sc.bg3, borderRadius: BorderRadius.circular(12), border: Border.all(color: sc.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: SanctumTheme.gold, size: 22),
          const SizedBox(height: 8),
          Text(label, style: TextStyle(fontSize: 14, color: sc.textPrimary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(sub, style: TextStyle(fontSize: 11, color: sc.textTertiary)),
        ]),
      ),
    );
  }
}
