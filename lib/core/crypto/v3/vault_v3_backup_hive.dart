// Hive glue for the v3 backup restore (DEV-P0-03-UI 子項 A).
//
// Restore REUSES the proven B2-5b transactional engine (vault_v3_migrate.dart:
// TransactionalMigration — staged -> verified -> commitIntent -> forward-replay,
// with an idempotent resume). Only the SOURCE differs: instead of decrypting v2
// records, [HiveBackupRestoreTarget.prepareStaging] writes the backup's already-
// sealed per-field envelopes into the v3 staging boxes VERBATIM. Because the
// backup carries the original vaultId (via the embedded material), the per-field
// V-06 AAD still matches, so the records decrypt in place after the swap.
//
// A DEDICATED journal box (separate from the migration journal) is used so an
// interrupted restore resumes through its own unlock hook and can CREATE the meta
// record on a fresh device (the migration-resume path assumes meta already
// exists). The commit bundle is otherwise identical to the migration:
//   A install v3 material  B staging->live  C flip meta v3  D clear v2 + staging.
//
// Interrupt invariant (RETURN-level, mirrors B2-5b): before commitIntent nothing
// live is mutated (staging discarded, any prior vault intact); at/after
// commitIntent the forward replay is idempotent from the durable staging + the
// journalled pending material.

import 'package:hive_flutter/hive_flutter.dart';

import '../../models/models.dart';
import 'vault_v3_live.dart' show VaultV3Material;
import 'vault_v3_migrate.dart';
import 'vault_v3_store.dart';

const String _backupJournalBox = 'sanctum_backup_restore_journal';
const String _jPhaseKey = 'phase';
const String _jMaterialKey = 'material';
const String _stagingSuffix = '__staging';

/// Canonical v3 box order (also the stable tokens used as keys in a backup's
/// recordsByBox map).
const List<String> kV3BackupBoxNames = <String>[
  kV3PasswordsBox,
  kV3DiaryBox,
  kV3FinanceBox,
  kV3ImagesBox,
  kV3ImageIndexBox,
];

/// Opens a full backup-restore transaction (writes [recordsByBox] to staging then
/// atomically installs [material] + swaps live + flips meta to v3).
Future<TransactionalMigration> openHiveBackupRestore({
  required Map<String, Map<String, String>> recordsByBox,
  required VaultV3Material material,
  required Box<VaultMeta> meta,
  required Box v3MaterialBox,
  required String v3MaterialKey,
  required Box<PasswordEntry> v2Passwords,
  required Box<DiaryEntry> v2Diary,
  required Box<FinanceRecord> v2Finance,
  required Box<String> v2Images,
  required Box v2ImageIndex,
}) async {
  final journal = await HiveBackupRestoreJournal.open();
  final target = await HiveBackupRestoreTarget._open(
    recordsByBox: recordsByBox,
    material: material,
    meta: meta,
    v3MaterialBox: v3MaterialBox,
    v3MaterialKey: v3MaterialKey,
    v2Passwords: v2Passwords,
    v2Diary: v2Diary,
    v2Finance: v2Finance,
    v2Images: v2Images,
    v2ImageIndex: v2ImageIndex,
    journal: journal,
  );
  return TransactionalMigration(target, journal);
}

/// Opens a resume-only backup-restore transaction (no records/material in memory):
/// completes or rolls back an interrupted restore at the next unlock.
Future<TransactionalMigration> openHiveBackupRestoreForResume({
  required Box<VaultMeta> meta,
  required Box v3MaterialBox,
  required String v3MaterialKey,
  required Box<PasswordEntry> v2Passwords,
  required Box<DiaryEntry> v2Diary,
  required Box<FinanceRecord> v2Finance,
  required Box<String> v2Images,
  required Box v2ImageIndex,
}) async {
  final journal = await HiveBackupRestoreJournal.open();
  final target = await HiveBackupRestoreTarget._open(
    recordsByBox: null,
    material: null,
    meta: meta,
    v3MaterialBox: v3MaterialBox,
    v3MaterialKey: v3MaterialKey,
    v2Passwords: v2Passwords,
    v2Diary: v2Diary,
    v2Finance: v2Finance,
    v2Images: v2Images,
    v2ImageIndex: v2ImageIndex,
    journal: journal,
  );
  return TransactionalMigration(target, journal);
}

/// Journal carrying phase + pending material JSON (so a resume from commitIntent
/// installs material without the DEK/password).
class HiveBackupRestoreJournal implements MigrationJournal {
  HiveBackupRestoreJournal(this._box);
  final Box _box;

