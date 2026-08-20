import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'dart:math' as math;
import 'dart:io';
import '../../../core/i18n/strings.dart';
import '../../../core/i18n/lang_provider.dart';
import '../../../core/models/models.dart';
import '../../../core/storage/providers.dart';
import '../../../core/storage/vault_service.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/widgets.dart';
import '../services/receipt_service.dart'; // decodeLineItems, ReceiptService
import 'receipt_preview_screen.dart';

class FinanceScreen extends ConsumerStatefulWidget {
  const FinanceScreen({super.key});
  @override
  ConsumerState<FinanceScreen> createState() => _FinanceScreenState();
}

class _FinanceScreenState extends ConsumerState<FinanceScreen> {
  String _filter = 'all';
  bool _showChart = false;
  int? _filterYear;
  int? _filterMonth;
  DateTime? _customStart;
  DateTime? _customEnd;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) =>
      ref.read(financeNotifierProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(langProvider);
    final state = ref.watch(financeNotifierProvider);
    return state.when(
      loading: () => const Center(child: CircularProgressIndicator(color: SanctumTheme.gold)),
      error: (e, _) => Center(child: Text('$e')),
      data: (all) {
        var filtered = all.toList();
        if (_customStart != null && _customEnd != null) { final endDay = DateTime(_customEnd!.year, _customEnd!.month, _customEnd!.day + 1); filtered = filtered.where((r) => !r.date.isBefore(_customStart!) && r.date.isBefore(endDay)).toList(); } else if (_filterYear != null && _filterMonth != null) { filtered = filtered.where((r) => r.date.year == _filterYear && r.date.month == _filterMonth).toList(); }
        final totalIncome  = filtered.where((r) => r.isIncome).fold(0.0,  (s, r) => s + r.amount);
        final totalExpense = filtered.where((r) => !r.isIncome).fold(0.0, (s, r) => s + r.amount);
        final net = totalIncome - totalExpense;
        final items = _filter == 'all' ? filtered : filtered.where((r) => r.type == _filter).toList();

        return CustomScrollView(slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
            sliver: SliverToBoxAdapter(child: Column(children: [
              // Header
              Row(children: [
                Text(S.finance, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: context.sc.textPrimary, letterSpacing: -0.3)),
                Spacer(),
                // Chart toggle
                GestureDetector(
                  onTap: () => setState(() => _showChart = !_showChart),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _showChart ? SanctumTheme.goldDim : context.sc.bg2,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _showChart ? SanctumTheme.gold.withValues(alpha: 0.3) : context.sc.border),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.bar_chart, size: 14, color: _showChart ? SanctumTheme.gold2 : context.sc.textTertiary),
                      SizedBox(width: 4),
                      Text(S.chart, style: TextStyle(fontSize: 12, color: _showChart ? SanctumTheme.gold2 : context.sc.textTertiary)),
                    ]),
                  ),
                ),
                SizedBox(width: 8),
                // Scan button
                GestureDetector(
                  onTap: () => _showScanOptions(context),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: context.sc.bg2,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: context.sc.border),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.document_scanner_outlined, size: 14, color: context.sc.textTertiary),
                      SizedBox(width: 4),
                      Text(S.get('scanBtn'), style: TextStyle(fontSize: 12, color: context.sc.textTertiary)),
                    ]),
                  ),
                ),
                const SizedBox(width: 8),
                GoldAddButton(label: S.add, onTap: () => _showAddSheet(context)),
              ]),
              const SizedBox(height: 14),

              // Summary cards
              Row(children: [
                _SummaryCard(label: S.totalIncome,  amount: totalIncome,  color: SanctumTheme.green, prefix: '+'),
                const SizedBox(width: 8),
                _SummaryCard(label: S.totalExpense, amount: totalExpense, color: SanctumTheme.red,   prefix: '−'),
                const SizedBox(width: 8),
                _SummaryCard(label: S.netBalance,   amount: net.abs(),    color: net >= 0 ? SanctumTheme.blue : SanctumTheme.red, prefix: net >= 0 ? '+' : '−'),
              ]),
              const SizedBox(height: 12),

              // Chart
              if (_showChart && all.isNotEmpty) ...[
                _FinanceChart(records: filtered),
                const SizedBox(height: 12),
              ],

              // Filter chips
              Row(children: [
                _Chip(label: S.all,     active: _filter == 'all',     onTap: () => setState(() => _filter = 'all')),
                const SizedBox(width: 6),
                _Chip(label: S.income,  active: _filter == 'income',  onTap: () => setState(() => _filter = 'income')),
                const SizedBox(width: 6),
                _Chip(label: S.expense, active: _filter == 'expense', onTap: () => setState(() => _filter = 'expense')),
              ]),
              const SizedBox(height: 4),
        const SizedBox(height: 6),
        _DateFilterBar(
          filterYear: _filterYear, filterMonth: _filterMonth,
          customStart: _customStart, customEnd: _customEnd,
          onMonthSelected: (y, m) => setState(() { _filterYear = y; _filterMonth = m; _customStart = null; _customEnd = null; }),
          onCustomRange: (s, e) => setState(() { _customStart = s; _customEnd = e; _filterYear = null; _filterMonth = null; }),
          onClear: () => setState(() { _filterYear = null; _filterMonth = null; _customStart = null; _customEnd = null; }),
        ),
            ])),
          ),

          if (items.isEmpty)
            SliverFillRemaining(child: EmptyState(
              emoji: '💰', title: S.noFinance, subtitle: S.noFinanceSub,
              action: GoldAddButton(label: S.add, onTap: () => _showAddSheet(context)),
            ))
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              sliver: SliverList(delegate: SliverChildBuilderDelegate(
                (_, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Dismissible(
                    key: ValueKey(items[i].id),
                    direction: DismissDirection.endToStart,
                    onDismissed: (_) {
                      HapticFeedback.mediumImpact();
                      ref.read(financeNotifierProvider.notifier).delete(items[i].id);
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
                    child: _FinanceCard(
                      record: items[i],
                      onEdit: () => _showEditSheet(context, items[i]),
                      onDelete: () => ref.read(financeNotifierProvider.notifier).delete(items[i].id),
                    ),
                  ),
                ),
                childCount: items.length,
              )),
            ),
        ]);
      },
    );
  }

  void _showScanOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.sc.bg2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(height: 16),
        Container(width: 36, height: 4, decoration: BoxDecoration(color: context.sc.border2, borderRadius: BorderRadius.circular(2))),
        SizedBox(height: 16),
        Text(S.get('importBill'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: context.sc.textPrimary)),
        SizedBox(height: 16),
        ListTile(
          leading: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(color: SanctumTheme.goldDim, borderRadius: BorderRadius.circular(8)),
            child: Icon(Icons.camera_alt_outlined, color: SanctumTheme.gold, size: 18),
          ),
          title: Text(S.get('takeBill'), style: TextStyle(color: context.sc.textPrimary, fontSize: 14)),
          subtitle: Text(S.get('takeBillSub'), style: TextStyle(color: context.sc.textTertiary, fontSize: 12)),
          onTap: () async {
            Navigator.pop(ctx);
            final file = await ReceiptService.instance.pickFromCamera();
            if (file != null && context.mounted) _openReceiptPreview(context, file);
          },
        ),
        ListTile(
          leading: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(color: context.sc.bg3, borderRadius: BorderRadius.circular(8)),
            child: Icon(Icons.photo_library_outlined, color: context.sc.textSecondary, size: 18),
          ),
          title: Text(S.get('fromGallery'), style: TextStyle(color: context.sc.textPrimary, fontSize: 14)),
          subtitle: Text(S.get('chooseScreenshotSub'), style: TextStyle(color: context.sc.textTertiary, fontSize: 12)),
          onTap: () async {
            Navigator.pop(ctx);
            final file = await ReceiptService.instance.pickFromGallery();
            if (file != null && context.mounted) _openReceiptPreview(context, file);
          },
        ),
        const SizedBox(height: 8),
      ])),
    );
  }

  Future<void> _openReceiptPreview(BuildContext context, File imageFile) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ReceiptPreviewScreen(imageFile: imageFile)),
    );
    if (saved == true) {
      ref.read(financeNotifierProvider.notifier).load();
    }
  }

  void _showAddSheet(BuildContext context) {
    final amountCtrl = TextEditingController();
    final descCtrl   = TextEditingController();
    String type     = 'expense';
    String category = 'cat_food';
    String currency = 'MOP';
    DateTime date   = DateTime.now();

    showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: context.sc.bg2,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          final cats = type == 'income' ? FinanceCategories.income : FinanceCategories.expense;
          return _FinanceForm(
            title: S.addRecord,
            amountCtrl: amountCtrl, descCtrl: descCtrl,
            type: type, category: category, currency: currency, date: date, cats: cats,
            onTypeChange: (t) => setSt(() { type = t; category = cats.first['key']!; }),
            onCategoryChange: (c) => setSt(() => category = c),
            onCurrencyChange: (c) => setSt(() => currency = c),
            onDateChange: (d) => setSt(() => date = d),
            onSave: () async {
              final amount = double.tryParse(amountCtrl.text);
              if (amount == null || amount <= 0) return;
              await ref.read(financeNotifierProvider.notifier).add(
                type: type, amount: amount, category: category,
                description: descCtrl.text, date: date, currency: currency,
              );
              if (ctx.mounted) Navigator.pop(ctx);
            },
          );
        },
      ),
    );
  }

  void _showEditSheet(BuildContext context, FinanceRecord record) {
    final amountCtrl = TextEditingController(text: record.amount.toString());
    final descCtrl   = TextEditingController(text: record.description);
    String type     = record.type;
    String category = record.category;
    String currency = record.currency;
    DateTime date   = record.date;

    showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: context.sc.bg2,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          final cats = type == 'income' ? FinanceCategories.income : FinanceCategories.expense;
          return _FinanceForm(
            title: S.editRecord,
            amountCtrl: amountCtrl, descCtrl: descCtrl,
            type: type, category: category, currency: currency, date: date, cats: cats,
            onTypeChange: (t) => setSt(() { type = t; category = cats.first['key']!; }),
            onCategoryChange: (c) => setSt(() => category = c),
            onCurrencyChange: (c) => setSt(() => currency = c),
            onDateChange: (d) => setSt(() => date = d),
            onSave: () async {
              final amount = double.tryParse(amountCtrl.text);
              if (amount == null || amount <= 0) return;
              await vaultService.updateFinanceRecord(record,
                type: type, amount: amount, category: category,
                description: descCtrl.text, date: date, currency: currency,
              );
              ref.read(financeNotifierProvider.notifier).load();
              if (ctx.mounted) Navigator.pop(ctx);
            },
          );
        },
      ),
    );
  }
}

