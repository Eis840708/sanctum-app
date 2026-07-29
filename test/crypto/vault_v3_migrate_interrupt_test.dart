// Real-adapter v2->v3 migration INTERRUPT regression (DEV-P0-03 B2-5b, RETURN).
// Drives the REAL HiveMigrationTarget over real Hive boxes and simulates a crash
// between each step of the three-way atomic bundle (A install material / B
// staging->live / C flip meta / D clear v2). It asserts the RETURN invariant:
//   * a crash BEFORE the flip leaves meta='v2' and the v2 boxes intact (the
//     existing vault is untouched and unlockable);
//   * a crash AFTER the flip leaves a ready v3 vault;
//   * in every case a resume (what unlock() runs) completes forward and every
//     record survives and decrypts;
//   * after migration the v3 store holds no sensitive plaintext (only id keys).
// Synthetic data only.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:sanctum/core/crypto/crypto_service.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_live.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_migrate.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_migrate_hive.dart';
import 'package:sanctum/core/models/models.dart';
import 'package:sanctum/core/storage/vault_service.dart';

final Map<String, String> _secure = {};
const _pw = 'legacy-master-password';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('b2_5b_intr_');
    const pp = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pp, (c) async => tmp.path);
    const ss = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ss, (c) async {
      final a = (c.arguments as Map?)?.cast<String, dynamic>() ?? {};
      final k = a['key'] as String?;
      switch (c.method) {
        case 'write': _secure[k!] = a['value'] as String; return null;
        case 'read': return _secure[k];
        case 'delete': _secure.remove(k); return null;
        case 'deleteAll': _secure.clear(); return null;
        case 'readAll': return Map<String, String>.from(_secure);
        case 'containsKey': return _secure.containsKey(k);
        default: return null;
      }
    });
    await vaultService.init();
  });

  setUp(_wipe);

  // Interrupt after N of the 4 bundle steps [A,B,C,D]. 1 => after A (pre-flip),
  // 2 => after B (pre-flip), 3 => after C (post-flip).
  for (final stopAfter in [1, 2, 3]) {
    test('crash after step ${['A', 'B', 'C'][stopAfter - 1]} -> vault survives, '
        'resume completes, data intact', () async {
      await _seedV2Vault();

      final v2Key = await cryptoService.deriveKey(
          _pw, _saltBytes(Hive.box<VaultMeta>('sanctum_meta').get('meta')!.salt));
      final created = await vaultV3Live.create(_pw);
      final journal = await HiveMigrationJournal.open();
      final target = await HiveMigrationTarget.open(
        v2Passwords: Hive.box<PasswordEntry>('sanctum_passwords'),
        v2Diary: Hive.box<DiaryEntry>('sanctum_diary'),
        v2Finance: Hive.box<FinanceRecord>('sanctum_finance'),
        v2Images: Hive.box<String>('sanctum_images'),
        v2ImageIndex: Hive.box('sanctum_image_index'),
        meta: Hive.box<VaultMeta>('sanctum_meta'),
        v3MaterialBox: await Hive.openBox('sanctum_vault_v3'),
        v3MaterialKey: 'material',
        v2Key: v2Key,
        material: created.material,
        dataKey: created.dataKey,
        vaultId: created.material.vaultId,
        journal: journal,
      );

      // Drive up to the interrupt point.
      await target.prepareStaging();
      await journal.write(MigrationPhase.commitIntent);
      if (stopAfter >= 1) await target.installMaterial();
      if (stopAfter >= 2) await target.commitStagingToLive();
      if (stopAfter >= 3) await target.flipMetaToV3();
      // <-- simulated crash here (step D and beyond not run)

      final meta = Hive.box<VaultMeta>('sanctum_meta').get('meta')!;
      if (stopAfter < 3) {
        // Pre-flip: existing vault is untouched and still v2.
        expect(meta.version, 'v2');
        expect(Hive.box<PasswordEntry>('sanctum_passwords').length, 1);
      } else {
        // Post-flip: routed to a ready v3 vault.
        expect(meta.version, 'v3');
      }

      // Resume is exactly what unlock() runs; here we drive it directly, then
      // unlock to read the data back.
      await TransactionalMigration(target, journal).recover();
      expect(Hive.box<VaultMeta>('sanctum_meta').get('meta')!.version, 'v3');

      final ok = await vaultService.unlock(_pw);
      expect(ok, isTrue);
      final pws = await vaultService.getPasswords();
      expect(pws.single.site, 'bank.invalid');
      expect(await vaultService.decryptPassword(pws.single), 'hunter2');
      final diary = await vaultService.getDiaryEntries();
      expect(diary.single.title, 'my day');
      final fin = await vaultService.getFinanceRecords();
      expect(fin.single.amount, 4321.99);
    });
  }

  test('after migration the v3 store holds no sensitive plaintext', () async {
    await _seedV2Vault();
    final ok = await vaultService.unlock(_pw); // auto-migrates
    expect(ok, isTrue);
    expect(Hive.box<VaultMeta>('sanctum_meta').get('meta')!.version, 'v3');

    final blobs = <String>[
      ...Hive.box('sanctum_passwords__v3').values.cast<String>(),
      ...Hive.box('sanctum_diary__v3').values.cast<String>(),
      ...Hive.box('sanctum_finance__v3').values.cast<String>(),
    ].join('\n');

    for (final secret in const [
      'bank.invalid', 'jsmith', 'hunter2', 'my day', 'dear diary',
      '4321.99', 'groceries',
    ]) {
      expect(blobs.contains(secret), isFalse, reason: 'plaintext "$secret" leaked');
    }
    // The record id keys remain plaintext (Hive keys) — that is the only
    // permitted plaintext (supplement §7).
    expect(Hive.box('sanctum_passwords__v3').keys, contains('pw-1'));
  });
}

