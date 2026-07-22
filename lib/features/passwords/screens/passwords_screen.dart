import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/i18n/lang_provider.dart';
import '../../../core/models/models.dart';
import '../../../core/storage/providers.dart';
import '../../../core/storage/vault_service.dart';
import '../../../core/crypto/crypto_service.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/widgets.dart';

// ── Expiry thresholds ─────────────────────────────────────────
const _kWarnDays = 90;   // yellow
const _kExpireDays = 180; // red

// ── Clipboard auto-clear duration ─────────────────────────────
const _kClipClearSecs = 30;

class PasswordsScreen extends ConsumerStatefulWidget {
  const PasswordsScreen({super.key});
  @override
  ConsumerState<PasswordsScreen> createState() => _PasswordsScreenState();
}

class _PasswordsScreenState extends ConsumerState<PasswordsScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) =>
      ref.read(passwordsNotifierProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(langProvider);
    final sc = context.sc;
    final state = ref.watch(passwordsNotifierProvider);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: TextField(
          controller: _search,
          onChanged: (v) => setState(() => _query = v.toLowerCase()),
          style: TextStyle(color: sc.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            hintText: '${S.search}…',
            prefixIcon: Icon(Icons.search, color: sc.textTertiary, size: 18),
            suffixIcon: _query.isNotEmpty
              ? IconButton(icon: Icon(Icons.clear, size: 16, color: sc.textTertiary),
                  onPressed: () { _search.clear(); setState(() => _query = ''); })
              : null,
          ),
        ),
      ),
      Expanded(child: state.when(
        loading: () => const Center(child: CircularProgressIndicator(color: SanctumTheme.gold)),
        error: (e, _) => Center(child: Text('$e')),
        data: (all) {
          final items = all.where((p) =>
            _query.isEmpty ||
            p.site.toLowerCase().contains(_query) ||
            p.username.toLowerCase().contains(_query)
          ).toList();

          return CustomScrollView(slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              sliver: SliverToBoxAdapter(child: SectionHeader(
                title: S.passwords, count: items.length,
                action: GoldAddButton(label: S.add, onTap: () => _showAddSheet(context)),
              )),
            ),
            if (items.isEmpty)
              SliverFillRemaining(child: EmptyState(
                emoji: '🔑', title: S.noPasswords, subtitle: S.noPasswordsSub,
                action: GoldAddButton(label: S.addPassword, onTap: () => _showAddSheet(context)),
              ))
            else
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverList(delegate: SliverChildBuilderDelegate(
                  (_, i) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Dismissible(
                      key: ValueKey(items[i].id),
                      direction: DismissDirection.endToStart,
                      confirmDismiss: (_) async {
                        return await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: sc.bg2,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            title: Text(S.get('deletePasswordTitle'), style: TextStyle(color: sc.textPrimary, fontWeight: FontWeight.w600)),
                            content: Text('確定刪除「${items[i].site}」？\n刪除後可在提示中復原。',
                              style: TextStyle(color: sc.textSecondary, fontSize: 14)),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false),
                                child: Text(S.cancel, style: TextStyle(color: sc.textSecondary))),
                              TextButton(onPressed: () => Navigator.pop(ctx, true),
                                child: Text(S.delete as String, style: TextStyle(color: SanctumTheme.red, fontWeight: FontWeight.w600))),
                            ],
                          ),
                        ) ?? false;
                      },
                      onDismissed: (_) async {
                        HapticFeedback.mediumImpact();
                        final site   = items[i].site;
                        final backup = vaultService.getRawPasswordEntry(items[i].id);
                        await ref.read(passwordsNotifierProvider.notifier).delete(items[i].id);
                        if (!mounted || backup == null) return;
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(SnackBar(
                            content: Text('已刪除「$site」'),
                            duration: const Duration(seconds: 5),
                            backgroundColor: sc.bg2,
                            behavior: SnackBarBehavior.floating,
                            action: SnackBarAction(
                              label: S.get('undo'),
                              textColor: SanctumTheme.gold,
                              onPressed: () async {
                                await vaultService.restoreRawPasswordEntry(backup);
                                ref.read(passwordsNotifierProvider.notifier).load();
                              },
                            ),
                          ));
                      },
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        decoration: BoxDecoration(
                          color: SanctumTheme.red.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.delete_outline,
                            color: SanctumTheme.red, size: 22),
                      ),
                      child: _PasswordCard(
                        entry: items[i],
                        onEdit: () => _showEditSheet(context, items[i]),
                      ),
                    ),
                  ),
                  childCount: items.length,
                )),
              ),
          ]);
        },
      )),
    ]);
  }

  void _showAddSheet(BuildContext context) {
    final sc = context.sc;
    final site  = TextEditingController();
    final user  = TextEditingController();
    final pw    = TextEditingController();
    final notes = TextEditingController();
    bool showPw = false;
    int strength = 0;

    showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: sc.bg2,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Padding(
          padding: EdgeInsets.only(left: 20, right: 20, top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(
                  color: sc.border2, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 16),
              Text(S.addPassword, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600,
                  color: sc.textPrimary)),
              const SizedBox(height: 16),
              SanctumField(label: S.site, hint: 'google.com', controller: site),
              SanctumField(label: S.username, hint: 'you@example.com', controller: user),
              _PwField(
                controller: pw, showPw: showPw, strength: strength,
                onToggle: () => setSt(() => showPw = !showPw),
                onGenerate: () {
                  final g = cryptoService.generatePassword();
                  pw.text = g;
                  setSt(() { showPw = true; strength = cryptoService.passwordStrength(g); });
                },
                onChanged: (v) => setSt(() => strength = cryptoService.passwordStrength(v)),
              ),
              SanctumField(label: S.notes, controller: notes),
              const SizedBox(height: 4),
              SizedBox(width: double.infinity, child: ElevatedButton(
                onPressed: () async {
                  if (site.text.isEmpty || user.text.isEmpty || pw.text.isEmpty) return;
                  await ref.read(passwordsNotifierProvider.notifier).add(
                    site: site.text, username: user.text,
                    password: pw.text, notes: notes.text);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: Text(S.save),
              )),
            ],
          )),
        ),
      ),
    );
  }

  void _showEditSheet(BuildContext context, PasswordEntry entry) {
    final sc = context.sc;
    final site  = TextEditingController(text: entry.site);
    final user  = TextEditingController(text: entry.username);
    final pw    = TextEditingController();
    final notes = TextEditingController(text: entry.notes);
    bool showPw = false;
    int strength = 0;
    bool pwChanged = false;

    showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: sc.bg2,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Padding(
          padding: EdgeInsets.only(left: 20, right: 20, top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(
                  color: sc.border2, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 16),
              Row(children: [
                Text('編輯密碼', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600,
                    color: sc.textPrimary)),
                const Spacer(),
                // Delete button in edit sheet
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 16, color: SanctumTheme.red),
                  label: const Text('刪除', style: TextStyle(fontSize: 13, color: SanctumTheme.red)),
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: ctx,
                      builder: (d) => AlertDialog(
                        backgroundColor: sc.bg2,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        title: Text(S.get('deletePasswordTitle'), style: TextStyle(color: sc.textPrimary, fontWeight: FontWeight.w600)),
                        content: Text('確定刪除「${entry.site}」？\n刪除後可在提示中復原。',
                          style: TextStyle(color: sc.textSecondary, fontSize: 14)),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(d, false),
                            child: Text(S.cancel, style: TextStyle(color: sc.textSecondary))),
                          TextButton(onPressed: () => Navigator.pop(d, true),
                            child: Text(S.delete, style: const TextStyle(color: SanctumTheme.red, fontWeight: FontWeight.w600))),
                        ],
                      ),
                    ) ?? false;
                    if (!confirmed) return;
                    final backup = vaultService.getRawPasswordEntry(entry.id);
                    Navigator.pop(ctx);
                    await ref.read(passwordsNotifierProvider.notifier).delete(entry.id);
                    if (!context.mounted || backup == null) return;
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(
                        content: Text('已刪除「${entry.site}」'),
                        duration: const Duration(seconds: 5),
                        backgroundColor: sc.bg2,
                        behavior: SnackBarBehavior.floating,
                        action: SnackBarAction(
                          label: S.get('undo'),
                          textColor: SanctumTheme.gold,
                          onPressed: () async {
                            await vaultService.restoreRawPasswordEntry(backup);
                            ref.read(passwordsNotifierProvider.notifier).load();
                          },
                        ),
                      ));
                  },
                ),
              ]),
              const SizedBox(height: 16),
              SanctumField(label: S.site, hint: 'google.com', controller: site),
              SanctumField(label: S.username, hint: 'you@example.com', controller: user),
              // Password field with hint that it's optional
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(S.password, style: TextStyle(fontSize: 12, color: sc.textTertiary)),
                  const SizedBox(width: 6),
                  Text('（留空則不修改）', style: TextStyle(fontSize: 11, color: sc.textTertiary)),
                ]),
                const SizedBox(height: 5),
                _PwField(
                  controller: pw, showPw: showPw, strength: strength,
                  onToggle: () => setSt(() => showPw = !showPw),
                  onGenerate: () {
                    final g = cryptoService.generatePassword();
                    pw.text = g;
                    setSt(() { showPw = true; strength = cryptoService.passwordStrength(g); pwChanged = true; });
                  },
                  onChanged: (v) => setSt(() {
                    strength = v.isEmpty ? 0 : cryptoService.passwordStrength(v);
                    pwChanged = v.isNotEmpty;
                  }),
                ),
              ]),
              SanctumField(label: S.notes, controller: notes),
              const SizedBox(height: 4),
              SizedBox(width: double.infinity, child: ElevatedButton(
                onPressed: () async {
                  if (site.text.isEmpty || user.text.isEmpty) return;
                  await ref.read(passwordsNotifierProvider.notifier).update(
                    entry,
                    site: site.text,
                    username: user.text,
                    password: pwChanged && pw.text.isNotEmpty ? pw.text : null,
                    notes: notes.text,
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: Text(S.save),
              )),
            ],
          )),
        ),
      ),
    );
  }
}

