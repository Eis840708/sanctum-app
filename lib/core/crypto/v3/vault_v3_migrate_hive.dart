// Hive/service adapter for the transactional v2 -> v3 migration (B2-5b).
// DEV-P0-03 B2-5b. Implements MigrationTarget over the real typed v2 boxes and
// the per-type v3 (staging + live) boxes, plus a durable journal that carries the
// pending v3 material so a resume can finish forward after a crash.
//
// prepareStaging strictly decrypts every v2 field (fail-CLOSED — a corrupt field
// throws and aborts the migration, leaving v2 intact; it never launders bad
// ciphertext), converts to the plaintext model, and re-seals each field into the
// v3 store (per-field envelope + AAD) in the STAGING boxes. The v2 live boxes are
// not touched until the atomic bundle's cleanup step (D), which runs only after
// the meta flip (C).

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../models/models.dart';
import '../crypto_service.dart';
import 'vault_v3_envelope.dart';
import 'vault_v3_live.dart';
import 'vault_v3_migrate.dart';
import 'vault_v3_record.dart';
import 'vault_v3_store.dart';

const String _migrationJournalBox = 'sanctum_migration_journal';
const String _jPhaseKey = 'phase';
const String _jMaterialKey = 'material';
const String _stagingSuffix = '__staging';

/// Opens the migration journal + all v3 staging/live boxes and returns a ready
/// transaction. [v2Key] is the just-unlocked v2 session key; [created] carries
/// the fresh DEK material + data subkey the migration re-encrypts under.
Future<TransactionalMigration> openHiveMigration({
  required Box<PasswordEntry> v2Passwords,
  required Box<DiaryEntry> v2Diary,
  required Box<FinanceRecord> v2Finance,
  required Box<String> v2Images,
  required Box v2ImageIndex,
  required Box<VaultMeta> meta,
  required Box v3MaterialBox,
  required String v3MaterialKey,
  required SecretKey v2Key,
  required V3CreateResult created,
  required Uint8List vaultId,
}) async {
  final journal = await HiveMigrationJournal.open();
  final target = await HiveMigrationTarget.open(
    v2Passwords: v2Passwords,
    v2Diary: v2Diary,
    v2Finance: v2Finance,
    v2Images: v2Images,
    v2ImageIndex: v2ImageIndex,
    meta: meta,
    v3MaterialBox: v3MaterialBox,
    v3MaterialKey: v3MaterialKey,
    v2Key: v2Key,
    material: created.material,
    dataKey: created.dataKey,
    vaultId: vaultId,
    journal: journal,
  );
  return TransactionalMigration(target, journal);
}

/// Opens a resume-only migration transaction (no keys): completes or rolls back
/// an interrupted migration at the next unlock.
Future<TransactionalMigration> openHiveMigrationForResume({
  required Box<PasswordEntry> v2Passwords,
  required Box<DiaryEntry> v2Diary,
  required Box<FinanceRecord> v2Finance,
  required Box<String> v2Images,
  required Box v2ImageIndex,
  required Box<VaultMeta> meta,
  required Box v3MaterialBox,
  required String v3MaterialKey,
}) async {
  final journal = await HiveMigrationJournal.open();
  final target = await HiveMigrationTarget.openForResume(
    v2Passwords: v2Passwords,
    v2Diary: v2Diary,
    v2Finance: v2Finance,
    v2Images: v2Images,
    v2ImageIndex: v2ImageIndex,
    meta: meta,
    v3MaterialBox: v3MaterialBox,
    v3MaterialKey: v3MaterialKey,
    journal: journal,
  );
  return TransactionalMigration(target, journal);
}

/// Journal carrying the phase plus the pending v3 material JSON (so a resume from
/// commitIntent can install material without re-deriving the DEK).
class HiveMigrationJournal implements MigrationJournal {
  HiveMigrationJournal(this._box);
  final Box _box;

  static Future<HiveMigrationJournal> open() async =>
      HiveMigrationJournal(await Hive.openBox(_migrationJournalBox));

  @override
  Future<MigrationPhase?> read() async {
    final raw = _box.get(_jPhaseKey);
    if (raw is! String) return null;
    return MigrationPhase.values.firstWhere((p) => p.name == raw);
  }

  @override
  Future<void> write(MigrationPhase phase) async =>
      _box.put(_jPhaseKey, phase.name);

  @override
  Future<void> clear() async {
    await _box.delete(_jPhaseKey);
    await _box.delete(_jMaterialKey);
  }

  Future<void> putMaterial(String encoded) async =>
      _box.put(_jMaterialKey, encoded);

  String? materialJson() => _box.get(_jMaterialKey) as String?;
}