  static Future<HiveBackupRestoreJournal> open() async =>
      HiveBackupRestoreJournal(await Hive.openBox(_backupJournalBox));

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

/// [MigrationTarget] whose staging source is a decoded backup's raw envelopes.
class HiveBackupRestoreTarget implements MigrationTarget {
  HiveBackupRestoreTarget._internal({
    required this.recordsByBox,
    required this.material,
    required this.meta,
    required this.v3MaterialBox,
    required this.v3MaterialKey,
    required this.v2Passwords,
    required this.v2Diary,
    required this.v2Finance,
    required this.v2Images,
    required this.v2ImageIndex,
    required this.journal,
    required this.staging,
    required this.live,
  });

  // Non-null on the full path; null on resume (recover() works from durable
  // staging + journalled pending material).
  final Map<String, Map<String, String>>? recordsByBox;
  final VaultV3Material? material;

  final Box<VaultMeta> meta;
  final Box v3MaterialBox;
  final String v3MaterialKey;
  final Box<PasswordEntry> v2Passwords;
  final Box<DiaryEntry> v2Diary;
  final Box<FinanceRecord> v2Finance;
  final Box<String> v2Images;
  final Box v2ImageIndex;
  final HiveBackupRestoreJournal journal;

  /// box token -> staging box / live box, in [kV3BackupBoxNames] order.
  final Map<String, Box> staging;
  final Map<String, Box> live;

  static Future<HiveBackupRestoreTarget> _open({
    required Map<String, Map<String, String>>? recordsByBox,
    required VaultV3Material? material,
    required Box<VaultMeta> meta,
    required Box v3MaterialBox,
    required String v3MaterialKey,
    required Box<PasswordEntry> v2Passwords,
    required Box<DiaryEntry> v2Diary,
    required Box<FinanceRecord> v2Finance,
    required Box<String> v2Images,
    required Box v2ImageIndex,
    required HiveBackupRestoreJournal journal,
  }) async {
    final staging = <String, Box>{};
    final live = <String, Box>{};
    for (final name in kV3BackupBoxNames) {
      live[name] = await Hive.openBox(name);
      staging[name] = await Hive.openBox('$name$_stagingSuffix');
    }
    return HiveBackupRestoreTarget._internal(
      recordsByBox: recordsByBox,
      material: material,
      meta: meta,
      v3MaterialBox: v3MaterialBox,
      v3MaterialKey: v3MaterialKey,
      v2Passwords: v2Passwords,
      v2Diary: v2Diary,
      v2Finance: v2Finance,
      v2Images: v2Images,
      v2ImageIndex: v2ImageIndex,
      journal: journal,
      staging: staging,
      live: live,
    );
  }

  @override
  Future<void> prepareStaging() async {
    await discardStaging();
    final records = recordsByBox!; // full path only
    final material = this.material!;
    for (final name in kV3BackupBoxNames) {
      final box = staging[name]!;
      final src = records[name];
      if (src == null) continue;
      for (final e in src.entries) {
        // Verbatim: the value is an already-sealed per-field envelope JSON.
        await box.put(e.key, e.value);
      }
    }
    // Persist pending material so a resume from commitIntent can install it.
    await journal.putMaterial(material.encode());
  }

  @override
  Future<bool> verifyStaging() async {
    final records = recordsByBox;
    if (records == null) return true; // resume path never verifies pre-commit
    for (final name in kV3BackupBoxNames) {
      final expected = records[name]?.length ?? 0;
      if (staging[name]!.length != expected) return false;
    }
    return true;
  }

  @override
  Future<void> installMaterial() async {
    final pending = journal.materialJson();
    if (pending == null) {
      throw StateError('no pending v3 material to install');
    }
    await v3MaterialBox.put(v3MaterialKey, pending);
  }

  @override
  Future<void> commitStagingToLive() async {
    for (final name in kV3BackupBoxNames) {
      await _copy(staging[name]!, live[name]!);
    }
  }

  @override
  Future<void> flipMetaToV3() async {
    final m = meta.get('meta');
    if (m != null) {
      m.version = 'v3';
      await m.save();
      return;
    }
    // Fresh device: no meta yet — create it so unlock routes to the v3 path.
    // v3 authenticates by unwrapping the DEK, so salt/verifyHash stay empty.
    final now = DateTime.now();
    await meta.put(
      'meta',
      VaultMeta(
        salt: '',
        verifyHash: '',
        createdAt: now,
        lastUnlocked: now,
        version: 'v3',
      ),
    );
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
    for (final name in kV3BackupBoxNames) {
      await staging[name]!.clear();
    }
  }

  static Future<void> _copy(Box from, Box to) async {
    await to.clear();
    for (final key in from.keys) {
      await to.put(key, from.get(key));
    }
  }
}