// ── Chart ─────────────────────────────────────────────────
class _FinanceChart extends StatelessWidget {
  final List<FinanceRecord> records;
  const _FinanceChart({required this.records});

  @override
  Widget build(BuildContext context) {
    // Group by month
    final Map<String, double> incomeByMonth = {};
    final Map<String, double> expenseByMonth = {};
    for (final r in records) {
      final key = '${r.date.year}-${r.date.month.toString().padLeft(2, '0')}';
      if (r.isIncome) incomeByMonth[key] = (incomeByMonth[key] ?? 0) + r.amount;
      else expenseByMonth[key] = (expenseByMonth[key] ?? 0) + r.amount;
    }
    final allKeys = {...incomeByMonth.keys, ...expenseByMonth.keys}.toList()..sort();
    if (allKeys.isEmpty) return SizedBox.shrink();
    final last6 = allKeys.length > 6 ? allKeys.sublist(allKeys.length - 6) : allKeys;
    final maxVal = last6.map((k) => math.max(incomeByMonth[k] ?? 0, expenseByMonth[k] ?? 0)).reduce(math.max);

    return Container(
      height: 160,
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.sc.bg2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.sc.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(S.monthly, style: TextStyle(fontSize: 11, color: context.sc.textTertiary, letterSpacing: 0.3)),
        const SizedBox(height: 8),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: last6.map((k) {
              final inc = incomeByMonth[k] ?? 0;
              final exp = expenseByMonth[k] ?? 0;
              final incH = maxVal > 0 ? (inc / maxVal) : 0.0;
              final expH = maxVal > 0 ? (exp / maxVal) : 0.0;
              final month = k.split('-')[1];
              return Expanded(child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 3),
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.center, children: [
                    _Bar(ratio: incH.toDouble(), color: SanctumTheme.green),
                    SizedBox(width: 2),
                    _Bar(ratio: expH.toDouble(), color: SanctumTheme.red),
                  ]),
                  SizedBox(height: 4),
                  Text(month, style: TextStyle(fontSize: 9, color: context.sc.textTertiary)),
                ]),
              ));
            }).toList(),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          _Legend(color: SanctumTheme.green, label: S.income),
          const SizedBox(width: 12),
          _Legend(color: SanctumTheme.red,   label: S.expense),
        ]),
      ]),
    );
  }
}

