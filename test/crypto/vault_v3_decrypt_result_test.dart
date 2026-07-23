// DEV-P0-03-B2-2 — V-03 fail-closed decryption contract tests.
// Synthetic fixtures only; no real vault.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_decrypt_result.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_envelope.dart';

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
  final env = VaultV3Envelope(random: _SeqRandom(1));
  final reader = VaultV3FieldReader(envelope: env);

  RecordContext ctx({int field = FieldId.pwSite}) => RecordContext(
        vaultId: vaultId,
        recordType: RecordType.password,
        recordId: recordId,
        fieldId: field,
        schemaVersion: 1,
      );

  Future<String> seal(String pt, {int field = FieldId.pwSite}) =>
      env.encryptStringToBase64(plaintext: pt, key: key, context: ctx(field: field));

  test('valid field decrypts to ok(plaintext)', () async {
    final blob = await seal('secret-site.example');
    final out = await reader.readField(stored: blob, key: key, context: ctx());
    expect(out.isOk, isTrue);
    expect(out.plaintext, 'secret-site.example');
    expect(out.displayableOrNull, 'secret-site.example');
  });

  test('empty stored value is empty plaintext, not a failure', () async {
    final out = await reader.readField(stored: '', key: key, context: ctx());
    expect(out.isOk, isTrue);
    expect(out.plaintext, '');
  });

  test('attacker plaintext is a failure, never echoed back', () async {
    const injected = 'THIS_IS_NOT_ENCRYPTED_attacker_controlled';
    final out =
        await reader.readField(stored: injected, key: key, context: ctx());
    expect(out.isFailure, isTrue);
    expect(out.reason, DecryptFailureReason.malformed);
    expect(out.displayableOrNull, isNull); // UI shows placeholder, not input
    expect(out.plaintext, isNot(injected));
  });

  test('non-base64 input is a malformed failure', () async {
    final out = await reader.readField(
        stored: 'not@@base64!!', key: key, context: ctx());
    expect(out.reason, DecryptFailureReason.malformed);
  });

  test('a v2-style base64 blob (no v3 magic) is malformed, not trial-decrypted',
      () async {
    final v2ish = base64.encode(_bytes(40, 0x00)); // no SNC3 magic
    final out =
        await reader.readField(stored: v2ish, key: key, context: ctx());
    expect(out.reason, DecryptFailureReason.malformed);
  });

  test('bit-flipped ciphertext is an authentication failure', () async {
    final blob = await seal('secret');
    final raw = base64.decode(blob);
    raw[VaultV3.headerLength] = raw[VaultV3.headerLength] ^ 0x01;
    final out = await reader.readField(
        stored: base64.encode(raw), key: key, context: ctx());
    expect(out.reason, DecryptFailureReason.authentication);
    expect(out.displayableOrNull, isNull);
  });

  test('wrong AAD context (field swap) is an authentication failure', () async {
    final blob = await seal('bank-site', field: FieldId.pwSite);
    // Read it as if it were the username field.
    final out = await reader.readField(
        stored: blob, key: key, context: ctx(field: FieldId.pwUsername));
    expect(out.reason, DecryptFailureReason.authentication);
  });

  test('wrong key is an authentication failure', () async {
    final blob = await seal('secret');
    final out = await reader.readField(
        stored: blob, key: SecretKey(_bytes(32, 0xF0)), context: ctx());
    expect(out.reason, DecryptFailureReason.authentication);
  });
}
