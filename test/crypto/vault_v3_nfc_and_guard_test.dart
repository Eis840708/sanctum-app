// DEV-P0-03-B2-2 — NFC normalisation + Argon2id floor dual-track guard tests.
// Synthetic fixtures only; no real vault.
//
// Composed/decomposed strings are built from explicit code points via
// String.fromCharCodes so the byte-level distinction cannot be lost to editor
// normalisation.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

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
  final salt = _bytes(32, 0x20);

  KdfDescriptor fast({
    int mem = 64,
    int iters = 1,
    int lanes = 1,
    PasswordNormalization norm = PasswordNormalization.none,
  }) =>
      KdfDescriptor(
        salt: salt,
        memoryKib: mem,
        iterations: iters,
        lanes: lanes,
        normalization: norm,
      );

  group('Argon2id floor dual-track guard (director ruling B2-2 §二)', () {
    test('new-parameter path enforces the floor and throws, no silent clamp',
        () {
      expect(
        () => KdfDescriptor.forNewParameters(salt: salt, memoryKib: 8 * 1024),
        throwsA(isA<KdfFloorViolation>()),
      );
      expect(
        () => KdfDescriptor.forNewParameters(salt: salt, iterations: 1),
        throwsA(isA<KdfFloorViolation>()),
      );
    });

    test('new-parameter path at exactly the floor is accepted', () {
      final d = KdfDescriptor.forNewParameters(salt: salt);
      expect(d.memoryKib, KdfDescriptor.floorMemoryKib);
      expect(d.iterations, KdfDescriptor.floorIterations);
      expect(d.lanes, KdfDescriptor.floorLanes);
      expect(d.belowSecurityFloor, isFalse);
    });

    test('raising lanes is allowed; lowering memory is not', () {
      expect(
        () => KdfDescriptor.forNewParameters(salt: salt, lanes: 4),
        returnsNormally,
      );
      expect(
        () => KdfDescriptor.forNewParameters(
            salt: salt, memoryKib: KdfDescriptor.floorMemoryKib - 1024),
        throwsA(isA<KdfFloorViolation>()),
      );
    });

    test(
        'read path unconditionally accepts a below-floor descriptor and unlocks',
        () async {
      final kh = VaultV3KeyHierarchy(random: _SeqRandom(1));
      final weak = KdfDescriptor.fromJson(<String, Object?>{
        'kdf_id': VaultV3.kdfArgon2id,
        'version': 0x13,
        'mem_kib': 8 * 1024, // below 19 MiB floor
        'iterations': 1,
        'lanes': 1,
        'salt': base64.encode(salt),
        'out_len': 32,
        'normalization': 'none',
      });
      expect(weak.belowSecurityFloor, isTrue);

      final dek = kh.generateDek();
      final kek = await kh.deriveKek(password: 'pw', descriptor: weak);
      final wrapped =
          await kh.wrapDekWithKek(dek: dek, kek: kek, vaultId: vaultId);
      final keys = await kh.unlockWithPassword(
        password: 'pw',
        descriptor: weak,
        wrappedDek: wrapped,
        vaultId: vaultId,
      );
      expect(await keys.dek.extractBytes(), dek); // unlocked despite weak params
    });
  });

  group('NFC password normalisation (director ruling B2-2 §三)', () {
    // "café": precomposed U+00E9 vs 'e' + U+0301 (combining acute).
    final precomposed = String.fromCharCodes(<int>[0x63, 0x61, 0x66, 0x00E9]);
    final decomposed =
        String.fromCharCodes(<int>[0x63, 0x61, 0x66, 0x65, 0x0301]);

    test('inputs really differ before normalisation', () {
      expect(precomposed, isNot(decomposed));
      expect(precomposed.runes.length, 4);
      expect(decomposed.runes.length, 5);
    });

    test('NFC and NFD forms of the same password derive the same KEK',
        () async {
      final kh = VaultV3KeyHierarchy(random: _SeqRandom(2));
      final d = fast(norm: PasswordNormalization.nfc);
      final k1 = await kh.deriveKek(password: precomposed, descriptor: d);
      final k2 = await kh.deriveKek(password: decomposed, descriptor: d);
      expect(await k1.extractBytes(), await k2.extractBytes());
    });

    test('with normalization=none the two forms derive DIFFERENT KEKs',
        () async {
      final kh = VaultV3KeyHierarchy(random: _SeqRandom(3));
      final d = fast(norm: PasswordNormalization.none);
      final k1 = await kh.deriveKek(password: precomposed, descriptor: d);
      final k2 = await kh.deriveKek(password: decomposed, descriptor: d);
      expect(await k1.extractBytes(), isNot(await k2.extractBytes()));
    });

    test('apply() implements the enum contract', () {
      expect(PasswordNormalization.none.apply(decomposed), decomposed);
      expect(PasswordNormalization.nfc.apply(decomposed), precomposed);
      expect(PasswordNormalization.nfc.apply(precomposed), precomposed);
    });

    test('coverage: Japanese dakuten, CJK, emoji, ASCII', () {
      // が: か (U+304B) + combining dakuten (U+3099) -> U+304C
      final kaDakuten = String.fromCharCodes(<int>[0x304B, 0x3099]);
      final ga = String.fromCharCodes(<int>[0x304C]);
      expect(PasswordNormalization.nfc.apply(kaDakuten), ga);

      // CJK ideographs: no composition, unchanged.
      final cjk = String.fromCharCodes(<int>[0x4E2D, 0x6587]); // 中文
      expect(PasswordNormalization.nfc.apply(cjk), cjk);

      // Emoji: unchanged.
      final emoji = String.fromCharCodes(<int>[0x1F510]);
      expect(PasswordNormalization.nfc.apply(emoji), emoji);

      // Pure ASCII: unchanged.
      expect(PasswordNormalization.nfc.apply('Password123!'), 'Password123!');
    });

    test('descriptor records the normalisation actually used', () {
      expect(fast(norm: PasswordNormalization.nfc).toJson()['normalization'],
          'NFC');
      expect(fast(norm: PasswordNormalization.none).toJson()['normalization'],
          'none');
      final back = KdfDescriptor.fromJson(
          fast(norm: PasswordNormalization.nfc).toJson());
      expect(back.normalization, PasswordNormalization.nfc);
    });
  });
}
