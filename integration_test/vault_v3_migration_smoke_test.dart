// On-device REAL-BUILD v2->v3 migration smoke (DEV-P0-03 Alpha packaging P-5(i)).
//
// Seeds a synthetic EXISTING v2 vault using the REAL v2 format — the same Hive
// typed adapters (PasswordEntry/DiaryEntry/FinanceRecord/VaultMeta) and the real
// cryptoService (PBKDF2 + AES-GCM) that the pre-B2-5a app wrote (director
// condition C1: reuse the B2-5b real-adapter seed, not a hand-built shape). Then
// drives the REAL VaultService end-to-end on a physical device:
//   unlock -> auto-migrate to v3 -> data intact -> re-lock/unlock.
//
// Run on a device in PROFILE (== release migration code path; lib/core has no
// build-mode branch, so this is a faithful proxy for the signed build's
// migration — see P-5 evidence file for the residual-gap statement):
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/vault_v3_migration_smoke_test.dart --profile -d <dev>
//
// Synthetic data only.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:integration_test/integration_test.dart';

import 'package:sanctum/core/crypto/crypto_service.dart';
import 'package:sanctum/core/models/models.dart';
import 'package:sanctum/core/storage/vault_service.dart';

const String _pw = 'legacy-master-smoke';

// Real-adapter v2 seed, adapted from test/crypto/vault_v3_migrate_interrupt_test
// _seedV2Vault (real Hive adapters + real cryptoService; VaultMeta version 'v2').
// Secure-storage salt is intentionally omitted: unlock falls back to meta.salt
// and re-populates secure storage on the real device.
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
      salt: base64.encode(salt),
      verifyHash: vh,
      createdAt: DateTime(2026, 1, 1),
      lastUnlocked: DateTime(2026, 1, 1),
      version: 'v2',
    ),
  );
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await vaultService.init();
  });

  testWidgets('real v2 vault -> unlock auto-migrates to v3 -> data intact -> '
      're-lock/unlock', (tester) async {
    await vaultService.clearVault();
    await _seedV2Vault();
    expect(Hive.box<VaultMeta>('sanctum_meta').get('meta')!.version, 'v2',
        reason: 'seed must be a real v2 vault before migration');

    // Unlock the v2 vault: this triggers the transactional auto-migration to v3.
    final ok = await vaultService.unlock(_pw);
    expect(ok, isTrue, reason: 'v2 unlock failed');
    expect(vaultService.isV3Vault, isTrue,
        reason: 'vault did not migrate to v3 on unlock');

    // Data survived the migration.
    final pws = await vaultService.getPasswords();
    expect(await vaultService.decryptPassword(pws.single), 'hunter2');
    final diary = await vaultService.getDiaryEntries();
    expect(await vaultService.decryptDiaryContent(diary.single), 'dear diary');

    // Re-lock / unlock round-trip on the now-v3 vault.
    vaultService.lock();
    expect(vaultService.isUnlocked, isFalse);
    expect(await vaultService.unlock(_pw), isTrue);
    expect(vaultService.isV3Vault, isTrue);
    expect(
        await vaultService.decryptPassword((await vaultService.getPasswords()).single),
        'hunter2');

    debugPrint('[migration-smoke] PASS: v2 -> v3 auto-migration, data intact, '
        're-lock/unlock ok');
    binding.reportData = <String, dynamic>{
      'migration_smoke': <String, Object?>{
        'migrated_to_v3': vaultService.isV3Vault,
        'password_ok': true,
        'diary_ok': true,
      }
    };

    await vaultService.clearVault();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
