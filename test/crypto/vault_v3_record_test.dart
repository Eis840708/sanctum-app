// Tests for the v3 full-record per-field codec (DEV-P0-03 B2-5b, option C).
// Synthetic key/vault only. Proves per-field round-trip and that the per-field
// V-06 AAD binding survives the storage-location move: a ciphertext moved to a
// different field / record slot fails to authenticate (never decrypts wrong).

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sanctum/core/crypto/v3/vault_v3_envelope.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_record.dart';

void main() {
  final codec = VaultV3RecordCodec();
  final dataKey = SecretKey(List<int>.generate(32, (i) => (i * 3 + 1) & 0xFF));
  final vaultId = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));

  Map<int, String> pwFields() => {
        V3FieldId.pwSite: 'example.invalid',
        V3FieldId.pwUsername: 'alice',
        V3FieldId.pwPassword: 's3cr3t!',
        V3FieldId.pwNotes: 'recovery codes inside',
        V3FieldId.pwIconEmoji: '🔐',
        V3FieldId.pwCreatedAt: '1700000000000',
        V3FieldId.pwUpdatedAt: '1700000009999',
      };

  test('per-field round-trip preserves every field', () async {
    final stored = await codec.encode(
      recordType: RecordType.password,
      id: 'rec-1',
      fields: pwFields(),
      dataKey: dataKey,
      vaultId: vaultId,
    );
    final back = await codec.decode(
      recordType: RecordType.password,
      id: 'rec-1',
      stored: stored,
      dataKey: dataKey,
      vaultId: vaultId,
    );
    expect(back, pwFields());
  });

  test('stored form leaks no plaintext (all fields are v3 envelopes)', () async {
    final stored = await codec.encode(
      recordType: RecordType.password,
      id: 'rec-1',
      fields: pwFields(),
      dataKey: dataKey,
      vaultId: vaultId,
    );
    expect(stored.contains('example.invalid'), isFalse);
    expect(stored.contains('alice'), isFalse);
    expect(stored.contains('s3cr3t'), isFalse);
    // Every field payload is a v3 envelope.
    final f = (jsonDecode(stored) as Map)['f'] as Map;
    for (final v in f.values) {
      expect(VaultV3Envelope.isV3(base64.decode(v as String)), isTrue);
    }
  });

  test('field ciphertext moved to another field slot fails to authenticate',
      () async {
    final stored = await codec.encode(
      recordType: RecordType.password,
      id: 'rec-1',
      fields: {V3FieldId.pwSite: 'site-value', V3FieldId.pwUsername: 'user-value'},
      dataKey: dataKey,
      vaultId: vaultId,
    );
    final map = jsonDecode(stored) as Map;
    final f = (map['f'] as Map).cast<String, Object?>();
    // Swap the site (0x01) and username (0x02) envelopes.
    final tmp = f['1'];
    f['1'] = f['2'];
    f['2'] = tmp;
    final tampered = jsonEncode({'sv': map['sv'], 'f': f});

    await expectLater(
      codec.decode(
        recordType: RecordType.password,
        id: 'rec-1',
        stored: tampered,
        dataKey: dataKey,
        vaultId: vaultId,
      ),
      throwsA(anything),
    );
  });

  test('record decoded under a different id fails (recordId AAD binding)',
      () async {
    final stored = await codec.encode(
      recordType: RecordType.password,
      id: 'rec-A',
      fields: {V3FieldId.pwSite: 'site'},
      dataKey: dataKey,
      vaultId: vaultId,
    );
    await expectLater(
      codec.decode(
        recordType: RecordType.password,
        id: 'rec-B', // different record id
        stored: stored,
        dataKey: dataKey,
        vaultId: vaultId,
      ),
      throwsA(anything),
    );
  });

  test('record decoded under a different record type fails (type AAD binding)',
      () async {
    final stored = await codec.encode(
      recordType: RecordType.password,
      id: 'rec-1',
      fields: {V3FieldId.pwSite: 'site'},
      dataKey: dataKey,
      vaultId: vaultId,
    );
    await expectLater(
      codec.decode(
        recordType: RecordType.diary, // wrong type
        id: 'rec-1',
        stored: stored,
        dataKey: dataKey,
        vaultId: vaultId,
      ),
      throwsA(anything),
    );
  });

  test('bit-flip in a field envelope fails closed', () async {
    final stored = await codec.encode(
      recordType: RecordType.finance,
      id: 'fin-1',
      fields: {V3FieldId.finAmount: '42.50', V3FieldId.finCurrency: 'HKD'},
      dataKey: dataKey,
      vaultId: vaultId,
    );
    final map = jsonDecode(stored) as Map;
    final f = (map['f'] as Map).cast<String, Object?>();
    final bytes = base64.decode(f['4']! as String);
    bytes[bytes.length - 1] ^= 0xFF; // corrupt the GCM tag
    f['4'] = base64.encode(bytes);
    final tampered = jsonEncode({'sv': map['sv'], 'f': f});

    await expectLater(
      codec.decode(
        recordType: RecordType.finance,
        id: 'fin-1',
        stored: tampered,
        dataKey: dataKey,
        vaultId: vaultId,
      ),
      throwsA(anything),
    );
  });
}
