import 'dart:io';
import 'dart:convert';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

// ── Data models ──────────────────────────────────────────────

class LineItem {
  final String name;
  final double amount;
  LineItem({required this.name, required this.amount});

  Map<String, dynamic> toJson() => {'n': name, 'a': amount};
  factory LineItem.fromJson(Map<String, dynamic> j) =>
      LineItem(name: j['n'] as String, amount: (j['a'] as num).toDouble());
}

class ParsedReceipt {
  final double amount;
  final String type;        // 'income' | 'expense'
  final String description; // merchant / note
  final String category;
  final DateTime date;
  final String currency;
  final List<LineItem> lineItems;
  final String rawText;

  ParsedReceipt({
    required this.amount,
    required this.type,
    required this.description,
    required this.category,
    required this.date,
    this.currency = 'MOP',
    this.lineItems = const [],
    this.rawText = '',
  });
}

// ── Helper: encode/decode line items JSON ────────────────────

String? encodeLineItems(List<LineItem> items) {
  if (items.isEmpty) return null;
  return jsonEncode(items.map((e) => e.toJson()).toList());
}

List<LineItem> decodeLineItems(String? json) {
  if (json == null || json.isEmpty) return [];
  try {
    final list = jsonDecode(json) as List;
    return list.map((e) => LineItem.fromJson(e as Map<String, dynamic>)).toList();
  } catch (_) {
    return [];
  }
}

// ── Universal currency table ──────────────────────────────────
// Maps symbol / code → ISO code
const _currencySymbols = {
  // Symbols
  r'HK\$': 'HKD', r'MO\$': 'MOP', r'US\$': 'USD',
  r'\$': 'MOP',   // fallback dollar — Macau/HK context: bare $ is MOP
  '€': 'EUR',     '£': 'GBP',    '¥': 'JPY',
  '₩': 'KRW',    '₹': 'INR',   '฿': 'THB',
  'RM': 'MYR',   'S\$': 'SGD',  'NT\$': 'TWD',
  // ISO codes (longer first to avoid partial matches)
  'MOP': 'MOP', 'HKD': 'HKD', 'CNY': 'CNY', 'USD': 'USD',
  'EUR': 'EUR', 'GBP': 'GBP', 'JPY': 'JPY', 'KRW': 'KRW',
  'AUD': 'AUD', 'CAD': 'CAD', 'SGD': 'SGD', 'TWD': 'TWD',
  'THB': 'THB', 'MYR': 'MYR', 'INR': 'INR', 'PHP': 'PHP',
  'VND': 'VND', 'IDR': 'IDR',
};

// ── Income keywords — multilingual ───────────────────────────
final _incomePattern = RegExp(
  r'\b(?:'
  // English
  r'received?|deposit(?:ed)?|credit(?:ed)?|refund(?:ed)?|transfer\s*in|'
  r'incoming|added\s+to|top[\s\-]?up|'
  // Chinese (both variants)
  r'存入|轉入|收入|入賬|入帳|到帳|退款|工資|薪金|薪水|發放|'
  // Japanese
  r'入金|振込|受取|'
  // Korean
  r'입금|수신|'
  // French
  r'reçu|crédit(?:é)?|virement\s+reçu|'
  // German
  r'gutschrift|eingegangen|überwiesen\s+von|'
  // Spanish / Portuguese
  r'recib(?:ido|iste)|depósito|transferencia\s+recibida|crédito|'
  // Generic sign indicator
  r'(?<!\-)(?<!\d)\+\s*\d'
  r')\b',
  caseSensitive: false,
);