class _Bar extends StatelessWidget {
  final double ratio;
  final Color color;
  const _Bar({required this.ratio, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    width: 10,
    height: math.max(2, ratio * 80),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(3)),
  );
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  const _Legend({required this.color, required this.label});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Container(width: 8, height: 8, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
    SizedBox(width: 4),
    Text(label, style: TextStyle(fontSize: 10, color: context.sc.textTertiary)),
  ]);
}

// ── Reusable form ─────────────────────────────────────────
class _FinanceForm extends StatefulWidget {
  final String title;
  final TextEditingController amountCtrl, descCtrl;
  final String type, category, currency;
  final DateTime date;
  final List<Map<String, String>> cats;
  final ValueChanged<String> onTypeChange, onCategoryChange;
  final ValueChanged<String>? onCurrencyChange;
  final ValueChanged<DateTime>? onDateChange;
  final VoidCallback onSave;

  const _FinanceForm({
    required this.title, required this.amountCtrl, required this.descCtrl,
    required this.type, required this.category, required this.date,
    required this.cats, required this.onTypeChange, required this.onCategoryChange,
    required this.onSave,
    this.currency = 'MOP', this.onCurrencyChange, this.onDateChange,
  });

  @override
  State<_FinanceForm> createState() => _FinanceFormState();
}

