// Hive / secure-storage adapter for the pure transactional restore engine.
// DEV-P0-03 B2-3 (findings V-01, V-02).
//
// Thin I/O glue only: it implements the [RestoreTarget] and [RestoreJournalStore]
// ports over real Hive boxes and the vault's secure storage. All transaction
// logic (validate -> stage -> commit -> rollback -> resume) lives in the pure
// `vault_v3_restore.dart`, which is unit-tested with in-memory fakes.
//
// Staging namespaces are `<liveBoxName>__staging`; the journal is a dedicated
// box. Records are copied into detached instances on both write and commit so a
// [StagedVault] never becomes owned by a Hive box (avoids HiveObject re-binding
// errors) and so [commitStagingToLive] is safely idempotent for crash resume.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../models/models.dart';
import 'vault_v3_restore.dart';

const String _stagingSuffix = '__staging';
const String _journalBoxName = 'sanctum_restore_journal';
const String _journalKey = 'j';

/// Opens the staging + journal infrastructure and returns a ready transaction.
Future<TransactionalRestore> openHiveRestore({
  required Box<PasswordEntry> livePasswords,
  required Box<DiaryEntry> liveDiary,
  required Box<FinanceRecord> liveFinance,
  required Box<String> liveImages,
  required Box liveImageIndex,
  required Box<VaultMeta> liveMeta,
  required FlutterSecureStorage secureStorage,
  required String saltKey,
  required String biometricKey,
  required String encV2Key,
}) async {
  final target = await HiveRestoreTarget.open(
    livePasswords: livePasswords,
    liveDiary: liveDiary,
    liveFinance: liveFinance,
    liveImages: liveImages,
    liveImageIndex: liveImageIndex,
    liveMeta: liveMeta,
    secureStorage: secureStorage,
    saltKey: saltKey,
    biometricKey: biometricKey,
    encV2Key: encV2Key,
  );
  final journal = await HiveRestoreJournalStore.open();
  return TransactionalRestore(target, journal);
}

/// [RestoreTarget] over real Hive boxes + secure storage.
class HiveRestoreTarget implements RestoreTarget {
  HiveRestoreTarget._({
    required this.livePasswords,
    required this.liveDiary,
    required this.liveFinance,
    required this.liveImages,
    required this.liveImageIndex,
    required this.liveMeta,
    required this.sPasswords,
    required this.sDiary,
    required this.sFinance,
    required this.sImages,
    required this.sImageIndex,
    required this.sMeta,
    required this.secureStorage,
    required this.saltKey,
    required this.biometricKey,
    required this.encV2Key,
  });

  final Box<PasswordEntry> livePasswords;
  final Box<DiaryEntry> liveDiary;
  final Box<FinanceRecord> liveFinance;
  final Box<String> liveImages;
  final Box liveImageIndex;
  final Box<VaultMeta> liveMeta;

  final Box<PasswordEntry> sPasswords;
  final Box<DiaryEntry> sDiary;
  final Box<FinanceRecord> sFinance;
  final Box<String> sImages;
  final Box sImageIndex;
  final Box<VaultMeta> sMeta;

  final FlutterSecureStorage secureStorage;
  final String saltKey;
  final String biometricKey;
  final String encV2Key;

  static const String _metaKey = 'meta';

  static Future<HiveRestoreTarget> open({
    required Box<PasswordEntry> livePasswords,
    required Box<DiaryEntry> liveDiary,
    required Box<FinanceRecord> liveFinance,
    required Box<String> liveImages,
    required Box liveImageIndex,
    required Box<VaultMeta> liveMeta,
    required FlutterSecureStorage secureStorage,
    required String saltKey,
    required String biometricKey,
    required String encV2Key,
  }) async {
    return HiveRestoreTarget._(
      livePasswords: livePasswords,
      liveDiary: liveDiary,
      liveFinance: liveFinance,
      liveImages: liveImages,
      liveImageIndex: liveImageIndex,
      liveMeta: liveMeta,
      sPasswords: await Hive.openBox<PasswordEntry>(
          '${livePasswords.name}$_stagingSuffix'),
      sDiary:
          await Hive.openBox<DiaryEntry>('${liveDiary.name}$_stagingSuffix'),
      sFinance: await Hive.openBox<FinanceRecord>(
          '${liveFinance.name}$_stagingSuffix'),
      sImages: await Hive.openBox<String>('${liveImages.name}$_stagingSuffix'),
      sImageIndex: await Hive.openBox('${liveImageIndex.name}$_stagingSuffix'),
      sMeta: await Hive.openBox<VaultMeta>('${liveMeta.name}$_stagingSuffix'),
      secureStorage: secureStorage,
      saltKey: saltKey,
      biometricKey: biometricKey,
      encV2Key: encV2Key,
    );
  }

