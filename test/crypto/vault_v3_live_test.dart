// Real-adapter regression for B2-5a DEK live-integration (RETURN level).
// DEV-P0-03 B2-5a. Synthetic passwords only — no real vault.
//
// Exercises the real key hierarchy (Argon2id KEK, AES-GCM DEK wrap, HKDF
// subkeys) and a real Hive material store, mirroring what VaultService.createVault
// / _unlockV3 do:
//   * v3 DEK round-trip: create -> persist material -> reload -> unlock -> the
//     data subkey decrypts what it encrypted; a wrong password fails closed.
//   * v2 zero-regression: the untouched v2 crypto primitives still round-trip and
//     verify (VaultService's v2 unlock path is byte-for-byte unchanged; only a
//     `version == 'v3'` branch was added above it).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:sanctum/core/crypto/crypto_service.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_keys.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_live.dart';

late Directory _tmp;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('b2_5a_live_');
    Hive.init(_tmp.path);
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await _tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('v3 DEK live-integration round-trip (real crypto + real Hive store)', () {
    test('create -> persist -> reload -> unlock -> data subkey decrypts',
        () async {
      final live = VaultV3Live();
      final created = await live.create('correct horse battery staple');

      // Encrypt a secret under the freshly created data subkey.
      final ct = await cryptoService.encrypt('TOP-SECRET', created.dataKey);

      // Persist material to a real Hive box and reload it (durability path).
      final box = await Hive.openBox('sanctum_vault_v3');
      await box.put('material', created.material.encode());
      final reloaded = VaultV3Material.decode(box.get('material') as String);

      // Unlock with the correct password -> a data subkey that decrypts the ct.
      final dataKey = await live.unlock('correct horse battery staple', reloaded);
      expect(await cryptoService.decrypt(ct, dataKey), 'TOP-SECRET');
    });

    test('wrong password fails closed (VaultV3KeyException, no wrong key)',
        () async {
      final live = VaultV3Live();
      final created = await live.create('right-password');
      await expectLater(
        live.unlock('WRONG-password', created.material),
        throwsA(isA<VaultV3KeyException>()),
      );
    });

    test('material JSON round-trip preserves vaultId / wrappedDEK / descriptor',
        () async {
      final live = VaultV3Live();
      final created = await live.create('pw');
      final m = created.material;
      final r = VaultV3Material.decode(m.encode());
      expect(r.vaultId, m.vaultId);
      expect(r.wrappedDek.bytes, m.wrappedDek.bytes);
      expect(r.wrappedDek.keyGeneration, m.wrappedDek.keyGeneration);
      expect(r.descriptor.salt, m.descriptor.salt);
      expect(r.descriptor.memoryKib, m.descriptor.memoryKib);
      expect(r.descriptor.iterations, m.descriptor.iterations);
      expect(r.descriptor.lanes, m.descriptor.lanes);
      expect(r.descriptor.normalization, m.descriptor.normalization);
      expect(r.recoveryWrappedDek, isNull);
    });

    test('KEK params are provisional above-floor Argon2id (19 MiB / t2 / p1)',
        () async {
      final live = VaultV3Live();
      final created = await live.create('pw');
      final d = created.material.descriptor;
      expect(d.kdfId, VaultV3KeysGuard.kdfArgon2id);
      expect(d.memoryKib, greaterThanOrEqualTo(KdfDescriptor.floorMemoryKib));
      expect(d.iterations, greaterThanOrEqualTo(KdfDescriptor.floorIterations));
      expect(d.lanes, greaterThanOrEqualTo(KdfDescriptor.floorLanes));
      expect(d.normalization, PasswordNormalization.nfc);
      expect(d.belowSecurityFloor, isFalse);
    });
  });

  group('v2 zero-regression (untouched crypto primitives still round-trip)', () {
    test('deriveKey + verifyKey accept correct and reject wrong password',
        () async {
      final salt = cryptoService.generateSalt();
      final key = await cryptoService.deriveKey('master-pw', salt);
      final vh = await cryptoService.makeVerifyHash(key);

      final again = await cryptoService.deriveKey('master-pw', salt);
      expect(await cryptoService.verifyKey(again, vh), isTrue);

      final wrong = await cryptoService.deriveKey('not-it', salt);
      expect(await cryptoService.verifyKey(wrong, vh), isFalse);
    });

    test('v2 field encrypt/decrypt round-trips under the derived key', () async {
      final salt = cryptoService.generateSalt();
      final key = await cryptoService.deriveKey('pw', salt);
      final ct = await cryptoService.encrypt('diary entry', key);
      expect(await cryptoService.decrypt(ct, key), 'diary entry');
    });
  });
}

/// Small guard exposing the Argon2id kdf id constant for the assertion above
/// without importing the envelope layer into the test.
class VaultV3KeysGuard {
  static const int kdfArgon2id = 0x02;
}