class _FinanceFormState extends State<_FinanceForm> {
  final _customEmojiCtrl = TextEditingController();
  final _customLabelCtrl = TextEditingController();

  // Common emojis for quick pick
  static const _quickEmojis = [
    '🎯','🎪','🏋️','✈️','🎵','💻','🐾','🌿',
    '🍕','☕','🎁','💡','🔧','🏠','👗','🎨',
  ];

  @override
  void initState() {
    super.initState();
    // If editing a custom category, pre-fill the fields
    if (widget.category.startsWith('custom:')) {
      final parts = widget.category.split(':');
      if (parts.length >= 2) _customEmojiCtrl.text = parts[1];
      if (parts.length >= 3) _customLabelCtrl.text = parts.sublist(2).join(':');
    }
    _customEmojiCtrl.addListener(_notifyCustom);
    _customLabelCtrl.addListener(_notifyCustom);
  }

  @override
  void dispose() {
    _customEmojiCtrl.dispose();
    _customLabelCtrl.dispose();
    super.dispose();
  }

  bool get _isOther =>
      widget.category == 'cat_other' || widget.category.startsWith('custom:');

  void _notifyCustom() {
    if (!_isOther) return;
    final e = _customEmojiCtrl.text.trim().isEmpty ? '📦' : _customEmojiCtrl.text.trim();
    final l = _customLabelCtrl.text.trim();
    if (l.isNotEmpty) {
      widget.onCategoryChange('custom:$e:$l');
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: MediaQuery.of(context).viewInsets.bottom + 24),
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: context.sc.border2, borderRadius: BorderRadius.circular(2)))),
      SizedBox(height: 16),
      Text(widget.title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: context.sc.textPrimary)),
      SizedBox(height: 16),
      // Type toggle
      Row(children: [
        _TypeBtn(label: S.expense, emoji: '↓', active: widget.type == 'expense', color: SanctumTheme.red,   onTap: () => widget.onTypeChange('expense')),
        SizedBox(width: 8),
        _TypeBtn(label: S.income,  emoji: '↑', active: widget.type == 'income',  color: SanctumTheme.green, onTap: () => widget.onTypeChange('income')),
      ]),
      SizedBox(height: 12),
      Text(S.amount, style: TextStyle(fontSize: 12, color: context.sc.textTertiary)),
      SizedBox(height: 5),
      TextFormField(
        controller: widget.amountCtrl,
        keyboardType: TextInputType.numberWithOptions(decimal: true),
        style: TextStyle(color: context.sc.textPrimary, fontSize: 22, fontWeight: FontWeight.w600),
        decoration: InputDecoration(hintText: '0.00', prefixText: '\$ '),
        autofocus: true,
      ),
      SizedBox(height: 12),
      Text(S.get('currencyLabel'), style: TextStyle(fontSize: 12, color: context.sc.textTertiary)),
      const SizedBox(height: 6),
      Row(children: ['MOP', 'HKD', 'CNY', 'USD'].map((c) {
        final active = widget.currency == c;
        return Padding(
          padding: EdgeInsets.only(right: 6),
          child: GestureDetector(
            onTap: () => widget.onCurrencyChange?.call(c),
            child: AnimatedContainer(
              duration: Duration(milliseconds: 150),
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: active ? SanctumTheme.goldDim : context.sc.bg3,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: active ? SanctumTheme.gold.withValues(alpha: 0.3) : context.sc.border),
              ),
              child: Text(c, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                color: active ? SanctumTheme.gold2 : context.sc.textSecondary)),
            ),
          ),
        );
      }).toList()),
      SizedBox(height: 12),
      Text(S.category, style: TextStyle(fontSize: 12, color: context.sc.textTertiary)),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: widget.cats.map((c) {
        final key    = c['key']!;
        final label  = S.catLabel(key);
        final active = widget.category == key || (key == 'cat_other' && widget.category.startsWith('custom:'));
        return GestureDetector(
          onTap: () {
            widget.onCategoryChange(key);
            if (key == 'cat_other') setState(() {});
          },
          child: AnimatedContainer(
            duration: Duration(milliseconds: 150),
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: active ? SanctumTheme.goldDim : context.sc.bg3,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: active ? SanctumTheme.gold.withValues(alpha: 0.3) : context.sc.border),
            ),
            child: Text(label, style: TextStyle(fontSize: 12, color: active ? SanctumTheme.gold2 : context.sc.textSecondary)),
          ),
        );
      }).toList()),

      // ── Custom label section (only when 其他 is selected) ──
      if (_isOther) ...[
        SizedBox(height: 12),
        Container(
          padding: EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: context.sc.bg3,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: SanctumTheme.gold.withValues(alpha: 0.2)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(S.get('customCategory'), style: TextStyle(fontSize: 12, color: SanctumTheme.gold, fontWeight: FontWeight.w500)),
            SizedBox(height: 10),
            Row(children: [
              // Emoji field
              Container(
                width: 50, height: 44,
                decoration: BoxDecoration(
                  color: context.sc.bg2,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: context.sc.border),
                ),
                child: Center(child: TextField(
                  controller: _customEmojiCtrl,
                  textAlign: TextAlign.center,
                  maxLength: 2,
                  style: const TextStyle(fontSize: 22),
                  decoration: const InputDecoration(
                    counterText: '',
                    border: InputBorder.none,
                    hintText: '📦',
                    hintStyle: TextStyle(fontSize: 22),
                    contentPadding: EdgeInsets.zero,
                  ),
                )),
              ),
              SizedBox(width: 8),
              // Label field
              Expanded(child: TextField(
                controller: _customLabelCtrl,
                style: TextStyle(color: context.sc.textPrimary, fontSize: 14),
                decoration: InputDecoration(
                  hintText: S.get('enterCategoryName'),
                  hintStyle: TextStyle(color: context.sc.textTertiary, fontSize: 13),
                  filled: true,
                  fillColor: context.sc.bg2,
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: context.sc.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: context.sc.border),
                  ),
                ),
              )),
            ]),
            const SizedBox(height: 10),
            // Quick emoji row
            SizedBox(
              height: 36,
              child: ListView(scrollDirection: Axis.horizontal, children: _quickEmojis.map((e) =>
                GestureDetector(
                  onTap: () { _customEmojiCtrl.text = e; _notifyCustom(); },
                  child: Container(
                    margin: EdgeInsets.only(right: 6),
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: _customEmojiCtrl.text == e ? SanctumTheme.goldDim : context.sc.bg2,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _customEmojiCtrl.text == e ? SanctumTheme.gold.withValues(alpha: 0.4) : context.sc.border),
                    ),
                    child: Center(child: Text(e, style: const TextStyle(fontSize: 18))),
                  ),
                ),
              ).toList()),
            ),
          ]),
        ),
      ],

      SizedBox(height: 12),
      SanctumField(label: S.description, hint: '', controller: widget.descCtrl),
      SizedBox(height: 12),
      Text(S.get('date'), style: TextStyle(fontSize: 12, color: context.sc.textTertiary)),
      const SizedBox(height: 6),
      GestureDetector(
        onTap: () async {
          final picked = await showDatePicker(
            context: context,
            initialDate: widget.date,
            firstDate: DateTime(2000),
            lastDate: DateTime(2099),
            builder: (c, ch) => Theme(
              data: Theme.of(c).copyWith(
                colorScheme: ColorScheme.dark(primary: SanctumTheme.gold, surface: context.sc.bg2),
              ),
              child: ch!,
            ),
          );
          if (picked != null) widget.onDateChange?.call(picked);
        },
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: context.sc.bg3,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.sc.border),
          ),
          child: Row(children: [
            Icon(Icons.calendar_today, size: 14, color: context.sc.textTertiary),
            SizedBox(width: 8),
            Text(DateFormat(S.get('dateFmtFull')).format(widget.date),
              style: TextStyle(color: context.sc.textPrimary, fontSize: 14)),
            Spacer(),
            Icon(Icons.chevron_right, size: 16, color: context.sc.textTertiary),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      SizedBox(width: double.infinity, child: ElevatedButton(onPressed: widget.onSave, child: Text(S.save))),
    ]),
  );
}

