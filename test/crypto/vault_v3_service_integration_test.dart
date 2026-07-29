// Real-VaultService integration regression (DEV-P0-03 B2-5a).
// Adopted from the QA acceptance harness per the B2-5a approval ruling
// (DEV-P0-03-B2-5a-批核決定-及-B2-5b-開放-v1): it drives the REAL VaultService
// end-to-end — including the actual meta.version branch in unlock() — by mocking
// the path_provider + flutter_secure_storage platform channels so
// Hive.initFlutter() runs under `flutter test`. Synthetic data only.
//
// Covers the RETURN-level guarantees for B2-5a:
//   * v2 unlock ZERO REGRESSION — a pre-existing v2 vault is routed to the
//     untouched v2 path and still unlocks/decrypts (disaster-if-broken case);
//   * v3 DEK round-trip through the real create/unlock;
//   * V-08 recovery live service (enableV3Recovery/recoverV3), v3-only, fail-closed.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart'; // also provides Uint8List
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:sanctum/core/crypto/crypto_service.dart';
import 'package:sanctum/core/models/models.dart';
import 'package:sanctum/core/storage/vault_service.dart';

final Map<String, String> _secure = {};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('b2_5a_svc_');
    // path_provider: Hive.initFlutter() asks for the documents directory.
    const pp = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pp, (c) async => tmp.path);
    // flutter_secure_storage: in-memory map.
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

  setUp(() async {
    await _wipe();
  });

  // ── RETURN #1: v3 DEK round-trip through the REAL VaultService ──────────────
  group('v3 DEK round-trip (real VaultService)', () {
    test('create(v3) -> add -> lock -> unlock -> record decrypts; version==v3',
        () async {
      await vaultService.createVault('correct horse battery staple');
      expect(Hive.box<VaultMeta>('sanctum_meta').get('meta')!.version, 'v3');

      await vaultService.addPassword(
          site: 'sentinel.invalid', username: 'me', password: 's3cr3t');
      vaultService.lock();
      expect(vaultService.isUnlocked, isFalse);

      final ok = await vaultService.unlock('correct horse battery staple');
      expect(ok, isTrue);
      final pws = await vaultService.getPasswords();
      expect(pws.single.site, 'sentinel.invalid');
      expect(await vaultService.decryptPassword(pws.single), 's3cr3t');
    });

    test('wrong password fails closed (returns false, stays locked)', () async {
      await vaultService.createVault('right-password');
      vaultService.lock();
      final bad = await vaultService.unlock('wrong-password');
      expect(bad, isFalse);
      expect(vaultService.isUnlocked, isFalse);
    });
  });

  // ── RETURN #2: v2 unlock ZERO REGRESSION (the disaster-if-broken case) ──────
  // Construct a PRE-EXISTING v2 vault exactly as pre-B2-5a createVault did, then
  // unlock it through the REAL (now version-branching) unlock(). Proves a v2
  // vault is routed to the untouched v2 path, not the v3 DEK path.
  group('v2 unlock zero regression (real VaultService branch)', () {
    Future<String> seedV2Vault(String password, String secret) async {
      final salt = cryptoService.generateSalt();
      final key = await cryptoService.deriveKey(password, salt);
      final vh = await cryptoService.makeVerifyHash(key);
      final encPass = await cryptoService.encrypt(secret, key);
      final saltB64 = base64.encode(salt);

      await Hive.box<PasswordEntry>('sanctum_passwords').put(
        'v2-pw',
        PasswordEntry(
          id: 'v2-pw',
          site: await cryptoService.encrypt('v2.invalid', key),
          username: await cryptoService.encrypt('legacy-user', key),
          encryptedPassword: encPass,
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        ),
      );
      await Hive.box<VaultMeta>('sanctum_meta').put(
        'meta',
        VaultMeta(
          salt: saltB64,
          verifyHash: vh,
          createdAt: DateTime(2026, 1, 1),
          lastUnlocked: DateTime(2026, 1, 1),
          version: 'v2',
        ),
      );
      _secure['vault_salt'] = saltB64;
      _secure['vault_enc_v2'] = 'done';
      return saltB64;
    }

    test('existing v2 vault still unlocks + decrypts (correct pw)', () async {
      await seedV2Vault('legacy-master', 'legacy-secret');
      vaultService.lock();

      final ok = await vaultService.unlock('legacy-master');
      expect(ok, isTrue, reason: 'v2 vault failed to unlock — branch regression');
      final pws = await vaultService.getPasswords();
      expect(await vaultService.decryptPassword(pws.single), 'legacy-secret',
          reason: 'existing v2 record did not survive/decrypt');
    });

    test('existing v2 vault rejects wrong pw (fail-closed, no v3 misroute)',
        () async {
      await seedV2Vault('legacy-master', 'legacy-secret');
      vaultService.lock();
      expect(await vaultService.unlock('wrong'), isFalse);
      expect(vaultService.isUnlocked, isFalse);
    });
  });

  // ── V-08 live recovery service through the REAL VaultService (v3 only) ───────
  group('V-08 recovery live service (real VaultService)', () {
    test('enableV3Recovery -> recoverV3 -> new pw unlocks, old pw dead, data kept',
        () async {
      await vaultService.createVault('old-password');
      await vaultService.addPassword(
          site: 'keep.invalid', username: 'u', password: 'keep-me');
      final shares = await vaultService.enableV3Recovery('old-password', n: 5, k: 3);
      expect(shares, hasLength(5));

      vaultService.lock();
      await vaultService.recoverV3(shares.take(3).toList(), 'brand-new-pw');

      // New password unlocks; the DEK (hence data) is preserved across recovery.
      final pws = await vaultService.getPasswords();
      expect(await vaultService.decryptPassword(pws.single), 'keep-me');
      vaultService.lock();
      expect(await vaultService.unlock('brand-new-pw'), isTrue);
      expect(await vaultService.unlock('old-password'), isFalse);
    });

    test('insufficient shares -> fail-closed throw (no reset)', () async {
      await vaultService.createVault('pw');
      final shares = await vaultService.enableV3Recovery('pw', n: 5, k: 3);
      await expectLater(
        vaultService.recoverV3(shares.take(2).toList(), 'x'),
        throwsA(anything),
      );
    });

    test('tampered share -> fail-closed throw', () async {
      await vaultService.createVault('pw');
      final shares = await vaultService.enableV3Recovery('pw', n: 5, k: 3);
      final bad = Uint8List.fromList(shares[0]);
      bad[bad.length - 8] ^= 0xFF; // corrupt inside payload/crc region
      await expectLater(
        vaultService.recoverV3([bad, shares[1], shares[2]], 'x'),
        throwsA(anything),
      );
    });

    test('enableV3Recovery with wrong password fails closed', () async {
      await vaultService.createVault('right');
      await expectLater(
        vaultService.enableV3Recovery('wrong', n: 5, k: 3),
        throwsA(anything),
      );
    });

    test('recovery ops on a v2 vault throw StateError (v3-only feature)',
        () async {
      // Seed a v2 vault, then attempt a v3-only recovery op.
      await Hive.box<VaultMeta>('sanctum_meta').put(
        'meta',
        VaultMeta(
          salt: 'x', verifyHash: 'y',
          createdAt: DateTime(2026, 1, 1), lastUnlocked: DateTime(2026, 1, 1),
          version: 'v2',
        ),
      );
      await expectLater(
        vaultService.enableV3Recovery('whatever'),
        throwsA(isA<StateError>()),
      );
    });
  });
}

