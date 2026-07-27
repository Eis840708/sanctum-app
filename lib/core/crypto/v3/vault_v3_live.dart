// Live DEK integration glue for create/unlock (DEV-P0-03 B2-5a, plan ruling A).
//
// Wires the already-built v3 key hierarchy (vault_v3_keys.dart, B2-1/B2-2) into
// the live vault for NEW vaults only:
//
//   create:  DEK <- CSPRNG; KEK <- Argon2id(password, descriptor);
//            wrappedDEK = wrap(DEK, KEK); dataKey = HKDF(DEK) -> session key
//   unlock:  KEK <- Argon2id(password, descriptor); DEK = unwrap(wrappedDEK, KEK);
//            dataKey = HKDF(DEK) -> session key  (wrong password => unwrap fails)
//
// Existing v2 vaults are NOT touched here — VaultService.unlock branches on
// meta.version and keeps the v2 path byte-for-byte unchanged. Existing-vault
// migration (re-encrypt records under the DEK = full-record encryption) is B2-5b.
//
// KEK parameters are provisional above-floor Argon2id (19 MiB / t2 / p1, the
// OWASP floor). Because the descriptor is self-describing and the DEK is
// independent of the password, the release-gate on-device measurement can later
// raise them via a KEK re-wrap WITHOUT re-encrypting any record.
//
// This module holds no Hive/secure-storage code; VaultV3Material serialises to a
// plain map that the caller persists durably (survives a secure-storage wipe —
// a random DEK, unlike a password-derived key, cannot be re-derived).

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'vault_v3_envelope.dart' show VaultV3;
import 'vault_v3_keys.dart';

/// Durable per-vault v3 key material. Persisted (Hive) so it survives a
/// secure-storage wipe; the wrapped DEK is encrypted, safe at rest.
class VaultV3Material {
  VaultV3Material({
    required this.vaultId,
    required this.wrappedDek,
    required this.descriptor,
    this.recoveryWrappedDek,
    this.recoveryCommit,
  });

  final Uint8List vaultId; // 16 bytes
  final WrappedDek wrappedDek; // password-KEK wrapped DEK
  final KdfDescriptor descriptor; // Argon2id params + salt (self-describing)

  /// V-08 recovery: DEK wrapped under the full-entropy recovery key R, plus the
  /// public commitment SHA-256(R). Null until the user opts into recovery.
  final WrappedDek? recoveryWrappedDek;
  final Uint8List? recoveryCommit;

  VaultV3Material withRecovery({
    required WrappedDek recoveryWrappedDek,
    required Uint8List recoveryCommit,
  }) =>
      VaultV3Material(
        vaultId: vaultId,
        wrappedDek: wrappedDek,
        descriptor: descriptor,
        recoveryWrappedDek: recoveryWrappedDek,
        recoveryCommit: recoveryCommit,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'vault_id': base64.encode(vaultId),
        'wrapped_dek': wrappedDek.toJson(),
        'kdf': descriptor.toJson(),
        if (recoveryWrappedDek != null)
          'recovery_dek': recoveryWrappedDek!.toJson(),
        if (recoveryCommit != null)
          'recovery_commit': base64.encode(recoveryCommit!),
      };

  static VaultV3Material fromJson(Map<String, Object?> json) {
    final rec = json['recovery_dek'];
    final commit = json['recovery_commit'];
    return VaultV3Material(
      vaultId: base64.decode(json['vault_id']! as String),
      wrappedDek: WrappedDek.fromJson(
          (json['wrapped_dek']! as Map).cast<String, Object?>()),
      descriptor:
          KdfDescriptor.fromJson((json['kdf']! as Map).cast<String, Object?>()),
      recoveryWrappedDek:
          rec == null ? null : WrappedDek.fromJson((rec as Map).cast<String, Object?>()),
      recoveryCommit: commit == null ? null : base64.decode(commit as String),
    );
  }

  String encode() => jsonEncode(toJson());

  static VaultV3Material decode(String s) =>
      fromJson((jsonDecode(s) as Map).cast<String, Object?>());
}

/// Result of creating a new v3 vault: the material to persist plus the data
/// subkey used as the live session key.
class V3CreateResult {
  const V3CreateResult({required this.material, required this.dataKey});
  final VaultV3Material material;
  final SecretKey dataKey;
}

/// Creates and unlocks v3 vault key material. No storage side effects.
class VaultV3Live {
  VaultV3Live({VaultV3KeyHierarchy? hierarchy})
      : _kh = hierarchy ?? VaultV3KeyHierarchy();

  final VaultV3KeyHierarchy _kh;

  static const int keyGenerationInitial = 0;

  /// Builds a fresh v3 key hierarchy for a new vault.
  Future<V3CreateResult> create(String password) async {
    final vaultId = _kh.randomBytes(VaultV3.uuidBytes);
    final dek = _kh.generateDek();
    final descriptor = KdfDescriptor.forNewParameters(
      salt: _kh.generateSalt(),
      normalization: PasswordNormalization.nfc,
    );
    final kek = await _kh.deriveKek(password: password, descriptor: descriptor);
    final wrapped = await _kh.wrapDekWithKek(
      dek: dek,
      kek: kek,
      vaultId: vaultId,
      keyGeneration: keyGenerationInitial,
    );
    final keys = await _kh.deriveSubkeys(
      dek: dek,
      vaultId: vaultId,
      keyGeneration: keyGenerationInitial,
    );
    return V3CreateResult(
      material: VaultV3Material(
        vaultId: vaultId,
        wrappedDek: wrapped,
        descriptor: descriptor,
      ),
      dataKey: keys.dataKey,
    );
  }

  /// Unlocks a v3 vault, returning the data subkey. Throws
  /// [VaultV3KeyException] when the password is wrong (the wrapped-DEK AEAD tag
  /// fails to authenticate — this is the v3 password check, no separate
  /// verifyHash needed).
  Future<SecretKey> unlock(String password, VaultV3Material material) async {
    final keys = await _kh.unlockWithPassword(
      password: password,
      descriptor: material.descriptor,
      wrappedDek: material.wrappedDek,
      vaultId: material.vaultId,
    );
    return keys.dataKey;
  }
}

final vaultV3Live = VaultV3Live();