// ── Widgets ───────────────────────────────────────────────
class _SummaryCard extends StatelessWidget {
  final String label;
  final double amount;
  final Color color;
  final String prefix;
  const _SummaryCard({required this.label, required this.amount, required this.color, required this.prefix});
  @override
  Widget build(BuildContext context) => Expanded(child: Container(
    padding: EdgeInsets.fromLTRB(10, 10, 10, 12),
    decoration: BoxDecoration(color: context.sc.bg2, borderRadius: BorderRadius.circular(10), border: Border.all(color: context.sc.border, width: 0.5)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontSize: 10, color: context.sc.textTertiary)),
      const SizedBox(height: 4),
      Text('$prefix${NumberFormat('#,##0.##').format(amount)}',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: color)),
    ]),
  ));
}

class _FinanceCard extends StatefulWidget {
  final FinanceRecord record;
  final VoidCallback onEdit, onDelete;
  const _FinanceCard({required this.record, required this.onEdit, required this.onDelete});

  @override
  State<_FinanceCard> createState() => _FinanceCardState();
}

class _FinanceCardState extends State<_FinanceCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final lineItems = decodeLineItems(record.lineItemsJson);
    final hasItems = lineItems.isNotEmpty;
    final amtColor = record.isIncome ? SanctumTheme.green : SanctumTheme.red;

    return VaultCard(
      accentColor: amtColor,
      child: Column(children: [
        // Main row
        GestureDetector(
          onTap: hasItems ? () => setState(() => _expanded = !_expanded) : null,
          child: Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: record.isIncome ? SanctumTheme.greenDim : SanctumTheme.redDim,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(child: Text(record.isIncome ? '↑' : '↓',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: amtColor))),
            ),
            SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(S.catLabel(record.category),
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: context.sc.textPrimary))),
                if (hasItems) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: SanctumTheme.goldDim,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: SanctumTheme.gold.withValues(alpha: 0.25)),
                    ),
                    child: Text(S.get('itemsCount').replaceAll('{n}', '${lineItems.length}'),
                      style: TextStyle(fontSize: 9, color: SanctumTheme.gold2, fontWeight: FontWeight.w600)),
                  ),
                ],
              ]),
              if (record.description.isNotEmpty)
                Text(record.description, style: TextStyle(fontSize: 12, color: context.sc.textTertiary),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ])),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${record.isIncome ? '+' : '−'}${record.currency} ${NumberFormat('#,##0.##').format(record.amount)}',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: amtColor)),
              Text(DateFormat('MMM d').format(record.date),
                style: TextStyle(fontSize: 11, color: context.sc.textTertiary)),
            ]),
            SizedBox(width: 8),
            Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (hasItems)
                Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16, color: context.sc.textTertiary),
              GestureDetector(onTap: widget.onEdit,
                child: Icon(Icons.edit_outlined, size: 16, color: context.sc.textTertiary)),
              SizedBox(height: 6),
              GestureDetector(onTap: widget.onDelete,
                child: Icon(Icons.delete_outline, size: 16, color: context.sc.textTertiary)),
            ]),
          ]),
        ),

        // Line items expansion
        if (_expanded && hasItems) ...[
          SizedBox(height: 8),
          Divider(height: 1, color: context.sc.border),
          SizedBox(height: 6),
          ...lineItems.map((item) => Padding(
            padding: EdgeInsets.fromLTRB(46, 3, 0, 3),
            child: Row(children: [
              Container(width: 4, height: 4, margin: EdgeInsets.only(right: 8),
                decoration: BoxDecoration(color: context.sc.textTertiary.withValues(alpha: 0.5), shape: BoxShape.circle)),
              Expanded(child: Text(item.name,
                style: TextStyle(fontSize: 12, color: context.sc.textSecondary))),
              Text(NumberFormat('#,##0.##').format(item.amount),
                style: TextStyle(fontSize: 12, color: context.sc.textTertiary)),
            ]),
          )),
          const SizedBox(height: 4),
        ],
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.active, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: Duration(milliseconds: 150),
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: active ? SanctumTheme.goldDim : context.sc.bg2,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: active ? SanctumTheme.gold.withValues(alpha: 0.3) : context.sc.border),
      ),
      child: Text(label, style: TextStyle(fontSize: 12,
        color: active ? SanctumTheme.gold2 : context.sc.textTertiary,
        fontWeight: active ? FontWeight.w500 : FontWeight.w400)),
    ),
  );
}