// ── Password field with show/hide + generate ──────────────────
class _PwField extends StatelessWidget {
  final TextEditingController controller;
  final bool showPw;
  final int strength;
  final VoidCallback onToggle, onGenerate;
  final ValueChanged<String> onChanged;

  const _PwField({
    required this.controller, required this.showPw, required this.strength,
    required this.onToggle, required this.onGenerate, required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextFormField(
        controller: controller,
        obscureText: !showPw,
        onChanged: onChanged,
        style: TextStyle(color: sc.textPrimary, fontSize: 14),
        decoration: InputDecoration(
          hintText: '••••••••',
          suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              icon: Icon(showPw ? Icons.visibility_off : Icons.visibility,
                  size: 18, color: sc.textTertiary),
              onPressed: onToggle,
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 18, color: SanctumTheme.gold),
              onPressed: onGenerate,
            ),
          ]),
        ),
      ),
      PasswordStrengthBar(strength: strength),
      const SizedBox(height: 12),
    ]);
  }
}

// ── Password card ─────────────────────────────────────────────
class _PasswordCard extends ConsumerStatefulWidget {
  final PasswordEntry entry;
  final VoidCallback onEdit;
  const _PasswordCard({required this.entry, required this.onEdit});

  @override
  ConsumerState<_PasswordCard> createState() => _PasswordCardState();
}

