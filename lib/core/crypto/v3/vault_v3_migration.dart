// Vault v2 -> v3 field migration engine (findings V-04; migration-plan.md).
// DEV-P0-03-B2-2. V-03 and V-04 are one batch (linked clause).
//
// Fixes the V-04 defect ("try decrypt; on failure re-encrypt", which laundered
// corrupted ciphertext into a valid-looking new ciphertext and flagged the vault
// migrated):
//   * version is decided by an EXPLICIT marker, never by trial decryption;
//   * a v2 field that fails AEAD authentication is ISOLATED, never re-encrypted;
//   * the vault is only flagged fully-migrated when zero fields were isolated.
//
// Pure and additive: it never imports the product v2 crypto. The caller injects
// a v2 decryptor that authenticates and returns null on failure, so this engine
// is exercised entirely with synthetic inputs in tests.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'vault_v3_envelope.dart';

/// Authenticates a v2 field and returns its plaintext, or null if it does not
/// authenticate. Returning null MUST mean "failed authentication", not "guessed
/// wrong version" — version is resolved separately and explicitly.
typedef V2FieldDecryptor = Future<String?> Function(String storedValue);

/// One field to migrate, with the context its v3 ciphertext will be bound to.
class MigrationField {
  const MigrationField({required this.stored, required this.context});

  final String stored;
  final RecordContext context;
}

/// A field that could not be migrated and was isolated (never re-encrypted).
class IsolatedField {
  const IsolatedField({required this.context, required this.stored, required this.reason});

  final RecordContext context;
  final String stored; // original bytes preserved verbatim for manual recovery
  final String reason;
}

/// Terminal state of a migration run.
enum MigrationStatus {
  /// Every non-v3 field migrated and zero fields isolated.
  complete,

  /// At least one field was isolated; vault stays on a partial marker so the
  /// mixed-read path remains active. NOT flagged as fully migrated.
  partial,
}

/// Result of migrating a set of fields.
class MigrationReport {
  MigrationReport({
    required this.migrated,
    required this.alreadyV3,
    required this.isolated,
  });

  /// context -> new v3 Base64 envelope, ready to be committed by the caller.
  final Map<String, String> migrated;

  /// Fields already in v3 form (skipped, not touched).
  final int alreadyV3;

  /// Fields that failed authentication and were isolated.
  final List<IsolatedField> isolated;

  MigrationStatus get status =>
      isolated.isEmpty ? MigrationStatus.complete : MigrationStatus.partial;

  /// The vault version flag may advance to v3 only when nothing was isolated.
  bool get mayFlagV3 => isolated.isEmpty;
}

/// Migrates v2 fields to v3, explicitly and without laundering corruption.
class VaultV3Migration {
  VaultV3Migration({VaultV3Envelope? envelope})
      : _envelope = envelope ?? VaultV3Envelope();

  final VaultV3Envelope _envelope;

  /// A stable key for a field's slot (used as the [MigrationReport.migrated]
  /// map key and to make journalling/resume idempotent).
  static String slotKey(RecordContext c) {
    String hex(List<int> b) =>
        b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${hex(c.vaultId)}:${c.recordType.id}:${hex(c.recordId)}:${c.fieldId}';
  }

  /// Migrates [fields].
  ///
  /// [v2Decrypt] authenticates a v2 field and returns plaintext or null.
  /// [dataKey] is the v3 data subkey the new envelopes are sealed under.
  /// [alreadyDone] lets a resumed run skip slots already committed (idempotent).
  Future<MigrationReport> migrate({
    required List<MigrationField> fields,
    required V2FieldDecryptor v2Decrypt,
    required SecretKey dataKey,
    Set<String> alreadyDone = const <String>{},
  }) async {
    final migrated = <String, String>{};
    final isolated = <IsolatedField>[];
    var alreadyV3 = 0;

    for (final field in fields) {
      final key = slotKey(field.context);
      if (alreadyDone.contains(key)) {
        continue; // resume: committed in a previous run
      }

      // Explicit version decision — no trial decryption.
      final raw = _tryBase64(field.stored);
      if (raw != null && VaultV3Envelope.isV3(raw)) {
        alreadyV3++;
        continue;
      }

      // A pre-v3 field: authenticate under v2. Failure => ISOLATE, never
      // re-encrypt the raw bytes.
      final String? plain;
      try {
        plain = await v2Decrypt(field.stored);
      } catch (_) {
        isolated.add(IsolatedField(
          context: field.context,
          stored: field.stored,
          reason: 'v2 decryptor threw',
        ));
        continue;
      }

      if (plain == null) {
        isolated.add(IsolatedField(
          context: field.context,
          stored: field.stored,
          reason: 'v2 authentication failed (isolated, not re-encrypted)',
        ));
        continue;
      }

      // Authenticated v2 plaintext -> fresh v3 envelope bound to its slot.
      migrated[key] = await _envelope.encryptStringToBase64(
        plaintext: plain,
        key: dataKey,
        context: field.context,
      );
    }

    return MigrationReport(
      migrated: migrated,
      alreadyV3: alreadyV3,
      isolated: isolated,
    );
  }

  static Uint8List? _tryBase64(String s) {
    if (s.isEmpty) return null;
    try {
      return base64.decode(s);
    } on FormatException {
      return null;
    }
  }
}
