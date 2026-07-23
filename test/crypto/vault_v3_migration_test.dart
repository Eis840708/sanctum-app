// DEV-P0-03-B2-2 — V-04 explicit-version migration tests.
// Synthetic fixtures only; no real vault. The v2 decryptor is a synthetic stub.
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_envelope.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_migration.dart';

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
  final dataKey = SecretKey(_bytes(32, 0x02));
  final env = VaultV3Envelope(random: _SeqRandom(1));
  final migration = VaultV3Migration(envelope: env);

  RecordContext ctx(int fieldId, int idStart) => RecordContext(
        vaultId: vaultId,
        recordType: RecordType.password,
        recordId: _bytes(16, idStart),
        fieldId: fieldId,
        schemaVersion: 1,
      );

  // A synthetic "v2" store: value "V2:<plaintext>" authenticates; anything else
  // (including corrupted markers) returns null.
  Future<String?> v2Decrypt(String stored) async {
    if (stored.startsWith('V2:')) return stored.substring(3);
    return null;
  }

  MigrationField field(String stored, int fieldId, int idStart) =>
      MigrationField(stored: stored, context: ctx(fieldId, idStart));

  test('migrates authenticated v2 fields into v3 envelopes', () async {
    final report = await migration.migrate(
      fields: [
        field('V2:site.example', FieldId.pwSite, 0x40),
        field('V2:alice', FieldId.pwUsername, 0x40),
      ],
      v2Decrypt: v2Decrypt,
      dataKey: dataKey,
    );

    expect(report.status, MigrationStatus.complete);
    expect(report.mayFlagV3, isTrue);
    expect(report.isolated, isEmpty);
    expect(report.migrated.length, 2);

    // Each migrated value is a real v3 envelope that decrypts back.
    final reader = env;
    final siteKey = VaultV3Migration.slotKey(ctx(FieldId.pwSite, 0x40));
    final back = await reader.decryptBase64ToString(
      encoded: report.migrated[siteKey]!,
      key: dataKey,
      context: ctx(FieldId.pwSite, 0x40),
    );
    expect(back, 'site.example');
  });

  test('corrupted v2 field is ISOLATED, never re-encrypted, blocks v3 flag',
      () async {
    final report = await migration.migrate(
      fields: [
        field('V2:good', FieldId.pwSite, 0x40),
        field('CORRUPT-bytes', FieldId.pwPassword, 0x40), // fails v2 auth
      ],
      v2Decrypt: v2Decrypt,
      dataKey: dataKey,
    );

    expect(report.status, MigrationStatus.partial);
    expect(report.mayFlagV3, isFalse); // must NOT flag fully migrated
    expect(report.migrated.length, 1); // only the good one
    expect(report.isolated.length, 1);

    final iso = report.isolated.single;
    expect(iso.stored, 'CORRUPT-bytes'); // original bytes preserved verbatim
    expect(iso.reason, contains('isolated'));
    // The corrupted bytes were NOT laundered into any migrated envelope.
    expect(report.migrated.values.any((v) => v.contains('CORRUPT')), isFalse);
  });

  test('already-v3 fields are skipped by explicit marker, not re-encrypted',
      () async {
    final existingV3 = await env.encryptStringToBase64(
      plaintext: 'already-v3',
      key: dataKey,
      context: ctx(FieldId.pwSite, 0x50),
    );

    final report = await migration.migrate(
      fields: [field(existingV3, FieldId.pwSite, 0x50)],
      v2Decrypt: (_) async =>
          throw StateError('v2 decrypt must not be called for a v3 field'),
      dataKey: dataKey,
    );

    expect(report.alreadyV3, 1);
    expect(report.migrated, isEmpty);
    expect(report.isolated, isEmpty);
    expect(report.status, MigrationStatus.complete);
  });

  test('resume skips slots already committed (idempotent)', () async {
    final done = <String>{
      VaultV3Migration.slotKey(ctx(FieldId.pwSite, 0x40)),
    };
    final report = await migration.migrate(
      fields: [
        field('V2:site', FieldId.pwSite, 0x40), // already done -> skip
        field('V2:user', FieldId.pwUsername, 0x40),
      ],
      v2Decrypt: v2Decrypt,
      dataKey: dataKey,
      alreadyDone: done,
    );

    expect(report.migrated.length, 1);
    expect(
      report.migrated.containsKey(
          VaultV3Migration.slotKey(ctx(FieldId.pwUsername, 0x40))),
      isTrue,
    );
  });

  test('empty stored value is treated as a v2 field, not v3', () async {
    // Empty is not v3 (no magic); v2Decrypt returns null -> isolated.
    final report = await migration.migrate(
      fields: [field('', FieldId.pwNotes, 0x60)],
      v2Decrypt: v2Decrypt,
      dataKey: dataKey,
    );
    expect(report.isolated.length, 1);
  });

  test('slotKey is stable and distinct per slot', () {
    final a = VaultV3Migration.slotKey(ctx(FieldId.pwSite, 0x40));
    final b = VaultV3Migration.slotKey(ctx(FieldId.pwUsername, 0x40));
    final c = VaultV3Migration.slotKey(ctx(FieldId.pwSite, 0x41));
    expect(a, isNot(b));
    expect(a, isNot(c));
    expect(a, VaultV3Migration.slotKey(ctx(FieldId.pwSite, 0x40)));
  });
}
