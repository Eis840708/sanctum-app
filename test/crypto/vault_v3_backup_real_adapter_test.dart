// Real-VaultService v3 backup round-trip regression (DEV-P0-03-UI 子項 A, RETURN).
// Drives the REAL VaultService end-to-end (real Hive + mocked platform channels),
// proving the release-blocking guarantee: a v3 vault exports a restorable backup,
// and a NEW DEVICE (all local state wiped — records, v3 material, secure storage)
// rebuilds every field from only the backup blob + the master password.
//
// Covers §六.1:
//   * export -> (new-device) restore -> every field identical, version==v3;
//   * wrong password / tampered container rejected fail-closed;
//   * exported bytes carry NO synthetic plaintext (raw scan);
//   * restore interrupted at commit-intent resumes forward at the next unlock;
//   * v2 vault export/unlock path unaffected (zero regression).
// Synthetic data only.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:sanctum/core/crypto/crypto_service.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_backup.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_migrate.dart';
import 'package:sanctum/core/models/models.dart';
import 'package:sanctum/core/storage/vault_service.dart';

final Map<String, String> _secure = {};

// Synthetic secrets — must NOT appear in the exported bytes.
const _site = 'sentinel-site.invalid';
const _user = 'sentinel-user';
const _pass = 'sentinel-P@ssw0rd-9931';
const _diaryTitle = 'sentinel-diary-title';
const _diaryBody = 'sentinel-diary-body-xyzzy';
const _finDesc = 'sentinel-finance-desc';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final backup = VaultV3Backup();

  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('ui_a_backup_');
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

  Future<void> seedV3(String pw) async {
    await vaultService.createVault(pw);
    await vaultService.addPassword(site: _site, username: _user, password: _pass);
    await vaultService.addDiaryEntry(
        title: _diaryTitle, content: _diaryBody, mood: 'ok', tags: ['t1', 't2']);
    await vaultService.addFinanceRecord(
        type: 'expense',
        amount: 42.5,
        category: 'food',
        description: _finDesc,
        date: DateTime(2026, 5, 1));
  }

  Future<Map<String, dynamic>> snapshot() async {
    final pws = await vaultService.getPasswords();
    final diary = await vaultService.getDiaryEntries();
    final fin = await vaultService.getFinanceRecords();
    return {
      'pw': [
        for (final p in pws)
          {
            's': p.site,
            'u': p.username,
            'p': await vaultService.decryptPassword(p),
          }
      ],
      'di': [
        for (final d in diary)
          {
            't': d.title,
            'c': await vaultService.decryptDiaryContent(d),
            'tags': d.tags,
          }
      ],
      'fi': [
        for (final f in fin)
          {'d': f.description, 'a': f.amount, 'c': f.category}
      ],
    };
  }

  group('RETURN: v3 backup round-trip (new-device restore)', () {
    test('export -> wipe device -> restore -> every field identical; v3', () async {
      await seedV3('correct horse battery staple');
      final before = await snapshot();
      final bytes = await vaultService.exportVaultV3Backup();

      // Simulate a brand-new device: nothing but the backup blob survives.
      await _wipe();
      expect(vaultService.hasVault, isFalse);

      await vaultService.importV3Backup(bytes,
          masterPassword: 'correct horse battery staple');
      expect(Hive.box<VaultMeta>('sanctum_meta').get('meta')!.version, 'v3');

      final after = await snapshot();
      expect(after, equals(before));

      // And it persists across a lock/unlock cycle on the "new device".
      vaultService.lock();
      expect(await vaultService.unlock('correct horse battery staple'), isTrue);
      expect(await snapshot(), equals(before));
    });

    test('wrong password on restore is rejected fail-closed', () async {
      await seedV3('right-pw');
      final bytes = await vaultService.exportVaultV3Backup();
      await _wipe();

      await expectLater(
        vaultService.importV3Backup(bytes, masterPassword: 'wrong-pw'),
        throwsA(anything),
      );
      // Nothing was created.
      expect(Hive.box<VaultMeta>('sanctum_meta').get('meta'), isNull);
      expect(Hive.box('sanctum_passwords__v3').isEmpty, isTrue);
    });

    test('tampered container is rejected before any live mutation', () async {
      await seedV3('pw');
      final bytes = await vaultService.exportVaultV3Backup();
      await _wipe();

      final tampered = Uint8List.fromList(bytes);
      tampered[tampered.length - 1] ^= 0xFF; // corrupt the outer tag
      await expectLater(
        vaultService.importV3Backup(tampered, masterPassword: 'pw'),
        throwsA(anything),
      );
      expect(Hive.box<VaultMeta>('sanctum_meta').get('meta'), isNull);
      expect(Hive.box('sanctum_passwords__v3').isEmpty, isTrue);
    });
  });

  group('RETURN: zero plaintext in the exported blob', () {
    test('no synthetic secret appears in the raw backup bytes', () async {
      await seedV3('pw');
      final bytes = await vaultService.exportVaultV3Backup();
      final haystack = utf8.decode(bytes, allowMalformed: true);
      for (final needle in const [
        _site, _user, _pass, _diaryTitle, _diaryBody, _finDesc,
      ]) {
        expect(haystack.contains(needle), isFalse,
            reason: 'plaintext "$needle" leaked into the backup');
      }
      // Sanity: the container really is a v3 backup.
      expect(VaultV3Backup.isBackupV3(bytes), isTrue);
    });
  });

  group('RETURN: restore interrupted at commit-intent resumes forward', () {
    test('staged + commitIntent journal -> unlock replays -> data intact', () async {
      // Produce a real backup, capture its decoded staging inputs, wipe device.
      await seedV3('resume-pw');
      final before = await snapshot();
      final bytes = await vaultService.exportVaultV3Backup();
      final header = backup.parseHeader(bytes);
      final keys =
          await backup.deriveKeys(password: 'resume-pw', material: header.material);
      final recordsByBox =
          await backup.decodeBody(bytes: bytes, header: header, backupKey: keys.backupKey);
      await _wipe();

      // Simulate a crash AFTER the point of no return: staging fully written +
      // journal at commitIntent + pending material, but live not yet swapped.
      for (final e in recordsByBox.entries) {
        final s = await Hive.openBox('${e.key}__staging');
        for (final r in e.value.entries) {
          await s.put(r.key, r.value);
        }
      }
      final journal = await Hive.openBox('sanctum_backup_restore_journal');
      await journal.put('material', header.material.encode());
      await journal.put('phase', MigrationPhase.commitIntent.name);

      // The next unlock must resume the restore forward, then unlock the v3 vault.
      final ok = await vaultService.unlock('resume-pw');
      expect(ok, isTrue);
      expect(Hive.box<VaultMeta>('sanctum_meta').get('meta')!.version, 'v3');
      expect(await snapshot(), equals(before));
    });
  });

  group('RETURN: rejected restore leaves an EXISTING vault intact (V-01/V-02)', () {
    // Distinct from the fresh-device negatives above: here a DIFFERENT populated
    // vault is already on the device and MUST survive a rejected import (no
    // clear-before-validate). Folded in from the QA acceptance harness.
    late Uint8List blob;
    setUp(() async {
      await vaultService.createVault('backup-owner-pw');
      await vaultService.addPassword(
          site: 'src.invalid', username: 'u', password: 'p');
      blob = await vaultService.exportVaultV3Backup();
      await _wipe();
      await vaultService.createVault('existing-device-pw');
      await vaultService.addPassword(
          site: 'existing.invalid', username: 'keep', password: 'do-not-lose');
      vaultService.lock();
    });

    Future<void> expectExistingIntact() async {
      expect(await vaultService.unlock('existing-device-pw'), isTrue);
      final pws = await vaultService.getPasswords();
      expect(pws.single.site, 'existing.invalid');
      expect(await vaultService.decryptPassword(pws.single), 'do-not-lose');
    }

    test('wrong password -> throws, existing vault intact', () async {
      await vaultService.unlock('existing-device-pw');
      await expectLater(
        vaultService.importV3Backup(blob, masterPassword: 'WRONG'),
        throwsA(anything),
      );
      vaultService.lock();
      await expectExistingIntact();
    });

    test('tampered body -> throws, existing vault intact', () async {
      final bad = Uint8List.fromList(blob);
      bad[bad.length - 1] ^= 0xFF;
      await vaultService.unlock('existing-device-pw');
      await expectLater(
        vaultService.importV3Backup(bad, masterPassword: 'backup-owner-pw'),
        throwsA(anything),
      );
      vaultService.lock();
      await expectExistingIntact();
    });

    test('truncated container -> throws, existing vault intact', () async {
      final cut = Uint8List.sublistView(blob, 0, blob.length ~/ 2);
      await vaultService.unlock('existing-device-pw');
      await expectLater(
        vaultService.importV3Backup(cut, masterPassword: 'backup-owner-pw'),
        throwsA(anything),
      );
      vaultService.lock();
      await expectExistingIntact();
    });
  });

  group('zero regression: v2 vault unaffected', () {
    test('a pre-existing v2 vault still unlocks + decrypts', () async {
      // Seed a v2 vault exactly as the legacy path did (no v3 material).
      final salt = cryptoService.generateSalt();
      final key = await cryptoService.deriveKey('legacy-master', salt);
      final vh = await cryptoService.makeVerifyHash(key);
      await Hive.box<PasswordEntry>('sanctum_passwords').put(
        'v2-pw',
        PasswordEntry(
          id: 'v2-pw',
          site: await cryptoService.encrypt('v2.invalid', key),
          username: await cryptoService.encrypt('legacy-user', key),
          encryptedPassword: await cryptoService.encrypt('legacy-secret', key),
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
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
      _secure['vault_salt'] = base64.encode(salt);
      _secure['vault_enc_v2'] = 'done';
      vaultService.lock();

      // A v2 vault auto-migrates to v3 on unlock (B2-5b); it must still unlock and
      // the record must survive — the backup wiring must not disturb this path.
      final ok = await vaultService.unlock('legacy-master');
      expect(ok, isTrue);
      final pws = await vaultService.getPasswords();
      expect(await vaultService.decryptPassword(pws.single), 'legacy-secret');
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
  final v3 = Hive.isBoxOpen('sanctum_vault_v3')
      ? Hive.box('sanctum_vault_v3')
      : await Hive.openBox('sanctum_vault_v3');
  await v3.clear();
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
  await (await Hive.openBox('sanctum_backup_restore_journal')).clear();
  _secure.clear();
}
