import 'package:hive/hive.dart';

part 'models.g.dart';

// ── Password Entry ──────────────────────────────────────────
@HiveType(typeId: 0)
class PasswordEntry extends HiveObject {
  @HiveField(0) String id;
  @HiveField(1) String site;
  @HiveField(2) String username;
  @HiveField(3) String encryptedPassword;
  @HiveField(4) String notes;
  @HiveField(5) DateTime createdAt;
  @HiveField(6) DateTime updatedAt;
  @HiveField(7) String? iconEmoji;

  PasswordEntry({
    required this.id, required this.site, required this.username,
    required this.encryptedPassword, this.notes = '',
    required this.createdAt, required this.updatedAt, this.iconEmoji,
  });
}

// ── Diary Entry ─────────────────────────────────────────────
@HiveType(typeId: 1)
class DiaryEntry extends HiveObject {
  @HiveField(0) String id;
  @HiveField(1) String title;
  @HiveField(2) String encryptedContent;
  @HiveField(3) String mood;
  @HiveField(4) DateTime createdAt;
  @HiveField(5) DateTime updatedAt;
  @HiveField(6) List<String> tags;

  DiaryEntry({
    required this.id, required this.title, required this.encryptedContent,
    required this.mood, required this.createdAt, required this.updatedAt,
    this.tags = const [],
  });
}

// ── Finance Record ──────────────────────────────────────────
@HiveType(typeId: 2)
class FinanceRecord extends HiveObject {
  @HiveField(0) String id;
  @HiveField(1) String type;
  @HiveField(2) double amount;
  @HiveField(3) String category;
  @HiveField(4) String description;
  @HiveField(5) DateTime date;
  @HiveField(6) DateTime createdAt;
  @HiveField(7) String currency;
  @HiveField(8) String? lineItemsJson; // JSON: [{"n":"名稱","a":12.5}, ...]

  FinanceRecord({
    required this.id, required this.type, required this.amount,
    required this.category, required this.description,
    required this.date, required this.createdAt,
    this.currency = 'HKD', this.lineItemsJson,
  });

  bool get isIncome => type == 'income';
}

// ── Vault Meta ──────────────────────────────────────────────
@HiveType(typeId: 3)
class VaultMeta extends HiveObject {
  @HiveField(0) String salt;
  @HiveField(1) String verifyHash;
  @HiveField(2) DateTime createdAt;
  @HiveField(3) DateTime lastUnlocked;
  @HiveField(4) int unlockCount;
  @HiveField(5) String version;

  VaultMeta({
    required this.salt, required this.verifyHash,
    required this.createdAt, required this.lastUnlocked,
    this.unlockCount = 0, this.version = '1.0',
  });
}

// ── Finance categories — i18n keys ──────────────────────────
// Each entry: emoji + i18n key (looked up at render time)
class FinanceCategories {
  static const List<Map<String, String>> income = [
    {'emoji': '💼', 'key': 'cat_work'},
    {'emoji': '💻', 'key': 'cat_freelance'},
    {'emoji': '📈', 'key': 'cat_investment'},
    {'emoji': '🎁', 'key': 'cat_gift'},
    {'emoji': '📦', 'key': 'cat_other'},
  ];
  static const List<Map<String, String>> expense = [
    {'emoji': '🏠', 'key': 'cat_housing'},
    {'emoji': '🍜', 'key': 'cat_food'},
    {'emoji': '🚌', 'key': 'cat_transport'},
    {'emoji': '🛍', 'key': 'cat_shopping'},
    {'emoji': '💊', 'key': 'cat_health'},
    {'emoji': '📚', 'key': 'cat_education'},
    {'emoji': '🎮', 'key': 'cat_entertainment'},
    {'emoji': '💝', 'key': 'cat_gifts'},
    {'emoji': '📦', 'key': 'cat_other'},
  ];
}

// ── Mood options ─────────────────────────────────────────────
class MoodOptions {
  static const List<Map<String, String>> all = [
    {'emoji': '😊', 'label': 'Happy'},
    {'emoji': '🤩', 'label': 'Excited'},
    {'emoji': '💪', 'label': 'Motivated'},
    {'emoji': '😌', 'label': 'Calm'},
    {'emoji': '😐', 'label': 'Neutral'},
    {'emoji': '😔', 'label': 'Sad'},
    {'emoji': '😤', 'label': 'Frustrated'},
    {'emoji': '😰', 'label': 'Anxious'},
    {'emoji': '😴', 'label': 'Tired'},
  ];
}