class _TypeBtn extends StatelessWidget {
  final String label, emoji;
  final bool active;
  final Color color;
  final VoidCallback onTap;
  const _TypeBtn({required this.label, required this.emoji, required this.active, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) => Expanded(child: GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: Duration(milliseconds: 150),
      padding: EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: active ? color.withValues(alpha: 0.12) : context.sc.bg3,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: active ? color.withValues(alpha: 0.4) : context.sc.border),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text(emoji, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: active ? color : context.sc.textTertiary)),
        SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 13, color: active ? color : context.sc.textTertiary, fontWeight: active ? FontWeight.w500 : FontWeight.w400)),
      ]),
    ),
  ));
}

class _DateFilterBar extends StatelessWidget {
  final int? filterYear, filterMonth;
  final DateTime? customStart, customEnd;
  final void Function(int, int) onMonthSelected;
  final void Function(DateTime, DateTime) onCustomRange;
  final VoidCallback onClear;
  const _DateFilterBar({required this.filterYear, required this.filterMonth, required this.customStart, required this.customEnd, required this.onMonthSelected, required this.onCustomRange, required this.onClear});

  bool get _active => filterYear != null || customStart != null;
  String get _label {
    if (customStart != null && customEnd != null) return DateFormat(S.get('dateFmtMonthDay')).format(customStart!) + ' - ' + DateFormat(S.get('dateFmtMonthDay')).format(customEnd!);
    if (filterYear != null && filterMonth != null) return S.get('yearMonth').replaceAll('{y}', '$filterYear').replaceAll('{m}', '$filterMonth');
    return S.get('allTime');
  }

