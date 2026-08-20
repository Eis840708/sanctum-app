import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/i18n/lang_provider.dart';
import '../../../core/models/models.dart';
import '../../../core/storage/vault_service.dart';
import '../../../shared/theme/app_theme.dart';

class SearchScreen extends ConsumerStatefulWidget {
  final String? initialQuery;
  const SearchScreen({super.key, this.initialQuery});
  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _ctrl = TextEditingController();
  String _query = '';
  List<PasswordEntry> _passwords = [];
  List<DiaryEntry>    _diary     = [];
  List<FinanceRecord> _finance   = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
      _ctrl.text = widget.initialQuery!;
      _query = widget.initialQuery!.toLowerCase().trim();
    }
    _ctrl.addListener(() {
      setState(() => _query = _ctrl.text.toLowerCase().trim());
    });
  }

  @override
  void didUpdateWidget(covariant SearchScreen old) {
    super.didUpdateWidget(old);
    if (widget.initialQuery != old.initialQuery && widget.initialQuery != null) {
      final q = widget.initialQuery!.toLowerCase().trim();
      if (q != _query) setState(() => _query = q);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loaded = false);
    try {
      final pw = await vaultService.getPasswords();
      final di = await vaultService.getDiaryEntries();
      final fi = await vaultService.getFinanceRecords();
      if (mounted) setState(() {
        _passwords = pw;
        _diary     = di;
        _finance   = fi;
        _loaded    = true;
      });
    } catch (e) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  List<PasswordEntry> get _filteredPw => _query.isEmpty ? [] :
    _passwords.where((p) =>
      p.site.toLowerCase().contains(_query) ||
      p.username.toLowerCase().contains(_query) ||
      p.notes.toLowerCase().contains(_query)).toList();

  List<DiaryEntry> get _filteredDiary => _query.isEmpty ? [] :
    _diary.where((d) =>
      d.title.toLowerCase().contains(_query) ||
      d.encryptedContent.toLowerCase().contains(_query) ||
      d.mood.toLowerCase().contains(_query)).toList();

  List<FinanceRecord> get _filteredFinance => _query.isEmpty ? [] :
    _finance.where((f) =>
      f.description.toLowerCase().contains(_query) ||
      S.catLabel(f.category).toLowerCase().contains(_query)).toList();

  int get _total => _filteredPw.length + _filteredDiary.length + _filteredFinance.length;

  @override
  Widget build(BuildContext context) {
    ref.watch(langProvider);
    final inDelegateMode = widget.initialQuery != null;
    return Column(children: [
      // Search bar — only show when NOT in delegate mode
      if (!inDelegateMode)
        Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(children: [
            Expanded(child: TextField(
              controller: _ctrl,
              autofocus: false,
              style: TextStyle(color: context.sc.textPrimary, fontSize: 15),
              decoration: InputDecoration(
                hintText: S.searchHint,
                prefixIcon: Icon(Icons.search, color: context.sc.textTertiary, size: 20),
                suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.clear, size: 16, color: context.sc.textTertiary),
                      onPressed: () { _ctrl.clear(); setState(() => _query = ''); },
                    )
                  : null,
              ),
            )),
            SizedBox(width: 8),
            GestureDetector(
              onTap: _load,
              child: Container(
                padding: EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: context.sc.bg3,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: context.sc.border),
                ),
                child: Icon(Icons.refresh, size: 18, color: context.sc.textTertiary),
              ),
            ),
          ]),
        ),

      // Status row
      if (_query.isNotEmpty)
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(children: [
            Text(
              _loaded
                ? '${S.searchResults} · $_total  (${S.passwords}: ${_filteredPw.length}  ${S.diary}: ${_filteredDiary.length}  ${S.finance}: ${_filteredFinance.length})'
                : S.get('loading'),
              style: TextStyle(fontSize: 11, color: context.sc.textTertiary),
            ),
          ]),
        ),

      Expanded(child: !_loaded
        ? const Center(child: CircularProgressIndicator(color: SanctumTheme.gold))
        : _query.isEmpty
          ? _emptySearch()
          : _total == 0
            ? _noResults()
            : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: [
                if (_filteredPw.isNotEmpty) ...[
                  _SectionLabel(emoji: '🔑', label: S.passwords, count: _filteredPw.length),
                  ..._filteredPw.map((p) => _PwResult(entry: p)),
                ],
                if (_filteredDiary.isNotEmpty) ...[
                  _SectionLabel(emoji: '📔', label: S.diary, count: _filteredDiary.length),
                  ..._filteredDiary.map((d) => _DiaryResult(entry: d)),
                ],
                if (_filteredFinance.isNotEmpty) ...[
                  _SectionLabel(emoji: '💰', label: S.finance, count: _filteredFinance.length),
                  ..._filteredFinance.map((f) => _FinanceResult(record: f)),
                ],
              ]),
      ),
    ]);
  }

  Widget _emptySearch() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text('🔍', style: TextStyle(fontSize: 40)),
      SizedBox(height: 12),
      Text(S.search, style: TextStyle(fontSize: 16, color: context.sc.textSecondary, fontWeight: FontWeight.w500)),
      SizedBox(height: 6),
      Text(S.searchHint, style: TextStyle(fontSize: 13, color: context.sc.textTertiary)),
    ]),
  );

  Widget _noResults() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text('😶', style: TextStyle(fontSize: 40)),
      SizedBox(height: 12),
      Text(S.noResults, style: TextStyle(fontSize: 16, color: context.sc.textSecondary)),
    ]),
  );
}

