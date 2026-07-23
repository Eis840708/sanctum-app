// Vault v3 fail-closed decryption contract (findings V-03;
// findings-response-matrix V-03). DEV-P0-03-B2-2.
//
// Replaces the v2 fail-open pattern (`_safeDecrypt` returning its raw input on
// failure). A v3 field read yields a typed [DecryptOutcome]; a failure is an
// explicit state the UI renders as "cannot decrypt", never the attacker- or
// corruption-controlled bytes shown as plaintext.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'vault_v3_envelope.dart';

/// Why a field could not be produced as trusted plaintext.
enum DecryptFailureReason {
  /// Payload is malformed (bad base64, too short, unknown version/alg, or not a
  /// v3 envelope at all).
  malformed,

  /// Authentication failed: wrong key, tampered ciphertext, or wrong AAD
  /// context (e.g. a ciphertext moved to a different field/record/vault).
  authentication,

  /// Plaintext bytes were not valid UTF-8.
  encoding,
}

/// The outcome of reading one encrypted field.
///
/// On success either [plaintext] (v3) or [legacyPlaintext] (migration only) is
/// set. On failure both are null and [reason] is set. No path returns the
/// ciphertext or raw input as if it were plaintext.
class DecryptOutcome {
  const DecryptOutcome._({this.plaintext, this.legacyPlaintext, this.reason});

  /// Authenticated v3 plaintext.
  factory DecryptOutcome.ok(String plaintext) =>
      DecryptOutcome._(plaintext: plaintext);

  /// A value that an EXPLICIT version marker (not trial decryption) says is a
  /// pre-v3 legacy plaintext, surfaced only inside the migration path.
  factory DecryptOutcome.legacyPlaintext(String value) =>
      DecryptOutcome._(legacyPlaintext: value);

  /// A field that cannot be produced as trusted plaintext.
  factory DecryptOutcome.failure(DecryptFailureReason reason) =>
      DecryptOutcome._(reason: reason);

  final String? plaintext;
  final String? legacyPlaintext;
  final DecryptFailureReason? reason;

  bool get isOk => plaintext != null;
  bool get isFailure => reason != null;

  /// The value to display, or null when the field must show a "cannot decrypt"
  /// placeholder. Never returns raw ciphertext/input.
  String? get displayableOrNull => plaintext ?? legacyPlaintext;
}

/// Reads v3 fields into [DecryptOutcome]s. Fail-closed: never throws to the
/// caller for a bad payload, and never yields the input as plaintext.
class VaultV3FieldReader {
  VaultV3FieldReader({VaultV3Envelope? envelope})
      : _envelope = envelope ?? VaultV3Envelope();

  final VaultV3Envelope _envelope;

  /// Decrypts a Base64 v3 field. An empty stored value maps to empty plaintext
  /// (an absent optional field), matching how the product stores "no value".
  Future<DecryptOutcome> readField({
    required String stored,
    required SecretKey key,
    required RecordContext context,
  }) async {
    if (stored.isEmpty) return DecryptOutcome.ok('');

    final Uint8List raw;
    try {
      raw = base64.decode(stored);
    } on FormatException {
      return DecryptOutcome.failure(DecryptFailureReason.malformed);
    }

    // Version is decided by the explicit marker, never by trial decryption.
    if (!VaultV3Envelope.isV3(raw)) {
      return DecryptOutcome.failure(DecryptFailureReason.malformed);
    }

    try {
      final clear = await _envelope.decrypt(
        envelope: raw,
        key: key,
        context: context,
      );
      return DecryptOutcome.ok(utf8.decode(clear));
    } on VaultV3FormatException {
      return DecryptOutcome.failure(DecryptFailureReason.malformed);
    } on SecretBoxAuthenticationError {
      return DecryptOutcome.failure(DecryptFailureReason.authentication);
    } on FormatException {
      // utf8.decode on non-UTF-8 bytes.
      return DecryptOutcome.failure(DecryptFailureReason.encoding);
    }
  }
}