/// MigrationTarget over the real boxes.
class HiveMigrationTarget implements MigrationTarget {
  HiveMigrationTarget._({
    required this.v2Passwords,
    required this.v2Diary,
    required this.v2Finance,
    required this.v2Images,
    required this.v2ImageIndex,
    required this.meta,
    required this.v3MaterialBox,
    required this.v3MaterialKey,
    required this.v2Key,
    required this.material,
    required this.store,
    required this.vaultId,
    required this.journal,
    required this.sPasswords,
    required this.sDiary,
    required this.sFinance,
    required this.sImages,
    required this.sImageIndex,
    required this.lPasswords,
    required this.lDiary,
    required this.lFinance,
    required this.lImages,
    required this.lImageIndex,
  });

  final Box<PasswordEntry> v2Passwords;
  final Box<DiaryEntry> v2Diary;
  final Box<FinanceRecord> v2Finance;
  final Box<String> v2Images;
  final Box v2ImageIndex;
  final Box<VaultMeta> meta;
  final Box v3MaterialBox;
  final String v3MaterialKey;
  // Migrate-path inputs; null on the resume-only path (recover() never uses them —
  // it works from the durable staging boxes + journalled pending material).
  final SecretKey? v2Key;
  final VaultV3Material? material;
  final VaultV3Store? store;
  final Uint8List vaultId;
  final HiveMigrationJournal journal;

  // v3 staging boxes
  final Box sPasswords, sDiary, sFinance, sImages, sImageIndex;
  // v3 live boxes
  final Box lPasswords, lDiary, lFinance, lImages, lImageIndex;

  static Future<HiveMigrationTarget> open({
    required Box<PasswordEntry> v2Passwords,
    required Box<DiaryEntry> v2Diary,
    required Box<FinanceRecord> v2Finance,
    required Box<String> v2Images,
    required Box v2ImageIndex,
    required Box<VaultMeta> meta,
    required Box v3MaterialBox,
    required String v3MaterialKey,
    required SecretKey v2Key,
    required VaultV3Material material,
    required SecretKey dataKey,
    required Uint8List vaultId,
    required HiveMigrationJournal journal,
  }) async {
    Future<Box> open(String name) => Hive.openBox(name);
    return HiveMigrationTarget._(
      v2Passwords: v2Passwords,
      v2Diary: v2Diary,
      v2Finance: v2Finance,
      v2Images: v2Images,
      v2ImageIndex: v2ImageIndex,
      meta: meta,
      v3MaterialBox: v3MaterialBox,
      v3MaterialKey: v3MaterialKey,
      v2Key: v2Key,
      material: material,
      store: VaultV3Store(dataKey: dataKey, vaultId: vaultId),
      vaultId: vaultId,
      journal: journal,
      sPasswords: await open('$kV3PasswordsBox$_stagingSuffix'),
      sDiary: await open('$kV3DiaryBox$_stagingSuffix'),
      sFinance: await open('$kV3FinanceBox$_stagingSuffix'),
      sImages: await open('$kV3ImagesBox$_stagingSuffix'),
      sImageIndex: await open('$kV3ImageIndexBox$_stagingSuffix'),
      lPasswords: await open(kV3PasswordsBox),
      lDiary: await open(kV3DiaryBox),
      lFinance: await open(kV3FinanceBox),
      lImages: await open(kV3ImagesBox),
      lImageIndex: await open(kV3ImageIndexBox),
    );
  }

  /// Resume-only target: no keys needed — recover() works from the durable
  /// staging boxes + journalled pending material.
  static Future<HiveMigrationTarget> openForResume({
    required Box<PasswordEntry> v2Passwords,
    required Box<DiaryEntry> v2Diary,
    required Box<FinanceRecord> v2Finance,
    required Box<String> v2Images,
    required Box v2ImageIndex,
    required Box<VaultMeta> meta,
    required Box v3MaterialBox,
    required String v3MaterialKey,
    required HiveMigrationJournal journal,
  }) async {
    Future<Box> open(String name) => Hive.openBox(name);
    return HiveMigrationTarget._(
      v2Passwords: v2Passwords,
      v2Diary: v2Diary,
      v2Finance: v2Finance,
      v2Images: v2Images,
      v2ImageIndex: v2ImageIndex,
      meta: meta,
      v3MaterialBox: v3MaterialBox,
      v3MaterialKey: v3MaterialKey,
      v2Key: null,
      material: null,
      store: null,
      vaultId: Uint8List(VaultV3.uuidBytes),
      journal: journal,
      sPasswords: await open('$kV3PasswordsBox$_stagingSuffix'),
      sDiary: await open('$kV3DiaryBox$_stagingSuffix'),
      sFinance: await open('$kV3FinanceBox$_stagingSuffix'),
      sImages: await open('$kV3ImagesBox$_stagingSuffix'),
      sImageIndex: await open('$kV3ImageIndexBox$_stagingSuffix'),
      lPasswords: await open(kV3PasswordsBox),
      lDiary: await open(kV3DiaryBox),
      lFinance: await open(kV3FinanceBox),
      lImages: await open(kV3ImagesBox),
      lImageIndex: await open(kV3ImageIndexBox),
    );
  }

