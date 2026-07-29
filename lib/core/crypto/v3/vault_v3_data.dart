// v3 data-access layer (DEV-P0-03 B2-5b, option C).
//
// Encapsulates the v3 record store so VaultService can delegate each data method
// with a single branch (`if (v3) return _v3Data.xxx()`), keeping the core file's
// diff auditable. All records are fully encrypted per-field in the v3 boxes; this
// layer decrypts in memory (where all v3 search/sort happens) and re-encrypts on
// write. Model objects here carry PLAINTEXT values.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../models/models.dart';
import 'vault_v3_envelope.dart';
import 'vault_v3_record.dart';
import 'vault_v3_store.dart';

/// Clears all v3 record storage (live + staging). Used by a full vault wipe.
Future<void> clearAllV3Storage() async {
  for (final name in const [
    kV3PasswordsBox,
    kV3DiaryBox,
    kV3FinanceBox,
    kV3ImagesBox,
    kV3ImageIndexBox,
  ]) {
    await (await Hive.openBox(name)).clear();
    await (await Hive.openBox('${name}__staging')).clear();
  }
}

/// Opens the v3 live boxes and returns a data layer bound to the session.
Future<VaultV3Data> openVaultV3Data({
  required SecretKey dataKey,
  required Uint8List vaultId,
}) async {
  return VaultV3Data._(
    store: VaultV3Store(dataKey: dataKey, vaultId: vaultId),
    passwords: await Hive.openBox(kV3PasswordsBox),
    diary: await Hive.openBox(kV3DiaryBox),
    finance: await Hive.openBox(kV3FinanceBox),
    images: await Hive.openBox(kV3ImagesBox),
    imageIndex: await Hive.openBox(kV3ImageIndexBox),
  );
}

class VaultV3Data {
  VaultV3Data._({
    required this.store,
    required this.passwords,
    required this.diary,
    required this.finance,
    required this.images,
    required this.imageIndex,
  });

  final VaultV3Store store;
  final Box passwords, diary, finance, images, imageIndex;
  final _uuid = const Uuid();

  // ── Passwords ──────────────────────────────────────────────────────────────
  // v3 entries carry plaintext in every field (incl. the password in the
  // `encryptedPassword` slot); decryptPassword returns it directly.

