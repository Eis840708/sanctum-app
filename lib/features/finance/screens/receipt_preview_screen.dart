import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/models/models.dart';
import '../../../core/storage/providers.dart';
import '../../../shared/theme/app_theme.dart';
import '../services/receipt_service.dart';

class ReceiptPreviewScreen extends ConsumerStatefulWidget {
  final File imageFile;
  const ReceiptPreviewScreen({super.key, required this.imageFile});

  @override
  ConsumerState<ReceiptPreviewScreen> createState() => _ReceiptPreviewScreenState();
}

class _ReceiptPreviewScreenState extends ConsumerState<ReceiptPreviewScreen> {
  bool _loading = true;
  String? _error;

  // Editable fields
  late TextEditingController _amountCtrl;
  late TextEditingController _descCtrl;
  late String _type;
  late String _category;
  late DateTime _date;
  late String _currency;
  late List<LineItem> _lineItems;

  static const _currencies = ['MOP', 'HKD', 'CNY', 'USD'];

  @override
  void initState() {
    super.initState();
    _amountCtrl = TextEditingController();
    _descCtrl   = TextEditingController();
    _type       = 'expense';
    _category   = 'cat_food';
    _date       = DateTime.now();
    _currency   = 'MOP';
    _lineItems  = [];
    _runOCR();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _runOCR() async {
    try {
      final result = await ReceiptService.instance.parseImage(widget.imageFile);
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (result == null) {
          _error = S.get('ocrFailed');
        } else {
          _amountCtrl.text = result.amount.toStringAsFixed(2);
          _descCtrl.text   = result.description;
          _type            = result.type;
          _category        = result.category;
          _date            = result.date;
          _currency        = result.currency;
          _lineItems       = List.from(result.lineItems);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '${S.get('ocrError')}：$e';
      });
    }
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amountCtrl.text);
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.get('enterValidAmount'))),
      );
      return;
    }

    await ref.read(financeNotifierProvider.notifier).addFull(
      id: const Uuid().v4(),
      type: _type,
      amount: amount,
      category: _category,
      description: _descCtrl.text,
      date: _date,
      currency: _currency,
      lineItemsJson: encodeLineItems(_lineItems),
    );

    if (mounted) {
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(true); // true = saved
    }
  }

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return Scaffold(
      backgroundColor: sc.bg,
      appBar: AppBar(
        backgroundColor: sc.bg,
        elevation: 0,
        title: Text(S.get('scanBill'), style: TextStyle(color: sc.textPrimary, fontSize: 17, fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: Icon(Icons.close, color: sc.textSecondary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (!_loading)
            TextButton(
              onPressed: _save,
              child: Text(S.save, style: const TextStyle(color: SanctumTheme.gold, fontWeight: FontWeight.w600, fontSize: 15)),
            ),
        ],
      ),
      body: _loading
          ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const CircularProgressIndicator(color: SanctumTheme.gold),
              const SizedBox(height: 16),
              Text(S.get('recognizing'), style: TextStyle(color: sc.textTertiary, fontSize: 14)),
            ]))
          : _buildForm(),
    );
  }

  Widget _buildForm() {
    final sc = context.sc;
    return SingleChildScrollView(
      padding: EdgeInsets.only(left: 16, right: 16, top: 8, bottom: MediaQuery.of(context).viewInsets.bottom + 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // Thumbnail
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.file(widget.imageFile, height: 120, width: double.infinity, fit: BoxFit.cover),
        ),
        const SizedBox(height: 4),

        // Error notice
        if (_error != null)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: SanctumTheme.red.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              const Icon(Icons.warning_amber, color: SanctumTheme.red, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(_error!, style: const TextStyle(color: SanctumTheme.red, fontSize: 13))),
            ]),
          ),

        const SizedBox(height: 16),

        // Type toggle
        Row(children: [
          _TypeBtn(label: S.expense, active: _type == 'expense', color: SanctumTheme.red,   onTap: () => setState(() => _type = 'expense')),
          const SizedBox(width: 8),
          _TypeBtn(label: S.income, active: _type == 'income',  color: SanctumTheme.green, onTap: () => setState(() => _type = 'income')),
        ]),
        const SizedBox(height: 14),

        // Amount + Currency row
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(S.amount, style: TextStyle(fontSize: 12, color: sc.textTertiary)),
            const SizedBox(height: 6),
            TextFormField(
              controller: _amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: TextStyle(color: sc.textPrimary, fontSize: 22, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(hintText: '0.00', contentPadding: EdgeInsets.symmetric(vertical: 8)),
            ),
          ])),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(S.get('currencyLabel'), style: TextStyle(fontSize: 12, color: sc.textTertiary)),
            const SizedBox(height: 6),
            DropdownButton<String>(
              value: _currencies.contains(_currency) ? _currency : 'MOP',
              dropdownColor: sc.bg2,
              style: TextStyle(color: sc.textPrimary, fontSize: 14),
              underline: const SizedBox.shrink(),
              items: _currencies.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
              onChanged: (v) => setState(() => _currency = v ?? 'MOP'),
            ),
          ]),
        ]),
        const SizedBox(height: 14),

        // Description
        Text(S.description, style: TextStyle(fontSize: 12, color: sc.textTertiary)),
        const SizedBox(height: 6),
        TextField(
          controller: _descCtrl,
          style: TextStyle(color: sc.textPrimary, fontSize: 15),
          decoration: InputDecoration(
            hintText: S.get('merchantNote'),
            hintStyle: TextStyle(color: sc.textTertiary, fontSize: 14),
            filled: true, fillColor: sc.bg2,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
          ),
        ),
        const SizedBox(height: 14),

        // Date
        Text(S.date, style: TextStyle(fontSize: 12, color: sc.textTertiary)),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: _date,
              firstDate: DateTime(2020),
              lastDate: DateTime.now().add(const Duration(days: 1)),
              builder: (c, ch) => Theme(
                data: Theme.of(c).copyWith(colorScheme: ColorScheme.dark(primary: SanctumTheme.gold, surface: sc.bg2)),
                child: ch!,
              ),
            );
            if (picked != null) setState(() => _date = picked);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: sc.bg2, borderRadius: BorderRadius.circular(8),
              border: Border.all(color: sc.border),
            ),
            child: Row(children: [
              Icon(Icons.calendar_today, size: 14, color: sc.textTertiary),
              const SizedBox(width: 8),
              Text(DateFormat(S.get('dateFmtFull')).format(_date), style: TextStyle(color: sc.textPrimary, fontSize: 14)),
            ]),
          ),
        ),
        const SizedBox(height: 14),

        // Category
        Text(S.category, style: TextStyle(fontSize: 12, color: sc.textTertiary)),
        const SizedBox(height: 8),
        _buildCategoryChips(),
        const SizedBox(height: 20),

        // Line items section
        _buildLineItemsSection(),
        const SizedBox(height: 16),

        // Save button
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _save,
            style: ElevatedButton.styleFrom(
              backgroundColor: SanctumTheme.gold,
              foregroundColor: sc.bg,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(S.get('saveRecord'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          ),
        ),
      ]),
    );
  }

  Widget _buildCategoryChips() {
    final sc = context.sc;
    final cats = _type == 'income' ? FinanceCategories.income : FinanceCategories.expense;
    return Wrap(spacing: 6, runSpacing: 6, children: cats.map((c) {
      final key = c['key']!;
      final emoji = c['emoji']!;
      final active = _category == key;
      return GestureDetector(
        onTap: () => setState(() => _category = key),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active ? SanctumTheme.goldDim : sc.bg3,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: active ? SanctumTheme.gold.withValues(alpha: 0.3) : sc.border),
          ),
          child: Text('$emoji ${_catLabel(key)}', style: TextStyle(fontSize: 12,
            color: active ? SanctumTheme.gold2 : sc.textSecondary)),
        ),
      );
    }).toList());
  }

  String _catLabel(String key) {
    // Delegate to the i18n category labels (all languages, emoji-prefixed),
    // consistent with the finance screen.
    return S.catLabel(key);
  }

  Widget _buildLineItemsSection() {
    final sc = context.sc;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(S.get('lineItem'), style: TextStyle(fontSize: 12, color: sc.textTertiary)),
        const Spacer(),
        GestureDetector(
          onTap: _addLineItem,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: SanctumTheme.goldDim, borderRadius: BorderRadius.circular(6),
              border: Border.all(color: SanctumTheme.gold.withValues(alpha: 0.3)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.add, size: 13, color: SanctumTheme.gold),
              const SizedBox(width: 3),
              Text(S.get('addLineItem'), style: const TextStyle(fontSize: 12, color: SanctumTheme.gold2)),
            ]),
          ),
        ),
      ]),

      if (_lineItems.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(S.get('lineItemsOptional'), style: TextStyle(fontSize: 12, color: sc.textTertiary.withValues(alpha: 0.6))),
        )
      else ...[
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(color: sc.bg2, borderRadius: BorderRadius.circular(10), border: Border.all(color: sc.border)),
          child: Column(children: [
            ..._lineItems.asMap().entries.map((entry) {
              final i = entry.key;
              final item = entry.value;
              return Column(children: [
                if (i > 0) Divider(height: 1, color: sc.border),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(item.name, style: TextStyle(color: sc.textPrimary, fontSize: 13, fontWeight: FontWeight.w500)),
                    ])),
                    Text(NumberFormat('#,##0.##').format(item.amount),
                      style: TextStyle(color: sc.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => _editLineItem(i),
                      child: Icon(Icons.edit_outlined, size: 14, color: sc.textTertiary),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => setState(() => _lineItems.removeAt(i)),
                      child: Icon(Icons.close, size: 14, color: sc.textTertiary),
                    ),
                  ]),
                ),
              ]);
            }),
            // Total row
            Divider(height: 1, color: sc.border),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                Text(S.get('total'), style: TextStyle(color: sc.textTertiary, fontSize: 12)),
                const Spacer(),
                Text(
                  NumberFormat('#,##0.##').format(_lineItems.fold(0.0, (s, i) => s + i.amount)),
                  style: const TextStyle(color: SanctumTheme.gold2, fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ]),
            ),
          ]),
        ),
      ],
    ]);
  }

  void _addLineItem() => _showLineItemDialog(null, null);
  void _editLineItem(int index) => _showLineItemDialog(index, _lineItems[index]);

  void _showLineItemDialog(int? index, LineItem? existing) {
    final sc = context.sc;
    final nameCtrl   = TextEditingController(text: existing?.name ?? '');
    final amountCtrl = TextEditingController(text: existing != null ? existing.amount.toStringAsFixed(2) : '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: sc.bg2,
        title: Text(index == null ? S.get('addLineItem') : S.get('editLineItem'),
          style: TextStyle(color: sc.textPrimary, fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: nameCtrl,
            autofocus: true,
            style: TextStyle(color: sc.textPrimary, fontSize: 14),
            decoration: _inputDecoration(S.get('itemNameHint'), sc),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: TextStyle(color: sc.textPrimary, fontSize: 14),
            decoration: _inputDecoration(S.amount, sc),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.cancel, style: TextStyle(color: sc.textTertiary)),
          ),
          TextButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              final amount = double.tryParse(amountCtrl.text);
              if (name.isEmpty || amount == null || amount <= 0) return;
              setState(() {
                if (index == null) {
                  _lineItems.add(LineItem(name: name, amount: amount));
                } else {
                  _lineItems[index] = LineItem(name: name, amount: amount);
                }
              });
              Navigator.pop(ctx);
            },
            child: Text(S.confirm, style: const TextStyle(color: SanctumTheme.gold, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String hint, SanctumColors sc) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: sc.textTertiary, fontSize: 13),
    filled: true, fillColor: sc.bg3,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: sc.border)),
  );
}

// ── Type button ───────────────────────────────────────────────
class _TypeBtn extends StatelessWidget {
  final String label;
  final bool active;
  final Color color;
  final VoidCallback onTap;
  const _TypeBtn({required this.label, required this.active, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return Expanded(child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.12) : sc.bg3,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: active ? color.withValues(alpha: 0.4) : sc.border),
        ),
        child: Center(child: Text(label,
          style: TextStyle(fontSize: 13, color: active ? color : sc.textTertiary,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400))),
      ),
    ));
  }
}
