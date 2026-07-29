// v3 full-record store + model<->fieldMap conversion (DEV-P0-03 B2-5b, option C).
// Design freeze: storage supplement v1.3-delta, design-spec §5.
//
// The pure conversion functions turn a PLAINTEXT model object into a
// fieldId -> plaintext-string map (and back), applying the canonical typed-field
// serialisation of supplement §6 (double / DateTime / List -> string). The store
// seals each field with VaultV3RecordCodec and persists the JSON in an
// independent per-type v3 box keyed by the record id. models.dart is untouched;
// the model objects here carry PLAINTEXT values (the v3 layer owns encryption),
// unlike the v2 typed boxes where the string fields held v2 ciphertext.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../models/models.dart';
import 'vault_v3_envelope.dart';
import 'vault_v3_record.dart';

// ── Per-type v3 box names (supplement §2) ────────────────────────────────────
const String kV3PasswordsBox = 'sanctum_passwords__v3';
const String kV3DiaryBox = 'sanctum_diary__v3';
const String kV3FinanceBox = 'sanctum_finance__v3';
const String kV3ImagesBox = 'sanctum_images__v3';
const String kV3ImageIndexBox = 'sanctum_image_index__v3';

// ── Pure model <-> fieldMap conversion (supplement §6) ───────────────────────

String _dt(DateTime d) => d.millisecondsSinceEpoch.toString();
DateTime _parseDt(String s) => DateTime.fromMillisecondsSinceEpoch(int.parse(s));

Map<int, String> passwordToFields(PasswordEntry e) => <int, String>{
      V3FieldId.pwSite: e.site,
      V3FieldId.pwUsername: e.username,
      V3FieldId.pwPassword: e.encryptedPassword,
      V3FieldId.pwNotes: e.notes,
      V3FieldId.pwIconEmoji: e.iconEmoji ?? '',
      V3FieldId.pwCreatedAt: _dt(e.createdAt),
      V3FieldId.pwUpdatedAt: _dt(e.updatedAt),
    };

PasswordEntry passwordFromFields(String id, Map<int, String> f) {
  final icon = f[V3FieldId.pwIconEmoji] ?? '';
  return PasswordEntry(
    id: id,
    site: f[V3FieldId.pwSite] ?? '',
    username: f[V3FieldId.pwUsername] ?? '',
    encryptedPassword: f[V3FieldId.pwPassword] ?? '',
    notes: f[V3FieldId.pwNotes] ?? '',
    createdAt: _parseDt(f[V3FieldId.pwCreatedAt]!),
    updatedAt: _parseDt(f[V3FieldId.pwUpdatedAt]!),
    iconEmoji: icon.isEmpty ? null : icon,
  );
}

Map<int, String> diaryToFields(DiaryEntry e) => <int, String>{
      V3FieldId.diaryTitle: e.title,
      V3FieldId.diaryContent: e.encryptedContent,
      V3FieldId.diaryMood: e.mood,
      V3FieldId.diaryTags: jsonEncode(e.tags),
      V3FieldId.diaryCreatedAt: _dt(e.createdAt),
      V3FieldId.diaryUpdatedAt: _dt(e.updatedAt),
    };

DiaryEntry diaryFromFields(String id, Map<int, String> f) => DiaryEntry(
      id: id,
      title: f[V3FieldId.diaryTitle] ?? '',
      encryptedContent: f[V3FieldId.diaryContent] ?? '',
      mood: f[V3FieldId.diaryMood] ?? '',
      tags: (jsonDecode(f[V3FieldId.diaryTags] ?? '[]') as List).cast<String>(),
      createdAt: _parseDt(f[V3FieldId.diaryCreatedAt]!),
      updatedAt: _parseDt(f[V3FieldId.diaryUpdatedAt]!),
    );

Map<int, String> financeToFields(FinanceRecord e) => <int, String>{
      V3FieldId.finType: e.type,
      V3FieldId.finCategory: e.category,
      V3FieldId.finDescription: e.description,
      V3FieldId.finAmount: e.amount.toString(),
      V3FieldId.finCurrency: e.currency,
      V3FieldId.finDate: _dt(e.date),
      if (e.lineItemsJson != null) V3FieldId.finLineItems: e.lineItemsJson!,
      V3FieldId.finCreatedAt: _dt(e.createdAt),
    };

FinanceRecord financeFromFields(String id, Map<int, String> f) => FinanceRecord(
      id: id,
      type: f[V3FieldId.finType] ?? '',
      amount: double.parse(f[V3FieldId.finAmount]!),
      category: f[V3FieldId.finCategory] ?? '',
      description: f[V3FieldId.finDescription] ?? '',
      date: _parseDt(f[V3FieldId.finDate]!),
      createdAt: _parseDt(f[V3FieldId.finCreatedAt]!),
      currency: f[V3FieldId.finCurrency] ?? 'HKD',
      lineItemsJson: f[V3FieldId.finLineItems],
    );

// ── Store over per-type v3 boxes ─────────────────────────────────────────────

/// Reads and writes fully-encrypted v3 records. All field values are sealed with
/// [VaultV3RecordCodec] (per-field envelope + V-06 AAD) before storage.
class VaultV3Store {
  VaultV3Store({
    required this.dataKey,
    required this.vaultId,
    VaultV3RecordCodec? codec,
  }) : _codec = codec ?? vaultV3RecordCodec;

  final SecretKey dataKey;
  final Uint8List vaultId;
  final VaultV3RecordCodec _codec;

  Future<void> put({
    required Box box,
    required RecordType recordType,
    required String id,
    required Map<int, String> fields,
  }) async {
    final stored = await _codec.encode(
      recordType: recordType,
      id: id,
      fields: fields,
      dataKey: dataKey,
      vaultId: vaultId,
    );
    await box.put(id, stored);
  }

  Future<Map<int, String>?> get({
    required Box box,
    required RecordType recordType,
    required String id,
  }) async {
    final raw = box.get(id);
    if (raw is! String) return null;
    return _codec.decode(
      recordType: recordType,
      id: id,
      stored: raw,
      dataKey: dataKey,
      vaultId: vaultId,
    );
  }

  /// Decrypts every record in [box] to (id, fields). Decryption is in-memory,
  /// which is where all v3 search/sort happens (supplement §3; blind-index out
  /// of scope).
  Future<List<MapEntry<String, Map<int, String>>>> getAll({
    required Box box,
    required RecordType recordType,
  }) async {
    final out = <MapEntry<String, Map<int, String>>>[];
    for (final key in box.keys) {
      final id = key.toString();
      final fields = await get(box: box, recordType: recordType, id: id);
      if (fields != null) out.add(MapEntry(id, fields));
    }
    return out;
  }
}
