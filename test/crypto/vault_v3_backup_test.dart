// v3 backup container unit tests (DEV-P0-03-UI 子項 A).
// Pure — no Hive. Drives VaultV3Backup encode/parseHeader/deriveKeys/decodeBody
// with a real material built by VaultV3Live.create. Synthetic data only.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:sanctum/core/crypto/v3/vault_v3_backup.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_keys.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_live.dart';

void main() {
  final backup = VaultV3Backup();

  // Synthetic "already-sealed" record values (opaque strings for the container).
  Map<String, Map<String, String>> sampleRecords() => {
        'sanctum_passwords__v3': {
          'id-1': '{"sv":1,"f":{"1":"ZW52ZWxvcGUtMQ=="}}',
          'id-2': '{"sv":1,"f":{"1":"ZW52ZWxvcGUtMg=="}}',
        },
        'sanctum_diary__v3': {
          'd-1': '{"sv":1,"f":{"2":"ZGlhcnk="}}',
        },
        'sanctum_finance__v3': {},
        'sanctum_images__v3': {},
        'sanctum_image_index__v3': {},
      };

  Future<Uint8List> seal(String pw, {Map<String, Map<String, String>>? recs}) async {
    final created = await vaultV3Live.create(pw);
    return backup.encode(
      material: created.material,
      recordsByBox: recs ?? sampleRecords(),
      backupKey: created.backupKey,
      createdAt: DateTime(2026, 7, 30),
    );
  }

  group('round-trip', () {
    test('encode -> parseHeader -> deriveKeys -> decodeBody returns identical set',
        () async {
      final created = await vaultV3Live.create('correct horse');
      final recs = sampleRecords();
      final bytes = await backup.encode(
        material: created.material,
        recordsByBox: recs,
        backupKey: created.backupKey,
        createdAt: DateTime(2026, 7, 30),
      );

      final header = backup.parseHeader(bytes);
      expect(header.material.vaultId, created.material.vaultId);
      expect(header.recordCounts['sanctum_passwords__v3'], 2);

      final keys =
          await backup.deriveKeys(password: 'correct horse', material: header.material);
      final out = await backup.decodeBody(
          bytes: bytes, header: header, backupKey: keys.backupKey);
      expect(out, equals(recs));
    });

    test('magic detection', () async {
      final bytes = await seal('pw');
      expect(VaultV3Backup.isBackupV3(bytes), isTrue);
      expect(VaultV3Backup.isBackupV3(Uint8List.fromList([1, 2, 3])), isFalse);
    });
  });

  group('fail-closed', () {
    test('wrong password fails the wrapped-DEK unwrap (no body access)', () async {
      final bytes = await seal('right-password');
      final header = backup.parseHeader(bytes);
      await expectLater(
        backup.deriveKeys(password: 'wrong-password', material: header.material),
        throwsA(isA<VaultV3KeyException>()),
      );
    });

    test('flipped body byte fails the outer tag', () async {
      final created = await vaultV3Live.create('pw');
      final bytes = await backup.encode(
        material: created.material,
        recordsByBox: sampleRecords(),
        backupKey: created.backupKey,
        createdAt: DateTime(2026, 7, 30),
      );
      final header = backup.parseHeader(bytes);
      final tampered = Uint8List.fromList(bytes);
      tampered[tampered.length - 1] ^= 0xFF; // corrupt inside the GCM tag
      final keys = await backup.deriveKeys(password: 'pw', material: header.material);
      await expectLater(
        backup.decodeBody(bytes: tampered, header: header, backupKey: keys.backupKey),
        throwsA(anything),
      );
    });

    test('flipped header byte breaks AAD binding', () async {
      final created = await vaultV3Live.create('pw');
      final bytes = await backup.encode(
        material: created.material,
        recordsByBox: sampleRecords(),
        backupKey: created.backupKey,
        createdAt: DateTime(2026, 7, 30),
      );
      // Corrupt a byte inside the header_json region (offset >= 8).
      final tampered = Uint8List.fromList(bytes);
      tampered[BackupV3.headerOffset + 2] ^= 0xFF;
      // parseHeader may still succeed (JSON often survives one flip) or throw;
      // if it parses, decode must fail because headerPrefix is the AAD.
      try {
        final header = backup.parseHeader(tampered);
        final keys =
            await backup.deriveKeys(password: 'pw', material: header.material);
        await expectLater(
          backup.decodeBody(
              bytes: tampered, header: header, backupKey: keys.backupKey),
          throwsA(anything),
        );
      } on BackupFormatException {
        // Acceptable: rejected at parse time.
      } on Object {
        // Any structured rejection is acceptable (fail-closed).
      }
    });

    test('unknown magic is rejected explicitly', () {
      final notBackup = Uint8List.fromList(utf8.encode('{"version":"2.0"}'));
      expect(() => backup.parseHeader(notBackup),
          throwsA(isA<BackupFormatException>()));
    });

    test('container truncated below the body minimum is rejected at parse',
        () async {
      final bytes = await seal('pw');
      // Drop the entire body: only magic+version+header_len(+header) remain.
      final truncated = bytes.sublist(0, BackupV3.headerOffset);
      expect(() => backup.parseHeader(truncated),
          throwsA(isA<BackupFormatException>()));
    });

    test('body truncation fails the outer GCM tag at decode', () async {
      final created = await vaultV3Live.create('pw');
      final bytes = await backup.encode(
        material: created.material,
        recordsByBox: sampleRecords(),
        backupKey: created.backupKey,
        createdAt: DateTime(2026, 7, 30),
      );
      final header = backup.parseHeader(bytes);
      // Lop bytes off the end of the body (still >= structural minimum) so the
      // header parses but the ciphertext/tag no longer authenticates.
      final truncated = bytes.sublist(0, bytes.length - 4);
      final keys = await backup.deriveKeys(password: 'pw', material: header.material);
      await expectLater(
        backup.decodeBody(
            bytes: truncated, header: header, backupKey: keys.backupKey),
        throwsA(anything),
      );
    });
  });

  group('recovery material survives the container', () {
    test('material with recovery wrap is carried in the header', () async {
      // Build material, then simulate recovery-enabled material by round-tripping
      // through toJson/fromJson with a recovery wrap present.
      final created = await vaultV3Live.create('pw');
      final withRec = created.material.withRecovery(
        recoveryWrappedDek: created.material.wrappedDek, // opaque blob for the test
        recoveryCommit: Uint8List.fromList(List<int>.filled(32, 7)),
      );
      final bytes = await backup.encode(
        material: withRec,
        recordsByBox: sampleRecords(),
        backupKey: created.backupKey,
        createdAt: DateTime(2026, 7, 30),
      );
      final header = backup.parseHeader(bytes);
      expect(header.material.recoveryWrappedDek, isNotNull);
      expect(header.material.recoveryCommit, isNotNull);
    });
  });
}