// Reset all live boxes + secure storage + session between tests. Boxes opened by
// VaultService.init() are typed, so they must be cleared through their real type.
Future<void> _wipe() async {
  vaultService.lock();
  await Hive.box<PasswordEntry>('sanctum_passwords').clear();
  await Hive.box<DiaryEntry>('sanctum_diary').clear();
  await Hive.box<FinanceRecord>('sanctum_finance').clear();
  await Hive.box<String>('sanctum_images').clear();
  await Hive.box('sanctum_image_index').clear(); // opened untyped by init()
  await Hive.box<VaultMeta>('sanctum_meta').clear();
  final v3 = Hive.isBoxOpen('sanctum_vault_v3')
      ? Hive.box('sanctum_vault_v3')
      : await Hive.openBox('sanctum_vault_v3');
  await v3.clear();
  // B2-5b: also clear the v3 record boxes (+ staging) and the migration journal,
  // otherwise auto-migration leaves state that contaminates the next test.
  for (final name in const [
    'sanctum_passwords__v3',
    'sanctum_diary__v3',
    'sanctum_finance__v3',
    'sanctum_images__v3',
    'sanctum_image_index__v3',
  ]) {
    await (await Hive.openBox(name)).clear();
    await (await Hive.openBox('${name}__staging')).clear();
  }
  await (await Hive.openBox('sanctum_migration_journal')).clear();
  _secure.clear();
}