  Future<List<PasswordEntry>> getPasswords() async {
    final all = await store.getAll(box: passwords, recordType: RecordType.password);
    final out = [for (final e in all) passwordFromFields(e.key, e.value)];
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  Future<void> addPassword({
    required String site,
    required String username,
    required String password,
    String notes = '',
    String? iconEmoji,
  }) async {
    final now = DateTime.now();
    final e = PasswordEntry(
      id: _uuid.v4(), site: site, username: username,
      encryptedPassword: password, notes: notes,
      createdAt: now, updatedAt: now, iconEmoji: iconEmoji,
    );
    await store.put(
      box: passwords, recordType: RecordType.password, id: e.id,
      fields: passwordToFields(e),
    );
  }

  String decryptPassword(PasswordEntry entry) => entry.encryptedPassword;

  Future<void> deletePassword(String id) async => passwords.delete(id);

  Future<PasswordEntry?> getRawPasswordEntry(String id) async {
    final f = await store.get(box: passwords, recordType: RecordType.password, id: id);
    return f == null ? null : passwordFromFields(id, f);
  }

  Future<void> restoreRawPasswordEntry(PasswordEntry entry) async => store.put(
        box: passwords, recordType: RecordType.password, id: entry.id,
        fields: passwordToFields(entry),
      );

  Future<void> updatePassword(PasswordEntry entry,
      {String? newPassword, String? site, String? username, String? notes}) async {
    final f = await store.get(box: passwords, recordType: RecordType.password, id: entry.id);
    if (f == null) return;
    final cur = passwordFromFields(entry.id, f);
    final updated = PasswordEntry(
      id: entry.id,
      site: site ?? cur.site,
      username: username ?? cur.username,
      encryptedPassword: newPassword ?? cur.encryptedPassword,
      notes: notes ?? cur.notes,
      createdAt: cur.createdAt,
      updatedAt: DateTime.now(),
      iconEmoji: cur.iconEmoji,
    );
    await store.put(
      box: passwords, recordType: RecordType.password, id: entry.id,
      fields: passwordToFields(updated),
    );
  }

  // ── Diary ──────────────────────────────────────────────────────────────────

  Future<List<DiaryEntry>> getDiaryEntries() async {
    final all = await store.getAll(box: diary, recordType: RecordType.diary);
    final out = [for (final e in all) diaryFromFields(e.key, e.value)];
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<String> addDiaryEntry({
    required String title,
    required String content,
    required String mood,
    List<String> tags = const [],
  }) async {
    final now = DateTime.now();
    final e = DiaryEntry(
      id: _uuid.v4(), title: title, encryptedContent: content, mood: mood,
      createdAt: now, updatedAt: now, tags: tags,
    );
    await store.put(
      box: diary, recordType: RecordType.diary, id: e.id, fields: diaryToFields(e),
    );
    return e.id;
  }

  String decryptDiaryContent(DiaryEntry entry) => entry.encryptedContent;

  Future<void> deleteDiaryEntry(String id) async => diary.delete(id);

  Future<void> updateDiaryEntry(DiaryEntry entry,
      {String? title, String? content, String? mood}) async {
    final f = await store.get(box: diary, recordType: RecordType.diary, id: entry.id);
    if (f == null) return;
    final cur = diaryFromFields(entry.id, f);
    final updated = DiaryEntry(
      id: entry.id,
      title: title ?? cur.title,
      encryptedContent: content ?? cur.encryptedContent,
      mood: mood ?? cur.mood,
      tags: cur.tags,
      createdAt: cur.createdAt,
      updatedAt: DateTime.now(),
    );
    await store.put(
      box: diary, recordType: RecordType.diary, id: entry.id,
      fields: diaryToFields(updated),
    );
  }

  // ── Diary images ───────────────────────────────────────────────────────────

  Future<String> addDiaryImage(Uint8List bytes) async {
    final id = _uuid.v4();
    await store.put(
      box: images, recordType: RecordType.image, id: id,
      fields: {V3FieldId.imageBytes: base64.encode(bytes)},
    );
    return id;
  }

  Future<Uint8List?> getDiaryImage(String imageId) async {
    final f = await store.get(box: images, recordType: RecordType.image, id: imageId);
    if (f == null) return null;
    return base64Decode(f[V3FieldId.imageBytes]!);
  }

  Future<List<String>> getDiaryImageIds(String entryId) async {
    final f = await store.get(box: imageIndex, recordType: RecordType.image, id: entryId);
    if (f == null) return [];
    return (jsonDecode(f[V3FieldId.imageIndexList] ?? '[]') as List).cast<String>();
  }

  Future<void> setDiaryImageIds(String entryId, List<String> ids) async {
    if (ids.isEmpty) {
      await imageIndex.delete(entryId);
      return;
    }
    await store.put(
      box: imageIndex, recordType: RecordType.image, id: entryId,
      fields: {V3FieldId.imageIndexList: jsonEncode(ids)},
    );
  }

  // ── Finance ────────────────────────────────────────────────────────────────

  Future<List<FinanceRecord>> getFinanceRecords() async {
    final all = await store.getAll(box: finance, recordType: RecordType.finance);
    final out = [for (final e in all) financeFromFields(e.key, e.value)];
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  Future<void> addFinanceRecord({
    String? id,
    required String type,
    required double amount,
    required String category,
    required String description,
    required DateTime date,
    String currency = 'MOP',
    String? lineItemsJson,
  }) async {
    final e = FinanceRecord(
      id: id ?? _uuid.v4(), type: type, amount: amount, category: category,
      description: description, date: date, createdAt: DateTime.now(),
      currency: currency, lineItemsJson: lineItemsJson,
    );
    await store.put(
      box: finance, recordType: RecordType.finance, id: e.id,
      fields: financeToFields(e),
    );
  }

  Future<void> deleteFinanceRecord(String id) async => finance.delete(id);

  Future<void> updateFinanceRecord(FinanceRecord record,
      {String? type, double? amount, String? category, String? description,
      DateTime? date, String? currency}) async {
    final f = await store.get(box: finance, recordType: RecordType.finance, id: record.id);
    if (f == null) return;
    final cur = financeFromFields(record.id, f);
    final updated = FinanceRecord(
      id: record.id,
      type: type ?? cur.type,
      amount: amount ?? cur.amount,
      category: category ?? cur.category,
      description: description ?? cur.description,
      date: date ?? cur.date,
      createdAt: cur.createdAt,
      currency: currency ?? cur.currency,
      lineItemsJson: cur.lineItemsJson,
    );
    await store.put(
      box: finance, recordType: RecordType.finance, id: record.id,
      fields: financeToFields(updated),
    );
  }

  Map<String, int> getCounts() => {
        'passwords': passwords.length,
        'diary': diary.length,
        'finance': finance.length,
      };
}