  void _pick(BuildContext ctx) {
    final now = DateTime.now();
    showModalBottomSheet(context: ctx, backgroundColor: ctx.sc.bg2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(height: 12),
        ListTile(leading: Icon(Icons.all_inclusive, color: SanctumTheme.gold, size: 18), title: Text(S.get('allTime'), style: TextStyle(color: ctx.sc.textPrimary, fontSize: 14)), onTap: () { Navigator.pop(ctx); onClear(); }),
        Divider(color: ctx.sc.border, height: 1),
        SizedBox(height: 200, child: ListView.builder(itemCount: 24, itemBuilder: (_, i) {
          final d = DateTime(now.year, now.month - i);
          final sel = filterYear == d.year && filterMonth == d.month;
          return ListTile(
            title: Text(S.get('yearMonth').replaceAll('{y}', '${d.year}').replaceAll('{m}', '${d.month}'), style: TextStyle(color: sel ? SanctumTheme.gold : ctx.sc.textPrimary, fontWeight: sel ? FontWeight.w600 : FontWeight.w400, fontSize: 14)),
            trailing: sel ? Icon(Icons.check, color: SanctumTheme.gold, size: 16) : null,
            onTap: () { Navigator.pop(ctx); onMonthSelected(d.year, d.month); },
          );
        })),
        Divider(color: ctx.sc.border, height: 1),
        ListTile(
          leading: Icon(Icons.date_range, color: ctx.sc.textSecondary, size: 18),
          title: Text(S.get('customDateRange'), style: TextStyle(color: ctx.sc.textPrimary, fontSize: 14)),
          onTap: () async {
            Navigator.pop(ctx);
            if (!ctx.mounted) return;
            final r = await showDateRangePicker(context: ctx, firstDate: DateTime(2020), lastDate: DateTime.now(),
              builder: (c, ch) => Theme(data: Theme.of(c).copyWith(colorScheme: ColorScheme.dark(primary: SanctumTheme.gold, surface: ctx.sc.bg2)), child: ch!));
            if (r != null) onCustomRange(r.start, r.end);
          },
        ),
        const SizedBox(height: 8),
      ])),
    );
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => _pick(context),
    child: Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: _active ? SanctumTheme.goldDim : context.sc.bg3, borderRadius: BorderRadius.circular(20), border: Border.all(color: _active ? SanctumTheme.gold.withValues(alpha: 0.4) : context.sc.border)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.calendar_today, size: 12, color: _active ? SanctumTheme.gold : context.sc.textTertiary),
        SizedBox(width: 6),
        Text(_label, style: TextStyle(fontSize: 12, color: _active ? SanctumTheme.gold2 : context.sc.textTertiary)),
        if (_active) ...[const SizedBox(width: 6), GestureDetector(onTap: onClear, child: const Icon(Icons.close, size: 12, color: SanctumTheme.gold))],
      ]),
    ),
  );
}