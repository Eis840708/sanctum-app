// DEV-P0-03-B2-1 — v3 envelope tests.
// Synthetic fixtures only; no real vault.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_envelope.dart';

/// Deterministic "random" source so KAT vectors are reproducible.
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
  final recordId = _bytes(16, 0x40);
  final key = SecretKey(_bytes(32, 0x01));

  RecordContext ctx({
    RecordType type = RecordType.password,
    int field = FieldId.pwSite,
    Uint8List? id,
    Uint8List? vault,
    int schema = 1,
  }) =>
      RecordContext(
        vaultId: vault ?? vaultId,
        recordType: type,
        recordId: id ?? recordId,
        fieldId: field,
        schemaVersion: schema,
      );

  group('header and format', () {
    test('emits the documented fixed binary header', () async {
      final env = VaultV3Envelope(random: _SeqRandom(1));
      final out = await env.encrypt(
        plaintext: utf8.encode('secret-site.example'),
        key: key,
        context: ctx(),
        keyGeneration: 0x0102,
      );

      expect(out.sublist(0, 4), VaultV3.magic); // "SNC3"
      expect(out[4], VaultV3.formatVersion); // 0x03
      expect(out[5], VaultV3.algAesGcm256); // 0x01
      expect(out[6], VaultV3.kdfArgon2id); // 0x02
      expect(out[7], KeyScope.data.id); // 0x01
      expect(out[8], 0x01); // key_generation hi
      expect(out[9], 0x02); // key_generation lo
      expect(out.length, VaultV3.headerLength + 19 + VaultV3.tagLength);
    });

    test('AAD layout is header ‖ vault ‖ type ‖ record ‖ field ‖ schema', () {
      final prefix = VaultV3Envelope.buildHeaderPrefix(
        kdfId: VaultV3.kdfArgon2id,
        scope: KeyScope.data,
        keyGeneration: 0,
      );
      final aad = VaultV3Envelope.buildAad(headerPrefix: prefix, context: ctx());

      expect(aad.length, 10 + 16 + 1 + 16 + 1 + 2);
      expect(aad.sublist(0, 10), prefix);
      expect(aad.sublist(10, 26), vaultId);
      expect(aad[26], RecordType.password.id);
      expect(aad.sublist(27, 43), recordId);
      expect(aad[43], FieldId.pwSite);
      expect(aad.sublist(44, 46), <int>[0x00, 0x01]);
    });

    test('isV3 keys off the explicit marker, not trial decryption', () {
      expect(VaultV3Envelope.isV3(<int>[]), isFalse);
      expect(VaultV3Envelope.isV3(utf8.encode('legacy v2 base64 payload')), isFalse);
      final fake = Uint8List(VaultV3.headerLength + VaultV3.tagLength)
        ..setAll(0, VaultV3.magic)
        ..[4] = VaultV3.formatVersion;
      expect(VaultV3Envelope.isV3(fake), isTrue);
    });

    test('rejects unknown alg_id and kdf_id instead of guessing', () async {
      final env = VaultV3Envelope(random: _SeqRandom(2));
      final good = await env.encrypt(
        plaintext: utf8.encode('x'),
        key: key,
        context: ctx(),
      );

      final badAlg = Uint8List.fromList(good)..[5] = 0x7F;
      expect(() => VaultV3Envelope.parseHeader(badAlg),
          throwsA(isA<VaultV3FormatException>()));

      final badKdf = Uint8List.fromList(good)..[6] = 0x7F;
      expect(() => VaultV3Envelope.parseHeader(badKdf),
          throwsA(isA<VaultV3FormatException>()));
    });
  });

  group('round trip', () {
    test('decrypts with the same context', () async {
      final env = VaultV3Envelope(random: _SeqRandom(3));
      final encoded = await env.encryptStringToBase64(
        plaintext: 'my-bank-login-site',
        key: key,
        context: ctx(),
      );
      final back = await env.decryptBase64ToString(
        encoded: encoded,
        key: key,
        context: ctx(),
      );
      expect(back, 'my-bank-login-site');
    });

    test('empty plaintext round trips', () async {
      final env = VaultV3Envelope(random: _SeqRandom(4));
      final out = await env.encrypt(
        plaintext: const <int>[],
        key: key,
        context: ctx(),
      );
      expect(await env.decrypt(envelope: out, key: key, context: ctx()),
          isEmpty);
    });
  });

  // V-06: cross-field / cross-record / cross-vault ciphertext swap must fail.
  group('V-06 AAD binding rejects swapped ciphertext', () {
    late VaultV3Envelope env;
    late Uint8List siteBlob;

    setUp(() async {
      env = VaultV3Envelope(random: _SeqRandom(5));
      siteBlob = await env.encrypt(
        plaintext: utf8.encode('my-bank-login-site'),
        key: key,
        context: ctx(),
      );
    });

    test('different field_id fails', () async {
      expect(
        () => env.decrypt(
          envelope: siteBlob,
          key: key,
          context: ctx(field: FieldId.pwUsername),
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('different record_type fails', () async {
      expect(
        () => env.decrypt(
          envelope: siteBlob,
          key: key,
          context: ctx(type: RecordType.diary, field: FieldId.diaryTitle),
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('different record_id fails', () async {
      expect(
        () => env.decrypt(
          envelope: siteBlob,
          key: key,
          context: ctx(id: _bytes(16, 0x90)),
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('different vault_id fails', () async {
      expect(
        () => env.decrypt(
          envelope: siteBlob,
          key: key,
          context: ctx(vault: _bytes(16, 0xA0)),
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('different schema_version fails', () async {
      expect(
        () => env.decrypt(
          envelope: siteBlob,
          key: key,
          context: ctx(schema: 2),
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('tampered header byte fails', () async {
      final tampered = Uint8List.fromList(siteBlob);
      tampered[9] = tampered[9] ^ 0x01; // key_generation lo
      expect(
        () => env.decrypt(envelope: tampered, key: key, context: ctx()),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  // v3 decryption is fail-closed: it raises, never returns its input.
  group('fail-closed decryption', () {
    test('bit-flipped ciphertext raises', () async {
      final env = VaultV3Envelope(random: _SeqRandom(6));
      final blob = await env.encrypt(
        plaintext: utf8.encode('secret'),
        key: key,
        context: ctx(),
      );
      final flipped = Uint8List.fromList(blob);
      flipped[VaultV3.headerLength] = flipped[VaultV3.headerLength] ^ 0x01;
      expect(
        () => env.decrypt(envelope: flipped, key: key, context: ctx()),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('truncated payload raises', () async {
      final env = VaultV3Envelope(random: _SeqRandom(7));
      final blob = await env.encrypt(
        plaintext: utf8.encode('secret'),
        key: key,
        context: ctx(),
      );
      expect(
        () => env.decrypt(
          envelope: blob.sublist(0, VaultV3.headerLength + 4),
          key: key,
          context: ctx(),
        ),
        throwsA(isA<VaultV3FormatException>()),
      );
    });

    test('attacker plaintext is rejected, never echoed back', () async {
      final env = VaultV3Envelope(random: _SeqRandom(8));
      const injected = 'THIS_IS_NOT_ENCRYPTED_attacker_controlled';
      expect(
        () => env.decryptBase64ToString(
          encoded: injected,
          key: key,
          context: ctx(),
        ),
        throwsA(isA<VaultV3FormatException>()),
      );
    });

    test('wrong key raises', () async {
      final env = VaultV3Envelope(random: _SeqRandom(9));
      final blob = await env.encrypt(
        plaintext: utf8.encode('secret'),
        key: key,
        context: ctx(),
      );
      expect(
        () => env.decrypt(
          envelope: blob,
          key: SecretKey(_bytes(32, 0xF0)),
          context: ctx(),
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('uuid parsing', () {
    test('parses canonical uuid', () {
      final parsed =
          VaultV3Envelope.uuidToBytes('00112233-4455-6677-8899-aabbccddeeff');
      expect(parsed.first, 0x00);
      expect(parsed.last, 0xFF);
      expect(parsed.length, 16);
    });

    test('rejects malformed uuid', () {
      expect(() => VaultV3Envelope.uuidToBytes('short'),
          throwsA(isA<VaultV3FormatException>()));
      expect(
          () => VaultV3Envelope.uuidToBytes(
              'zz112233-4455-6677-8899-aabbccddeeff'),
          throwsA(isA<VaultV3FormatException>()));
    });
  });
}
