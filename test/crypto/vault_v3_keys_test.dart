// DEV-P0-03-B2-1 — v3 key hierarchy tests (Option 2).
// Synthetic fixtures only; no real vault.
//
// Argon2id parameters here are deliberately tiny so the suite stays fast.
// Production parameters are decided by on-device measurement, not by tests.
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_envelope.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_keys.dart';

class _SeqRandom implements Random {
  _SeqRandom(this._seed);
  int _seed;
  @override
  int nextInt(int max) => (_seed = (_seed * 7 + 13) & 0xFF) % max;
  @override
  bool nextBool() => nextInt(2) == 1;
  @override
  double nextDouble() => nextInt(256) / 256.0;
}

Uint8List _bytes(int length, int start) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (start + i) & 0xFF));

void main() {
  final vaultId = _bytes(16, 0x10);

  // Small on purpose: keeps `flutter test` fast.
  final fastKdf = KdfDescriptor(
    salt: _bytes(32, 0x20),
    memoryKib: 64,
    iterations: 1,
    lanes: 1,
  );

  group('KdfDescriptor', () {
    test('is self-describing and round trips through JSON', () {
      final json = fastKdf.toJson();
      expect(json['kdf_id'], VaultV3.kdfArgon2id);
      expect(json['version'], 0x13);
      expect(json['out_len'], 32);

      final back = KdfDescriptor.fromJson(json);
      expect(back.memoryKib, fastKdf.memoryKib);
      expect(back.iterations, fastKdf.iterations);
      expect(back.lanes, fastKdf.lanes);
      expect(back.salt, fastKdf.salt);
      expect(back.normalization, fastKdf.normalization);
    });

    test('records the normalisation actually applied', () {
      // design-spec §3.2 asks for NFC; no NFC implementation is vendored yet,
      // so the descriptor must not claim NFC. Raised to the director.
      expect(fastKdf.normalization, PasswordNormalization.none);
      expect(fastKdf.toJson()['normalization'], 'none');
    });
  });

  group('Option 2 key hierarchy', () {
    late VaultV3KeyHierarchy kh;

    setUp(() => kh = VaultV3KeyHierarchy(random: _SeqRandom(11)));

    test('DEK is random, not derived from the password', () async {
      final a = kh.generateDek();
      final b = kh.generateDek();
      expect(a.length, 32);
      expect(a, isNot(b));
    });

    test('unlock recovers the same DEK and subkeys', () async {
      final dek = kh.generateDek();
      final kek = await kh.deriveKek(password: 'pw-synthetic', descriptor: fastKdf);
      final wrapped = await kh.wrapDekWithKek(
        dek: dek,
        kek: kek,
        vaultId: vaultId,
      );

      final keys = await kh.unlockWithPassword(
        password: 'pw-synthetic',
        descriptor: fastKdf,
        wrappedDek: wrapped,
        vaultId: vaultId,
      );

      expect(await keys.dek.extractBytes(), dek);
      expect(keys.keyGeneration, 0);
    });

    test('wrong password fails to unwrap the DEK', () async {
      final dek = kh.generateDek();
      final kek = await kh.deriveKek(password: 'right', descriptor: fastKdf);
      final wrapped =
          await kh.wrapDekWithKek(dek: dek, kek: kek, vaultId: vaultId);

      expect(
        () => kh.unlockWithPassword(
          password: 'wrong',
          descriptor: fastKdf,
          wrappedDek: wrapped,
          vaultId: vaultId,
        ),
        throwsA(isA<VaultV3KeyException>()),
      );
    });

    test('wrap blob is bound to its vault id', () async {
      final dek = kh.generateDek();
      final kek = await kh.deriveKek(password: 'pw', descriptor: fastKdf);
      final wrapped =
          await kh.wrapDekWithKek(dek: dek, kek: kek, vaultId: vaultId);

      expect(
        () => kh.unwrapDekWithKek(
          wrapped: wrapped,
          kek: kek,
          vaultId: _bytes(16, 0x99),
        ),
        throwsA(isA<VaultV3KeyException>()),
      );
    });

    test('password change re-wraps the DEK without touching records', () async {
      final dek = kh.generateDek();
      final oldKek = await kh.deriveKek(password: 'old', descriptor: fastKdf);
      final oldWrap =
          await kh.wrapDekWithKek(dek: dek, kek: oldKek, vaultId: vaultId);

      final newKdf = KdfDescriptor(
        salt: _bytes(32, 0x77),
        memoryKib: 64,
        iterations: 1,
        lanes: 1,
      );
      final newKek = await kh.deriveKek(password: 'new', descriptor: newKdf);
      final newWrap = await kh.wrapDekWithKek(
        dek: await kh.unwrapDekWithKek(
          wrapped: oldWrap,
          kek: oldKek,
          vaultId: vaultId,
        ),
        kek: newKek,
        vaultId: vaultId,
        keyGeneration: oldWrap.keyGeneration + 1,
      );

      final recovered = await kh.unwrapDekWithKek(
        wrapped: newWrap,
        kek: newKek,
        vaultId: vaultId,
      );
      expect(recovered, dek); // same DEK ⇒ records need no re-encryption
      expect(newWrap.keyGeneration, 1);
    });

    test('subkeys are domain separated', () async {
      final dek = kh.generateDek();
      final keys =
          await kh.deriveSubkeys(dek: dek, vaultId: vaultId, keyGeneration: 0);

      final data = await keys.dataKey.extractBytes();
      final verify = await keys.verifyKey.extractBytes();
      final backup = await keys.backupKey.extractBytes();

      expect(data, isNot(verify));
      expect(data, isNot(backup));
      expect(verify, isNot(backup));
      expect(data.length, 32);
      expect(data, isNot(dek));
    });

    test('subkeys are deterministic for a given DEK and vault', () async {
      final dek = kh.generateDek();
      final a =
          await kh.deriveSubkeys(dek: dek, vaultId: vaultId, keyGeneration: 0);
      final b =
          await kh.deriveSubkeys(dek: dek, vaultId: vaultId, keyGeneration: 0);
      expect(await a.dataKey.extractBytes(), await b.dataKey.extractBytes());
    });
  });

  // DR-01: Shamir splits a full-entropy recovery key, never the master password.
  group('recovery key (DR-01)', () {
    late VaultV3KeyHierarchy kh;
    setUp(() => kh = VaultV3KeyHierarchy(random: _SeqRandom(12)));

    test('recovery key is 32 bytes of full entropy', () {
      final r = kh.generateRecoveryKey();
      expect(r.length, 32);
      expect(r, isNot(kh.generateRecoveryKey()));
    });

    test('recovery key unwraps the same DEK as the password path', () async {
      final dek = kh.generateDek();
      final r = kh.generateRecoveryKey();
      final kek = await kh.deriveKek(password: 'pw', descriptor: fastKdf);

      final byPassword =
          await kh.wrapDekWithKek(dek: dek, kek: kek, vaultId: vaultId);
      final byRecovery = await kh.wrapDekWithRecoveryKey(
        dek: dek,
        recoveryKey: r,
        vaultId: vaultId,
      );

      expect(
        await kh.unwrapDekWithKek(
            wrapped: byPassword, kek: kek, vaultId: vaultId),
        dek,
      );
      expect(
        await kh.unwrapDekWithRecoveryKey(
            wrapped: byRecovery, recoveryKey: r, vaultId: vaultId),
        dek,
      );
    });

    test('password and recovery wrap labels are not interchangeable', () async {
      final dek = kh.generateDek();
      final r = kh.generateRecoveryKey();
      final recoveryWrap = await kh.wrapDekWithRecoveryKey(
        dek: dek,
        recoveryKey: r,
        vaultId: vaultId,
      );

      // Same key bytes, wrong label ⇒ AAD mismatch ⇒ rejected.
      expect(
        () => kh.unwrapDekWithKek(
          wrapped: recoveryWrap,
          kek: SecretKey(r),
          vaultId: vaultId,
        ),
        throwsA(isA<VaultV3KeyException>()),
      );
    });

    test('commitment is SHA-256 over the full-entropy key', () async {
      final r = kh.generateRecoveryKey();
      final commit = await kh.recoveryCommitment(r);
      final expected = await Sha256().hash(r);

      expect(commit, expected.bytes);
      expect(commit.length, 32);
      expect(await kh.recoveryCommitment(kh.generateRecoveryKey()),
          isNot(commit));
    });
  });

  group('envelope integrates with the hierarchy', () {
    test('data subkey encrypts and decrypts a record field', () async {
      final kh = VaultV3KeyHierarchy(random: _SeqRandom(13));
      final env = VaultV3Envelope(random: _SeqRandom(14));

      final dek = kh.generateDek();
      final keys =
          await kh.deriveSubkeys(dek: dek, vaultId: vaultId, keyGeneration: 0);

      final context = RecordContext(
        vaultId: vaultId,
        recordType: RecordType.finance,
        recordId: _bytes(16, 0x50),
        fieldId: FieldId.finAmount,
        schemaVersion: 1,
      );

      final blob = await env.encryptStringToBase64(
        plaintext: '1234.56',
        key: keys.dataKey,
        context: context,
      );
      expect(
        await env.decryptBase64ToString(
            encoded: blob, key: keys.dataKey, context: context),
        '1234.56',
      );

      // A different subkey must not open a data-scope ciphertext.
      expect(
        () => env.decryptBase64ToString(
            encoded: blob, key: keys.backupKey, context: context),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });
}