class _SectionLabel extends StatelessWidget {
  final String emoji, label;
  final int count;
  const _SectionLabel({required this.emoji, required this.label, required this.count});

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: 16, bottom: 8),
    child: Row(children: [
      Text(emoji, style: TextStyle(fontSize: 14)),
      SizedBox(width: 6),
      Text(label.toUpperCase(), style: TextStyle(fontSize: 11, color: context.sc.textTertiary, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
      SizedBox(width: 6),
      Container(
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: context.sc.bg3, borderRadius: BorderRadius.circular(8)),
        child: Text('$count', style: TextStyle(fontSize: 10, color: context.sc.textTertiary)),
      ),
    ]),
  );
}

class _PwResult extends StatelessWidget {
  final PasswordEntry entry;
  const _PwResult({required this.entry});

  @override
  Widget build(BuildContext context) => Container(
    margin: EdgeInsets.only(bottom: 8),
    padding: EdgeInsets.all(12),
    decoration: BoxDecoration(color: context.sc.bg2, borderRadius: BorderRadius.circular(10), border: Border.all(color: context.sc.border)),
    child: Row(children: [
      Container(
        width: 32, height: 32,
        decoration: BoxDecoration(color: SanctumTheme.purpleDim, borderRadius: BorderRadius.circular(7)),
        child: Center(child: Text(entry.site[0].toUpperCase(),
          style: TextStyle(color: SanctumTheme.purple, fontWeight: FontWeight.w600))),
      ),
      SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(entry.site, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: context.sc.textPrimary)),
        Text(entry.username, style: TextStyle(fontSize: 12, color: context.sc.textTertiary)),
      ])),
      GestureDetector(
        onTap: () async {
          final pw = await vaultService.decryptPassword(entry);
          await Clipboard.setData(ClipboardData(text: pw));
          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.copied), backgroundColor: context.sc.bg3,
              behavior: SnackBarBehavior.floating, duration: Duration(seconds: 2)));
        },
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: context.sc.bg3, borderRadius: BorderRadius.circular(6), border: Border.all(color: context.sc.border)),
          child: Text(S.copy, style: TextStyle(fontSize: 11, color: context.sc.textTertiary)),
        ),
      ),
    ]),
  );
}

class _DiaryResult extends StatelessWidget {
  final DiaryEntry entry;
  const _DiaryResult({required this.entry});

  @override
  Widget build(BuildContext context) => Container(
    margin: EdgeInsets.only(bottom: 8),
    padding: EdgeInsets.all(12),
    decoration: BoxDecoration(color: context.sc.bg2, borderRadius: BorderRadius.circular(10), border: Border.all(color: context.sc.border)),
    child: Row(children: [
      Text(entry.mood, style: TextStyle(fontSize: 22)),
      SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(entry.title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: context.sc.textPrimary)),
        Text(DateFormat('MMM d, yyyy').format(entry.createdAt),
          style: TextStyle(fontSize: 11, color: context.sc.textTertiary)),
      ])),
    ]),
  );
}

class _FinanceResult extends StatelessWidget {
  final FinanceRecord record;
  const _FinanceResult({required this.record});

  @override
  Widget build(BuildContext context) => Container(
    margin: EdgeInsets.only(bottom: 8),
    padding: EdgeInsets.all(12),
    decoration: BoxDecoration(color: context.sc.bg2, borderRadius: BorderRadius.circular(10), border: Border.all(color: context.sc.border)),
    child: Row(children: [
      Container(
        width: 32, height: 32,
        decoration: BoxDecoration(
          color: record.isIncome ? SanctumTheme.greenDim : SanctumTheme.redDim,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Center(child: Text(record.isIncome ? '↑' : '↓',
          style: TextStyle(fontWeight: FontWeight.w700, color: record.isIncome ? SanctumTheme.green : SanctumTheme.red))),
      ),
      SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(S.catLabel(record.category), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: context.sc.textPrimary)),
        if (record.description.isNotEmpty)
          Text(record.description, style: TextStyle(fontSize: 11, color: context.sc.textTertiary)),
      ])),
      Text(
        '${record.isIncome ? '+' : '−'}\$${NumberFormat('#,##0.##').format(record.amount)}',
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
          color: record.isIncome ? SanctumTheme.green : SanctumTheme.red),
      ),
    ]),
  );
}
