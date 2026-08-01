// Service + encoding-boundary regression for the v3 UI wiring (DEV-P0-03-UI B+C).
// Drives the REAL VaultService through the exact call sequences and transforms
// the backup/recovery UI performs, so the thin widgets sit on a proven boundary:
//   * backup_screen:  isV3Vault -> exportVaultV3Backup / importV3Backup
//   * shamir_screen:  enableV3Recovery -> base64 (display) -> base64 (input)
//                     -> recoverV3 -> new password unlocks, old fails
// Synthetic data only.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:sanctum/core/models/models.dart';
import 'package:sanctum/core/storage/vault_service.dart';

final Map<String, String> _secure = {};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('ui_bc_');
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

  setUp(() async => _wipe());

  // ── isV3Vault getter (backup/shamir UI branch selector) ─────────────────────
  group('isV3Vault', () {
    test('false with no vault, true after v3 create', () async {
      expect(vaultService.hasVault, isFalse);
      expect(vaultService.isV3Vault, isFalse);
      await vaultService.createVault('correct horse battery staple');
      expect(vaultService.isV3Vault, isTrue);
    });

    test('false for a seeded v2 vault', () async {
      await Hive.box<VaultMeta>('sanctum_meta').put(
        'meta',
        VaultMeta(
          salt: 'x', verifyHash: 'y',
          createdAt: DateTime(2026, 1, 1), lastUnlocked: DateTime(2026, 1, 1),
          version: 'v2',
        ),
      );
      expect(vaultService.isV3Vault, isFalse);
    });
  });

  // ── backup_screen call sequence: export -> import round-trip ────────────────
  group('backup UI call sequence', () {
    test('isV3Vault -> exportVaultV3Backup -> wipe -> importV3Backup restores',
        () async {
      await vaultService.createVault('master-pw-123456');
      await vaultService.addPassword(site: 's.invalid', username: 'u', password: 'secret-1');
      expect(vaultService.isV3Vault, isTrue);
      final bytes = await vaultService.exportVaultV3Backup();

      await _wipe();
      await vaultService.importV3Backup(bytes, masterPassword: 'master-pw-123456');
      final pws = await vaultService.getPasswords();
      expect(await vaultService.decryptPassword(pws.single), 'secret-1');
    });

    test('wrong password throws (UI maps to one message) + existing vault lives',
        () async {
      await vaultService.createVault('backup-pw-123456');
      await vaultService.addPassword(site: 'src.invalid', username: 'u', password: 'p');
      final bytes = await vaultService.exportVaultV3Backup();
      await _wipe();
      await vaultService.createVault('existing-pw-123456');
      await vaultService.addPassword(site: 'keep.invalid', username: 'k', password: 'do-not-lose');
      vaultService.lock();

      await vaultService.unlock('existing-pw-123456');
      await expectLater(
        vaultService.importV3Backup(bytes, masterPassword: 'WRONG-PASSWORD'),
        throwsA(anything),
      );
      vaultService.lock();
      expect(await vaultService.unlock('existing-pw-123456'), isTrue);
      final pws = await vaultService.getPasswords();
      expect(await vaultService.decryptPassword(pws.single), 'do-not-lose');
    });
  });

  // ── shamir_screen recovery: base64 display/input boundary + recoverV3 ───────
  group('recovery UI base64 boundary', () {
    test('enable -> base64 encode/decode -> recoverV3 -> new pw unlocks, old fails',
        () async {
      await vaultService.createVault('old-pw-123456');
      await vaultService.addPassword(site: 'keep.invalid', username: 'u', password: 'keep-me');

      // _V3GenerateTab: shares are base64-encoded for display/export.
      final shares = await vaultService.enableV3Recovery('old-pw-123456', n: 5, k: 3);
      final displayed = shares.map(base64Encode).toList();

      // _V3RecoverTab: user pastes base64 codes; we decode them back.
      final pasted = displayed.take(3).map(base64Decode).toList();
      await vaultService.recoverV3(pasted, 'brand-new-pw-123456');

      // Data preserved; new password unlocks; old password is dead.
      final pws = await vaultService.getPasswords();
      expect(await vaultService.decryptPassword(pws.single), 'keep-me');
      vaultService.lock();
      expect(await vaultService.unlock('brand-new-pw-123456'), isTrue);
      expect(await vaultService.unlock('old-pw-123456'), isFalse);
    });

    test('tampered base64 share -> recoverV3 throws (UI merges to one message)',
        () async {
      await vaultService.createVault('pw-123456789');
      final shares = await vaultService.enableV3Recovery('pw-123456789', n: 5, k: 3);
      final displayed = shares.map(base64Encode).toList();
      final pasted = displayed.take(3).map(base64Decode).toList();
      pasted[0] = Uint8List.fromList(pasted[0])..[pasted[0].length - 6] ^= 0xFF;
      await expectLater(
        vaultService.recoverV3(pasted, 'new-pw-123456'),
        throwsA(anything),
      );
    });

    test('insufficient shares -> recoverV3 throws', () async {
      await vaultService.createVault('pw-123456789');
      final shares = await vaultService.enableV3Recovery('pw-123456789', n: 5, k: 3);
      final pasted =
          shares.map(base64Encode).take(2).map(base64Decode).toList();
      await expectLater(
        vaultService.recoverV3(pasted, 'new-pw-123456'),
        throwsA(anything),
      );
    });
  });
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
  for (final n in const [
    'sanctum_passwords__v3', 'sanctum_diary__v3', 'sanctum_finance__v3',
    'sanctum_images__v3', 'sanctum_image_index__v3',
  ]) {
    await (await Hive.openBox(n)).clear();
    await (await Hive.openBox('${n}__staging')).clear();
  }
  await (await Hive.openBox('sanctum_migration_journal')).clear();
  await (await Hive.openBox('sanctum_backup_restore_journal')).clear();
  _secure.clear();
}