// ── Expense keywords — multilingual ──────────────────────────
final _expensePattern = RegExp(
  r'\b(?:'
  // English
  r'paid?|payment|purchase(?:d)?|charged?|debit(?:ed)?|spent|'
  r'withdrawal|withdraw|deducted?|bill(?:ed)?|transaction|'
  // Chinese
  r'消費|扣賬|扣款|付款|支出|購物|簽賬|刷卡|轉出|取款|提款|費用|帳單|'
  // Japanese
  r'出金|引落|支払|決済|ご利用|'
  // Korean
  r'출금|결제|사용|지불|'
  // French
  r'd[ée]bit(?:é)?|paiement|achat|pr[eè]l[eè]vement|'
  // German
  r'lastschrift|abbuchung|zahlung|ausgabe|'
  // Spanish / Portuguese
  r'pago|compra|cargo|d[eé]bito|cobro|'
  // Generic sign indicator
  r'(?<=\d)\s*(?:DR|D/R)'
  r')\b',
  caseSensitive: false,
);

// ── ReceiptService ────────────────────────────────────────────

class ReceiptService {
  static final ReceiptService _instance = ReceiptService._();
  static ReceiptService get instance => _instance;
  ReceiptService._();

  final _picker = ImagePicker();

  // ── Public: pick image from camera ──────────────────────────
  Future<File?> pickFromCamera() async {
    try {
      final xfile = await _picker.pickImage(source: ImageSource.camera, imageQuality: 85);
      return xfile == null ? null : File(xfile.path);
    } catch (_) {
      return null;
    }
  }

  // ── Public: pick image from gallery ─────────────────────────
  Future<File?> pickFromGallery() async {
    try {
      final xfile = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
      return xfile == null ? null : File(xfile.path);
    } catch (_) {
      return null;
    }
  }