  @override
  Future<void> writeStaging(StagedVault data) async {
    await discardStaging();
    for (final e in data.passwords) {
      await sPasswords.put(e.id, _copyPassword(e));
    }
    for (final e in data.diary) {
      await sDiary.put(e.id, _copyDiary(e));
    }
    for (final e in data.finance) {
      await sFinance.put(e.id, _copyFinance(e));
    }
    for (final e in data.images.entries) {
      await sImages.put(e.key, e.value);
    }
    for (final e in data.imageIndex.entries) {
      await sImageIndex.put(e.key, List<String>.from(e.value));
    }
    final meta = data.meta;
    if (meta != null) {
      await sMeta.put(_metaKey, _copyMeta(meta));
    }
  }

  @override
  Future<bool> verifyStaging(StagedVault data) async {
    if (sPasswords.length != data.passwords.length) return false;
    if (sDiary.length != data.diary.length) return false;
    if (sFinance.length != data.finance.length) return false;
    if (sImages.length != data.images.length) return false;
    if (sImageIndex.length != data.imageIndex.length) return false;
    if ((data.meta != null) != sMeta.isNotEmpty) return false;
    return true;
  }

  @override
  Future<void> commitStagingToLive() async {
    await livePasswords.clear();
    for (final e in sPasswords.values) {
      await livePasswords.put(e.id, _copyPassword(e));
    }
    await liveDiary.clear();
    for (final e in sDiary.values) {
      await liveDiary.put(e.id, _copyDiary(e));
    }
    await liveFinance.clear();
    for (final e in sFinance.values) {
      await liveFinance.put(e.id, _copyFinance(e));
    }
    await liveImages.clear();
    for (final e in sImages.toMap().entries) {
      await liveImages.put(e.key, e.value);
    }
    await liveImageIndex.clear();
    for (final e in sImageIndex.toMap().entries) {
      await liveImageIndex.put(e.key, List<String>.from(e.value as List));
    }
    // Meta is only replaced when the candidate carried credentials; a same-device
    // backup restore stages no meta and must leave the live meta untouched.
    if (sMeta.isNotEmpty) {
      final m = sMeta.get(_metaKey);
      if (m != null) {
        await liveMeta.clear();
        await liveMeta.put(_metaKey, _copyMeta(m));
      }
    }
  }

  @override
  Future<void> applyCommitSideEffects(RestoreSideEffects effects) async {
    final salt = effects.salt;
    if (salt != null) {
      await secureStorage.write(key: saltKey, value: salt);
    }
    if (effects.installEncV2Done) {
      await secureStorage.write(key: encV2Key, value: 'done');
    }
    if (effects.deleteBiometricKey) {
      await secureStorage.delete(key: biometricKey);
    }
  }

  @override
  Future<void> discardStaging() async {
    await sPasswords.clear();
    await sDiary.clear();
    await sFinance.clear();
    await sImages.clear();
    await sImageIndex.clear();
    await sMeta.clear();
  }
}

/// [RestoreJournalStore] over a dedicated Hive box holding one latest entry as a
/// primitive map (no adapter needed).
class HiveRestoreJournalStore implements RestoreJournalStore {
  HiveRestoreJournalStore(this._box);

  final Box _box;

  static Future<HiveRestoreJournalStore> open() async {
    final box = await Hive.openBox(_journalBoxName);
    return HiveRestoreJournalStore(box);
  }

  @override
  Future<RestoreJournalEntry?> read() async {
    final raw = _box.get(_journalKey);
    if (raw == null) return null;
    return RestoreJournalEntry.fromJson((raw as Map).cast<String, dynamic>());
  }

  @override
  Future<void> write(RestoreJournalEntry entry) async {
    await _box.put(_journalKey, entry.toJson());
  }

  @override
  Future<void> clear() async {
    await _box.delete(_journalKey);
  }
}

// ── Detached copies (keep StagedVault a pure DTO; idempotent commit) ──────────

PasswordEntry _copyPassword(PasswordEntry e) => PasswordEntry(
      id: e.id,
      site: e.site,
      username: e.username,
      encryptedPassword: e.encryptedPassword,
      notes: e.notes,
      createdAt: e.createdAt,
      updatedAt: e.updatedAt,
      iconEmoji: e.iconEmoji,
    );

DiaryEntry _copyDiary(DiaryEntry e) => DiaryEntry(
      id: e.id,
      title: e.title,
      encryptedContent: e.encryptedContent,
      mood: e.mood,
      createdAt: e.createdAt,
      updatedAt: e.updatedAt,
      tags: List<String>.from(e.tags),
    );

FinanceRecord _copyFinance(FinanceRecord e) => FinanceRecord(
      id: e.id,
      type: e.type,
      amount: e.amount,
      category: e.category,
      description: e.description,
      date: e.date,
      createdAt: e.createdAt,
      currency: e.currency,
      lineItemsJson: e.lineItemsJson,
    );

VaultMeta _copyMeta(VaultMeta m) => VaultMeta(
      salt: m.salt,
      verifyHash: m.verifyHash,
      createdAt: m.createdAt,
      lastUnlocked: m.lastUnlocked,
      unlockCount: m.unlockCount,
      version: m.version,
    );