class _PasswordCardState extends ConsumerState<_PasswordCard> {
  Timer? _clipTimer;
  int    _clipSecs = 0;

  @override
  void dispose() {
    _clipTimer?.cancel();
    super.dispose();
  }

  void _copy(BuildContext ctx, String text, {bool isPassword = false}) {
    Clipboard.setData(ClipboardData(text: text));

    if (isPassword) {
      _clipTimer?.cancel();
      setState(() => _clipSecs = _kClipClearSecs);
      _clipTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) { t.cancel(); return; }
        setState(() => _clipSecs--);
        if (_clipSecs <= 0) {
          t.cancel();
          Clipboard.setData(const ClipboardData(text: ''));
        }
      });
    }

    final msg = isPassword ? '密碼已複製（$_kClipClearSecs 秒後自動清除）' : '${S.copied}';
    ScaffoldMessenger.of(ctx).clearSnackBars();
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: ctx.sc.bg3,
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: isPassword ? _kClipClearSecs : 2),
    ));
  }

  // Expiry state based on last update date
  _ExpiryState get _expiry {
    final days = DateTime.now().difference(widget.entry.updatedAt).inDays;
    if (days >= _kExpireDays) return _ExpiryState.expired;
    if (days >= _kWarnDays)   return _ExpiryState.warning;
    return _ExpiryState.ok;
  }

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    final exp = _expiry;
    return VaultCard(
      accentColor: exp == _ExpiryState.expired ? SanctumTheme.red
          : exp == _ExpiryState.warning ? SanctumTheme.amber
          : SanctumTheme.purple,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AvatarIcon(fallback: widget.entry.site, background: SanctumTheme.purpleDim),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.entry.site, style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w500, color: sc.textPrimary)),
            Text(widget.entry.username, style: TextStyle(
                fontSize: 12, color: sc.textTertiary)),
          ])),
          // Expiry badge
          if (exp != _ExpiryState.ok) _ExpiryBadge(state: exp),
          const SizedBox(width: 6),
          Text(_relativeDate(widget.entry.updatedAt),
              style: TextStyle(fontSize: 11, color: sc.textTertiary)),
        ]),

        // Clipboard countdown bar
        if (_clipSecs > 0) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: _clipSecs / _kClipClearSecs,
              backgroundColor: sc.bg3,
              valueColor: const AlwaysStoppedAnimation(SanctumTheme.amber),
              minHeight: 2,
            ),
          ).animate().fadeIn(duration: 200.ms),
          const SizedBox(height: 2),
          Text('剪貼簿將在 $_clipSecs 秒後清除',
            style: TextStyle(fontSize: 10, color: SanctumTheme.amber)),
        ],

        const SizedBox(height: 10),
        Row(children: [
          _CardBtn(label: S.copyUsername,
              onTap: () => _copy(context, widget.entry.username)),
          const SizedBox(width: 8),
          _CardBtn(label: S.copyPassword, onTap: () async {
            final pw = await vaultService.decryptPassword(widget.entry);
            if (context.mounted) _copy(context, pw, isPassword: true);
          }),
          const Spacer(),
          _CardBtn(label: '編輯', onTap: widget.onEdit),
        ]),
      ]),
    );
  }

  String _relativeDate(DateTime dt) {
    final diff = DateTime.now().difference(dt).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    if (diff < 7)  return '$diff 天前';
    if (diff < 30) return '${diff ~/ 7} 週前';
    if (diff < 365) return '${diff ~/ 30} 個月前';
    return '${diff ~/ 365} 年前';
  }
}

enum _ExpiryState { ok, warning, expired }

class _ExpiryBadge extends StatelessWidget {
  final _ExpiryState state;
  const _ExpiryBadge({required this.state});

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    final color = state == _ExpiryState.expired ? SanctumTheme.red : SanctumTheme.amber;
    final label = state == _ExpiryState.expired ? '已過期' : '建議更新';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label, style: TextStyle(fontSize: 9, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

class _CardBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _CardBtn({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: sc.bg3,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: sc.border),
        ),
        child: Text(label, style: TextStyle(fontSize: 11,
            color: sc.textTertiary)),
      ),
    );
  }
}