  // ── Public: parse image → ParsedReceipt ─────────────────────
  // Uses Latin script (bundled, no download needed).
  // Latin OCR still captures Arabic numerals, currency symbols, and dates
  // from any language receipt — Chinese merchant names are lost but amounts are preserved.
  Future<ParsedReceipt?> parseImage(File imageFile) async {
    final inputImage = InputImage.fromFile(imageFile);
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(inputImage);
      final text = result.text;
      if (text.trim().isEmpty) return null;
      return _parseText(text);
    } finally {
      recognizer.close();
    }
  }

  // ── Public: parse raw text ───────────────────────────────────
  ParsedReceipt? parseRawText(String text) {
    if (text.trim().isEmpty) return null;
    return _parseText(text);
  }

  // ── Internal: choose strategy ─────────────────────────────────
  ParsedReceipt? _parseText(String text) {
    // Short texts (<= ~5 lines) are likely SMS/notifications → universal SMS
    // Longer texts are likely physical receipts → receipt OCR
    final lineCount = text.split('\n').where((l) => l.trim().isNotEmpty).length;
    if (lineCount <= 8) {
      final sms = _parseUniversalSMS(text);
      if (sms != null) return sms;
    }
    return _parseReceipt(text);
  }

  // ════════════════════════════════════════════════════════════
  // UNIVERSAL SMS / NOTIFICATION PARSER
  // Strategy: extract amount + currency → detect income/expense
  //           → extract date → extract merchant description
  // Works for any bank, any language.
  // ════════════════════════════════════════════════════════════
  ParsedReceipt? _parseUniversalSMS(String text) {
    // ── Step 1: Extract all (currency, amount, sign?) candidates ──
    final candidates = _extractAmountCandidates(text);
    if (candidates.isEmpty) return null;

    // ── Step 2: Pick the most prominent amount ────────────────
    // Prefer the largest amount (usually the transaction amount,
    // not a card-ending number or account balance fragment).
    // Exclude suspiciously small numbers (≤ 0) or huge ones
    // that look like account numbers.
    final filtered = candidates.where((c) => c.amount > 0 && c.amount < 1e9).toList();
    if (filtered.isEmpty) return null;

    // Sort: prefer explicit currency prefix/suffix over bare numbers
    filtered.sort((a, b) {
      final aHasCur = a.currency != null ? 1 : 0;
      final bHasCur = b.currency != null ? 1 : 0;
      if (aHasCur != bHasCur) return bHasCur - aHasCur;
      return b.amount.compareTo(a.amount);
    });
    final best = filtered.first;

    // ── Step 3: Determine income / expense ───────────────────
    // First check for explicit sign in the matched text
    String type;
    if (best.explicitSign == '+') {
      type = 'income';
    } else if (best.explicitSign == '-') {
      type = 'expense';
    } else {
      // Keyword scan on full text
      final hasIncome  = _incomePattern.hasMatch(text);
      final hasExpense = _expensePattern.hasMatch(text);
      if (hasIncome && !hasExpense) {
        type = 'income';
      } else {
        type = 'expense'; // default — most notifications are expenses
      }
    }

    // ── Step 4: Determine currency ────────────────────────────
    final currency = best.currency ?? _detectCurrency(text) ?? 'MOP';

    // ── Step 5: Extract date ──────────────────────────────────
    final date = _extractDate(text) ?? DateTime.now();

    // ── Step 6: Extract merchant / description ────────────────
    final description = _extractDescription(text, best.matchedStr);

    return ParsedReceipt(
      amount: best.amount,
      type: type,
      description: description,
      category: _guessCategory(description, type),
      date: date,
      currency: currency,
      rawText: text,
    );
  }

  // ── Amount candidate model ────────────────────────────────────
  _AmountCandidate? _tryParseCandidate(String raw, String? currency, String? sign, String fullMatch) {
    final clean = raw.replaceAll(RegExp(r'[,，]'), '');
    final amount = double.tryParse(clean);
    if (amount == null || amount <= 0) return null;
    return _AmountCandidate(amount: amount, currency: currency, explicitSign: sign, matchedStr: fullMatch);
  }

  // ── Extract all amount candidates ────────────────────────────
  // Tries currency-prefixed, currency-suffixed, and bare decimal patterns
  List<_AmountCandidate> _extractAmountCandidates(String text) {
    final results = <_AmountCandidate>[];

    // Build one big alternation of all currency symbols/codes (longest first)
    final symbols = _currencySymbols.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final symGroup = symbols.join('|');

    // Pattern: [sign] CURRENCY AMOUNT  (e.g. -MOP 123.45 / HKD123.45 / $50)
    final prefixRe = RegExp(
      r'([+\-−－]?)\s*(' + symGroup + r')\s*([+\-−－]?)\s*([\d,，]+(?:[.,]\d+)?)',
      caseSensitive: false,
    );
    for (final m in prefixRe.allMatches(text)) {
      final sign = (m.group(1)! + m.group(3)!).replaceAll('−', '-').replaceAll('－', '-');
      final rawCur = m.group(2)!;
      final rawAmt = m.group(4)!;
      final currency = _currencySymbols[rawCur] ??
          _currencySymbols[rawCur.toUpperCase()] ?? rawCur.toUpperCase();
      final c = _tryParseCandidate(rawAmt, currency, sign.isNotEmpty ? sign : null, m.group(0)!);
      if (c != null) results.add(c);
    }

    // Pattern: AMOUNT CURRENCY  (e.g. 123.45 HKD / 100MOP)
    final suffixRe = RegExp(
      r'([\d,，]+(?:[.,]\d+)?)\s*(' + symGroup + r')',
      caseSensitive: false,
    );
    for (final m in suffixRe.allMatches(text)) {
      final rawAmt = m.group(1)!;
      final rawCur = m.group(2)!;
      final currency = _currencySymbols[rawCur] ??
          _currencySymbols[rawCur.toUpperCase()] ?? rawCur.toUpperCase();
      final c = _tryParseCandidate(rawAmt, currency, null, m.group(0)!);
      if (c != null) results.add(c);
    }

    // Pattern: bare decimal (e.g. 123.45) — lower priority
    final bareRe = RegExp(r'\b(\d{1,6}[.,]\d{2})\b');
    for (final m in bareRe.allMatches(text)) {
      final rawAmt = m.group(1)!;
      final c = _tryParseCandidate(rawAmt, null, null, m.group(0)!);
      if (c != null) results.add(c);
    }

    return results;
  }

  // ── Detect currency from text if not found near amount ───────
  String? _detectCurrency(String text) {
    final symbols = _currencySymbols.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final sym in symbols) {
      if (RegExp(sym, caseSensitive: false).hasMatch(text)) {
        return _currencySymbols[sym];
      }
    }
    return null;
  }

  // ── Universal date extractor ──────────────────────────────────
  // Handles: 2024-01-15, 01/15/2024, 15 Jan 2024, 2024年1月15日,
  //          Jan 15 2024, 15.01.2024, 2024/1/15, etc.
  DateTime? _extractDate(String text) {
    // Normalize Chinese date chars
    final norm = text
        .replaceAll('年', '-').replaceAll('月', '-').replaceAll('日', ' ');

    // yyyy-MM-dd or yyyy/MM/dd or yyyy.MM.dd
    final iso = RegExp(r'(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})');
    for (final m in iso.allMatches(norm)) {
      final d = _safeDate(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
      if (d != null) return d;
    }

    // dd/MM/yyyy or MM/dd/yyyy or dd.MM.yyyy
    final dmy = RegExp(r'(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})');
    for (final m in dmy.allMatches(norm)) {
      final a = int.parse(m.group(1)!);
      final b = int.parse(m.group(2)!);
      final y = int.parse(m.group(3)!);
      // Heuristic: if first part > 12, it must be day
      if (a > 12) return _safeDate(y, b, a);
      if (b > 12) return _safeDate(y, a, b);
      return _safeDate(y, a, b); // default: MM/dd/yyyy (common in US/HK notifications)
    }

    // "15 Jan 2024" or "Jan 15, 2024" or "15 January 2024"
    // Note: no duplicate keys — 'mai'/'august' only listed once each
    const months = {
      // English short
      'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
      'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
      // English long
      'january': 1, 'february': 2, 'march': 3, 'april': 4,
      'june': 6, 'july': 7, 'august': 8, 'september': 9, 'october': 10,
      'november': 11, 'december': 12,
      // French (skip 'mai'→5 already covered, 'août'→8 not in EN, 'septembre'→9 differs)
      'janvier': 1, 'février': 2, 'mars': 3, 'avril': 4, 'mai': 5,
      'juin': 6, 'juillet': 7, 'août': 8, 'septembre': 9,
      'octobre': 10, 'novembre': 11, 'décembre': 12,
      // German (skip 'mai'→dup of French, 'august'→dup of English)
      'januar': 1, 'februar': 2, 'märz': 3, 'juni': 6,
      'juli': 7, 'oktober': 10, 'dezember': 12,
      // Spanish
      'enero': 1, 'febrero': 2, 'marzo': 3, 'abril': 4, 'mayo': 5,
      'junio': 6, 'julio': 7, 'agosto': 8, 'septiembre': 9,
      'octubre': 10, 'noviembre': 11, 'diciembre': 12,
    };

    final wordDate = RegExp(
      r'(\d{1,2})\s+([A-Za-zÀ-ÿ]+)\s+(\d{4})|([A-Za-zÀ-ÿ]+)\s+(\d{1,2}),?\s+(\d{4})',
    );
    for (final m in wordDate.allMatches(text)) {
      if (m.group(1) != null) {
        // dd MonthName yyyy
        final month = months[m.group(2)!.toLowerCase()];
        if (month != null) {
          final d = _safeDate(int.parse(m.group(3)!), month, int.parse(m.group(1)!));
          if (d != null) return d;
        }
      } else {
        // MonthName dd yyyy
        final month = months[m.group(4)!.toLowerCase()];
        if (month != null) {
          final d = _safeDate(int.parse(m.group(6)!), month, int.parse(m.group(5)!));
          if (d != null) return d;
        }
      }
    }

    return null;
  }

  DateTime? _safeDate(int y, int m, int d) {
    try {
      if (y < 2000 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31) return null;
      return DateTime(y, m, d);
    } catch (_) {
      return null;
    }
  }

  // ── Merchant / description extractor ─────────────────────────
  // Strategy: remove known noise words, find the most meaningful
  // contiguous text segment in the message.
  String _extractDescription(String text, String matchedAmountStr) {
    // Remove the matched amount string to reduce noise
    var cleaned = text.replaceFirst(matchedAmountStr, ' ');

    // Remove date-like patterns
    cleaned = cleaned.replaceAll(RegExp(r'\d{4}[-/\.]\d{1,2}[-/\.]\d{1,2}[\s\d:]*'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\d{1,2}[-/\.]\d{1,2}[-/\.]\d{4}'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\d{1,2}:\d{2}(?::\d{2})?'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'2024年\d+月\d+日|2025年\d+月\d+日|2026年\d+月\d+日'), ' ');

    // Remove card/account number fragments (4+ consecutive digits)
    cleaned = cleaned.replaceAll(RegExp(r'\b\d{4,}\b'), ' ');

    // Remove common noise labels across languages
    final noisePattern = RegExp(
      r'\b(?:time|date|amount|balance|ref(?:erence)?|no\.|#|'
      r'時間|日期|金額|餘額|結餘|類型|帳戶|卡號|交易|參考|'
      r'datum|betrag|référence|montant|fecha|importe|'
      r'card|ending|xxxx|account|acct|authorized)\b',
      caseSensitive: false,
    );
    cleaned = cleaned.replaceAll(noisePattern, ' ');

    // Remove punctuation runs and collapse whitespace
    cleaned = cleaned.replaceAll(RegExp(r'[：:；;，,。.!！?？\|\-_=*]{2,}'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();

    // Split into segments, score by: CJK/alpha content, length, position
    final segments = cleaned.split(RegExp(r'[\n\r\t|]'))
      .map((s) => s.trim())
      .where((s) => s.length >= 2)
      .toList();

    if (segments.isEmpty) return '';

    // Score each segment
    String best = '';
    double bestScore = -1;
    for (final seg in segments) {
      // Count meaningful characters (letters, CJK)
      final meaningful = seg.replaceAll(RegExp(r'[\s\d\W]'), '').length;
      final total = seg.length;
      if (total == 0) continue;
      final score = meaningful / total * total.clamp(0, 20).toDouble();
      if (score > bestScore) {
        bestScore = score;
        best = seg;
      }
    }

    // Trim leading/trailing punctuation from winner
    best = best.replaceAll(RegExp(r'^[\W\s]+|[\W\s]+$'), '').trim();
    return best;
  }

  // ════════════════════════════════════════════════════════════
  // PHYSICAL RECEIPT OCR PARSER
  // ════════════════════════════════════════════════════════════
  ParsedReceipt? _parseReceipt(String text) {
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

    // Total amount — look for explicit total line first
    double? totalAmount;
    final totalPatterns = [
      RegExp(r'(?:合計|總計|總額|小計|應付|total\s*:?|amount\s+due|subtotal|grand\s+total)\D{0,8}([\d,]+\.?\d*)', caseSensitive: false),
    ];
    for (final line in lines.reversed) {
      for (final pat in totalPatterns) {
        final m = pat.firstMatch(line);
        if (m != null) {
          final v = double.tryParse(m.group(1)!.replaceAll(',', ''));
          if (v != null && v > 0) { totalAmount = v; break; }
        }
      }
      if (totalAmount != null) break;
    }

    // Fallback: largest amount-like number in text
    if (totalAmount == null) {
      final candidates = _extractAmountCandidates(text);
      final valid = candidates.where((c) => c.amount > 0 && c.amount < 1e8).toList()
        ..sort((a, b) => b.amount.compareTo(a.amount));
      if (valid.isNotEmpty) totalAmount = valid.first.amount;
    }

    if (totalAmount == null || totalAmount <= 0) return null;

    // Date
    final date = _extractDate(text) ?? DateTime.now();

    // Merchant: first meaningful non-numeric line
    String merchant = '';
    for (final line in lines) {
      if (line.length >= 2 && !RegExp(r'^[\d\s\-\/:.,*#（）()]+$').hasMatch(line)) {
        merchant = line;
        break;
      }
    }

    // Currency
    final currency = _detectCurrency(text) ?? 'MOP';

    // Line items
    final lineItems = _extractLineItems(lines);
    if (lineItems.isNotEmpty && totalAmount == lineItems.fold(0.0, (s, i) => s + i.amount)) {
      // total matches sum — good
    }

    return ParsedReceipt(
      amount: totalAmount,
      type: 'expense',
      description: merchant,
      category: _guessCategory(merchant, 'expense'),
      date: date,
      currency: currency,
      lineItems: lineItems,
      rawText: text,
    );
  }

  // ── Line item extraction ──────────────────────────────────────
  List<LineItem> _extractLineItems(List<String> lines) {
    final items = <LineItem>[];
    final lineItemPat = RegExp(r'^(.+?)\s+([\d,]+\.\d{2})\s*$');
    final skipPat = RegExp(
      r'合計|總計|小計|找贖|找數|優惠|折扣|tax|vat|service|total|subtotal|discount|change|cash|paid',
      caseSensitive: false,
    );
    for (final line in lines) {
      if (skipPat.hasMatch(line.toLowerCase())) continue;
      final m = lineItemPat.firstMatch(line);
      if (m != null) {
        final name = m.group(1)!.trim();
        final amount = double.tryParse(m.group(2)!.replaceAll(',', ''));
        if (amount != null && amount > 0 && name.length >= 2) {
          items.add(LineItem(name: name, amount: amount));
        }
      }
    }
    return items;
  }

  // ── Category guesser (multilingual) ──────────────────────────
  String _guessCategory(String text, String type) {
    if (type == 'income') {
      if (RegExp(r'工資|薪|salary|wage|payroll|lohn|salaire', caseSensitive: false).hasMatch(text)) return 'cat_work';
      if (RegExp(r'freelance|自由|接案|honoraire', caseSensitive: false).hasMatch(text)) return 'cat_freelance';
      if (RegExp(r'dividend|interest|股息|利息|投資|invest', caseSensitive: false).hasMatch(text)) return 'cat_investment';
      return 'cat_other';
    }
    final t = text.toLowerCase();
    if (RegExp(r'超市|market|grocery|便利|7-?11|ok便|circle|carrefour|fairprice|don\s*don\s*donki', caseSensitive: false).hasMatch(t)) return 'cat_food';
    if (RegExp(r'餐|食|cafe|coffee|茶|飯|麵|pizza|kfc|mcd|麥當|starbucks|restaurant|eatery|bistro|brasserie', caseSensitive: false).hasMatch(t)) return 'cat_food';
    if (RegExp(r'巴士|bus|taxi|的士|uber|grab|lyft|地鐵|mtr|metro|ferry|渡|park|parking|toll|petrol|fuel|gas\s*station|加油|油站', caseSensitive: false).hasMatch(t)) return 'cat_transport';
    if (RegExp(r'藥|pharmacy|clinic|醫|hospital|health|apotheke|pharmacie|farmacia', caseSensitive: false).hasMatch(t)) return 'cat_health';
    if (RegExp(r'書|book|school|tutor|course|education|學|学|bildung|école|universidad', caseSensitive: false).hasMatch(t)) return 'cat_education';
    if (RegExp(r'戲院|cinema|movie|game|遊戲|ktv|bowling|netflix|spotify|apple\s*tv|disney|entertainment|divertissement', caseSensitive: false).hasMatch(t)) return 'cat_entertainment';
    if (RegExp(r'購物|shop|mall|百貨|fashion|衣|鞋|nike|adidas|zara|h&m|uniqlo|ikea', caseSensitive: false).hasMatch(t)) return 'cat_shopping';
    if (RegExp(r'水電|electricity|water|gas bill|internet|wifi|phone\s*bill|租|rent|mortgage|管理費|property', caseSensitive: false).hasMatch(t)) return 'cat_housing';
    return 'cat_other';
  }
}

// ── Internal: amount candidate ────────────────────────────────
class _AmountCandidate {
  final double amount;
  final String? currency;
  final String? explicitSign;
  final String matchedStr;
  _AmountCandidate({
    required this.amount,
    this.currency,
    this.explicitSign,
    required this.matchedStr,
  });
}