Uint8List _saltBytes(String b64) => Uint8List.fromList(base64.decode(b64));

Future<void> _seedV2Vault() async {
  final salt = cryptoService.generateSalt();
  final key = await cryptoService.deriveKey(_pw, salt);
  final vh = await cryptoService.makeVerifyHash(key);

  await Hive.box<PasswordEntry>('sanctum_passwords').put(
    'pw-1',
    PasswordEntry(
      id: 'pw-1',
      site: await cryptoService.encrypt('bank.invalid', key),
      username: await cryptoService.encrypt('jsmith', key),
      encryptedPassword: await cryptoService.encrypt('hunter2', key),
      notes: '',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    ),
  );
  await Hive.box<DiaryEntry>('sanctum_diary').put(
    'd-1',
    DiaryEntry(
      id: 'd-1',
      title: await cryptoService.encrypt('my day', key),
      encryptedContent: await cryptoService.encrypt('dear diary', key),
      mood: await cryptoService.encrypt('calm', key),
      tags: const ['personal'],
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    ),
  );
  await Hive.box<FinanceRecord>('sanctum_finance').put(
    'f-1',
    FinanceRecord(
      id: 'f-1',
      type: await cryptoService.encrypt('expense', key),
      amount: 4321.99,
      category: await cryptoService.encrypt('groceries', key),
      description: await cryptoService.encrypt('weekly shop', key),
      date: DateTime(2026, 1, 3),
      createdAt: DateTime(2026, 1, 3),
      currency: 'HKD',
    ),
  );
  await Hive.box<VaultMeta>('sanctum_meta').put(
    'meta',
    VaultMeta(
      salt: base64.encode(salt), verifyHash: vh,
      createdAt: DateTime(2026, 1, 1), lastUnlocked: DateTime(2026, 1, 1),
      version: 'v2',
    ),
  );
  _secure['vault_salt'] = base64.encode(salt);
  _secure['vault_enc_v2'] = 'done';
}

Future<void> _wipe() async {
  vaultService.lock();
  await Hive.box<PasswordEntry>('sanctum_passwords').clear();
  await Hive.box<DiaryEntry>('sanctum_diary').clear();
  await Hive.box<FinanceRecord>('sanctum_finance').clear();
  await Hive.box<String>('sanctum_images').clear();
  await Hive.box('sanctum_image_index').clear();
  await Hive.box<VaultMeta>('sanctum_meta').clear();
  await (await Hive.openBox('sanctum_vault_v3')).clear();
  for (final name in const [
    'sanctum_passwords__v3', 'sanctum_diary__v3', 'sanctum_finance__v3',
    'sanctum_images__v3', 'sanctum_image_index__v3',
  ]) {
    await (await Hive.openBox(name)).clear();
    await (await Hive.openBox('${name}__staging')).clear();
  }
  await (await Hive.openBox('sanctum_migration_journal')).clear();
  _secure.clear();
}
