// Real-VaultService integration for the V-05 biometric service wiring
// (DEV-P0-03 B2-5a-native stage 1b-iii). Drives the REAL VaultService
// (enableV3Biometric / unlockV3WithBiometric / disableV3Biometric /
// hasV3Biometric) with path_provider + flutter_secure_storage mocked so
// Hive.initFlutter() runs under `flutter test`, and the native
// 'com.sanctum.vault/keyauth' channel replaced by an in-memory fake KeyStore
// (keyed by vaultId) that round-trips the DEK. Synthetic data only; no device,
// no real biometric.
//
// On-device RETURN (real BiometricPrompt/KeyStore, enrollment-invalidation,
// no-hardware fallback) is the integration_test, run on a device by Eis.
import 'dart:io';

import 'package:flutter/services.dart'; // also provides Uint8List
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:sanctum/core/crypto/v3/vault_v3_biometric.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_keys.dart';
import 'package:sanctum/core/models/models.dart';
import 'package:sanctum/core/storage/vault_service.dart';

final Map<String, String> _secure = {};

/// In-memory fake of the native KeyStore: vaultId(hex) -> DEK. Mirrors the
/// hardware contract (the key is bound to the vault; the blob is opaque).
final Map<String, List<int>> _hw = {};
final List<String> _keyauthCalls = [];