  Future<String> _dec(String v) async =>
      v.isEmpty ? '' : await cryptoService.decrypt(v, v2Key!);

  @override
  Future<void> prepareStaging() async {
    await discardStaging();
    // Non-null on the migrate path (openForResume never calls prepareStaging).
    final store = this.store!;
    final material = this.material!;

    for (final e in v2Passwords.values) {
      final plain = PasswordEntry(
        id: e.id,
        site: await _dec(e.site),
        username: await _dec(e.username),
        encryptedPassword: await _dec(e.encryptedPassword),
        notes: await _dec(e.notes),
        createdAt: e.createdAt,
        updatedAt: e.updatedAt,
        iconEmoji: e.iconEmoji,
      );
      await store.put(
        box: sPasswords,
        recordType: RecordType.password,
        id: e.id,
        fields: passwordToFields(plain),
      );
    }

    for (final e in v2Diary.values) {
      final plain = DiaryEntry(
        id: e.id,
        title: await _dec(e.title),
        encryptedContent: await _dec(e.encryptedContent),
        mood: await _dec(e.mood),
        tags: e.tags,
        createdAt: e.createdAt,
        updatedAt: e.updatedAt,
      );
      await store.put(
        box: sDiary,
        recordType: RecordType.diary,
        id: e.id,
        fields: diaryToFields(plain),
      );
    }

    for (final e in v2Finance.values) {
      final plain = FinanceRecord(
        id: e.id,
        type: await _dec(e.type),
        amount: e.amount,
        category: await _dec(e.category),
        description: await _dec(e.description),
        date: e.date,
        createdAt: e.createdAt,
        currency: e.currency,
        lineItemsJson: e.lineItemsJson,
      );
      await store.put(
        box: sFinance,
        recordType: RecordType.finance,
        id: e.id,
        fields: financeToFields(plain),
      );
    }

    for (final key in v2Images.keys) {
      final enc = v2Images.get(key);
      if (enc is! String) continue;
      final plainBytes = await _dec(enc);
      await store.put(
        box: sImages,
        recordType: RecordType.image,
        id: key.toString(),
        fields: {V3FieldId.imageBytes: plainBytes},
      );
    }

    for (final key in v2ImageIndex.keys) {
      final ids = List<String>.from(v2ImageIndex.get(key) as List);
      await store.put(
        box: sImageIndex,
        recordType: RecordType.image,
        id: key.toString(),
        fields: {V3FieldId.imageIndexList: jsonEncode(ids)},
      );
    }

    // Persist the pending material so a resume from commitIntent can install it.
    await journal.putMaterial(material.encode());
  }

  @override
  Future<bool> verifyStaging() async {
    return sPasswords.length == v2Passwords.length &&
        sDiary.length == v2Diary.length &&
        sFinance.length == v2Finance.length &&
        sImages.length == v2Images.length &&
        sImageIndex.length == v2ImageIndex.length;
  }

  @override
  Future<void> installMaterial() async {
    // Always from the journalled pending material (written before commitIntent),
    // so a resume can install it without the DEK/password.
    final pending = journal.materialJson();
    if (pending == null) {
      throw StateError('no pending v3 material to install');
    }
    await v3MaterialBox.put(v3MaterialKey, pending);
  }

  @override
  Future<void> commitStagingToLive() async {
    await _copy(sPasswords, lPasswords);
    await _copy(sDiary, lDiary);
    await _copy(sFinance, lFinance);
    await _copy(sImages, lImages);
    await _copy(sImageIndex, lImageIndex);
  }

  @override
  Future<void> flipMetaToV3() async {
    final m = meta.get('meta');
    if (m != null) {
      m.version = 'v3';
      await m.save();
    }
  }

  @override
  Future<void> cleanupV2AndStaging() async {
    await v2Passwords.clear();
    await v2Diary.clear();
    await v2Finance.clear();
    await v2Images.clear();
    await v2ImageIndex.clear();
    await discardStaging();
  }

  @override
  Future<void> discardStaging() async {
    await sPasswords.clear();
    await sDiary.clear();
    await sFinance.clear();
    await sImages.clear();
    await sImageIndex.clear();
  }

  static Future<void> _copy(Box from, Box to) async {
    await to.clear();
    for (final key in from.keys) {
      await to.put(key, from.get(key));
    }
  }
}