/// When true, the fake unlock raises the distinct "key-invalidated" error the
/// native side returns after a new biometric enrollment invalidates the key.
bool _simulateInvalidated = false;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('b2_5a_bio_svc_');
    const pp = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(pp, (c) async => tmp.path);
    const ss = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    messenger.setMockMethodCallHandler(ss, (c) async {
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
    // Fake native key-auth channel.
    const ka = MethodChannel('com.sanctum.vault/keyauth');
    messenger.setMockMethodCallHandler(ka, (c) async {
      _keyauthCalls.add(c.method);
      final a = (c.arguments as Map?)?.cast<String, Object?>() ?? {};
      switch (c.method) {
        case 'capability':
          return <String, Object?>{
            'available': true,
            'strongBox': false,
            'insideSecureHardware': true,
            'reason': null,
          };
        case 'enroll':
          final vaultId = a['vaultId']! as Uint8List;
          final dek = a['dek']! as Uint8List;
          _hw[_hex(vaultId)] = List<int>.from(dek);
          return Uint8List.fromList(List<int>.filled(60, 0xAB)); // opaque blob
        case 'unlock':
          if (_simulateInvalidated) {
            throw PlatformException(code: 'key-invalidated');
          }
          final vaultId = a['vaultId']! as Uint8List;
          final dek = _hw[_hex(vaultId)];
          if (dek == null) {
            throw PlatformException(code: 'no-key');
          }
          return Uint8List.fromList(dek);
        case 'disable':
          final vaultId = a['vaultId']! as Uint8List;
          _hw.remove(_hex(vaultId));
          return true;
        default:
          return null;
      }
    });
    await vaultService.init();
  });

  setUp(() async {
    _secure.clear();
    _hw.clear();
    _keyauthCalls.clear();
    _simulateInvalidated = false;
    vaultService.lock();
    if (Hive.isBoxOpen('sanctum_meta')) {
      await Hive.box<VaultMeta>('sanctum_meta').clear();
    }
    if (Hive.isBoxOpen('sanctum_passwords')) {
      await Hive.box<PasswordEntry>('sanctum_passwords').clear();
    }
    if (Hive.isBoxOpen('sanctum_diary')) {
      await Hive.box<DiaryEntry>('sanctum_diary').clear();
    }
    if (Hive.isBoxOpen('sanctum_finance')) {
      await Hive.box<FinanceRecord>('sanctum_finance').clear();
    }
    if (Hive.isBoxOpen('sanctum_images')) {
      await Hive.box<String>('sanctum_images').clear();
    }
    if (Hive.isBoxOpen('sanctum_image_index')) {
      await Hive.box('sanctum_image_index').clear();
    }
    await (await Hive.openBox('sanctum_vault_v3')).clear();
    // v3 full-record-encrypted data lives in separate *__v3 boxes; clear them
    // too so a prior test's records (under a different DEK) never leak in.
    for (final name in const [
      'sanctum_passwords__v3',
      'sanctum_diary__v3',
      'sanctum_finance__v3',
      'sanctum_images__v3',
      'sanctum_image_index__v3',
    ]) {
      await (await Hive.openBox(name)).clear();
    }
  });

  group('enable / hasV3Biometric', () {
    test('enable adds hw-bio wrap; password still unlocks; data intact',
        () async {
      await vaultService.createVault('correct horse battery staple');
      await vaultService.addPassword(
          site: 'sentinel.invalid', username: 'me', password: 's3cr3t');
      expect(await vaultService.hasV3Biometric, isFalse);

      await vaultService.enableV3Biometric('correct horse battery staple');
      expect(await vaultService.hasV3Biometric, isTrue);
      expect(_keyauthCalls, contains('enroll'));

      // password wrap untouched -> password still unlocks and data survives.
      vaultService.lock();
      expect(await vaultService.unlock('correct horse battery staple'), isTrue);
      final pws = await vaultService.getPasswords();
      expect(await vaultService.decryptPassword(pws.single), 's3cr3t');
    });

    test('wrong password on enable throws, no wrap persisted', () async {
      await vaultService.createVault('right-password');
      await expectLater(
        vaultService.enableV3Biometric('wrong-password'),
        throwsA(isA<VaultV3KeyException>()),
      );
      expect(await vaultService.hasV3Biometric, isFalse);
    });

    test('hasV3Biometric is false with no v3 vault', () async {
      expect(await vaultService.hasV3Biometric, isFalse);
    });
  });

  group('biometric unlock round-trip', () {
    test('enable -> lock -> unlockV3WithBiometric -> data decrypts', () async {
      await vaultService.createVault('pw-alpha');
      await vaultService.addPassword(
          site: 'bio.invalid', username: 'u', password: 'top-secret');
      await vaultService.enableV3Biometric('pw-alpha');
      vaultService.lock();
      expect(vaultService.isUnlocked, isFalse);

      await vaultService.unlockV3WithBiometric();
      expect(vaultService.isUnlocked, isTrue);
      final pws = await vaultService.getPasswords();
      expect(pws.single.site, isNotEmpty);
      expect(await vaultService.decryptPassword(pws.single), 'top-secret');
    });

    test('session key equals the password-unlock session (same DEK)', () async {
      await vaultService.createVault('pw-beta');
      await vaultService.addPassword(
          site: 's.invalid', username: 'u', password: 'v');
      await vaultService.enableV3Biometric('pw-beta');

      // password path
      vaultService.lock();
      await vaultService.unlock('pw-beta');
      final viaPw =
          await vaultService.decryptPassword((await vaultService.getPasswords()).single);
      // biometric path
      vaultService.lock();
      await vaultService.unlockV3WithBiometric();
      final viaBio =
          await vaultService.decryptPassword((await vaultService.getPasswords()).single);
      expect(viaBio, viaPw);
    });
  });

  group('fail-closed', () {
    test('unlockV3WithBiometric without enrollment throws, stays locked',
        () async {
      await vaultService.createVault('pw');
      vaultService.lock();
      await expectLater(
        vaultService.unlockV3WithBiometric(),
        throwsA(isA<VaultV3BiometricException>()),
      );
      expect(vaultService.isUnlocked, isFalse);
    });

    test('native no-key on unlock -> VaultV3BiometricException', () async {
      await vaultService.createVault('pw');
      await vaultService.enableV3Biometric('pw');
      _hw.clear(); // simulate invalidated / wiped hardware key
      vaultService.lock();
      await expectLater(
        vaultService.unlockV3WithBiometric(),
        throwsA(isA<VaultV3BiometricException>()),
      );
      expect(vaultService.isUnlocked, isFalse);
    });

    test('enrollment-invalidation (key-invalidated) -> fail-closed, distinct '
        'signal, password recovers', () async {
      await vaultService.createVault('pw');
      await vaultService.addPassword(
          site: 's.invalid', username: 'u', password: 'sec');
      await vaultService.enableV3Biometric('pw');
      _simulateInvalidated = true; // new biometric enrolled -> key dead
      vaultService.lock();

      Object? err;
      try {
        await vaultService.unlockV3WithBiometric();
      } catch (e) {
        err = e;
      }
      expect(err, isA<VaultV3BiometricException>());
      // distinct signal surfaced (not a generic keystore error).
      expect(err.toString(), contains('key-invalidated'));
      expect(vaultService.isUnlocked, isFalse);

      // Fail-closed recovery: master password still unlocks + data intact.
      expect(await vaultService.unlock('pw'), isTrue);
      final pws = await vaultService.getPasswords();
      expect(await vaultService.decryptPassword(pws.single), 'sec');
    });
  });

  group('disable', () {
    test('disable removes wrap; password still works', () async {
      await vaultService.createVault('pw');
      await vaultService.enableV3Biometric('pw');
      expect(await vaultService.hasV3Biometric, isTrue);

      await vaultService.disableV3Biometric();
      expect(await vaultService.hasV3Biometric, isFalse);
      expect(_keyauthCalls, contains('disable'));

      // subsequent biometric unlock is fail-closed; password still works.
      vaultService.lock();
      await expectLater(
        vaultService.unlockV3WithBiometric(),
        throwsA(isA<VaultV3BiometricException>()),
      );
      expect(await vaultService.unlock('pw'), isTrue);
    });
  });
}
