// V-08 recovery live wiring — Shamir recovery of the DEK (DEV-P0-03 B2-5a).
// Design freeze: design-spec v1.1 §2.4, backup-schema v1.1 §6 (DR-01/DR-02).
//
// v3 vaults only. Recovery splits a full-entropy key R (never the password);
// R wraps the DEK. On recovery, ≥ threshold shares reconstruct R (fail-closed via
// vault_v3_shamir: explicit errors, commit is the integrity authority), then R
// unwraps the DEK — after which the caller MUST force a master-password reset
// (re-wrap the DEK under a fresh KEK). This module is pure crypto orchestration
// over the existing key hierarchy + Shamir envelope; no Hive, no password.

import 'dart:typed_data';

import 'vault_v3_keys.dart';
import 'vault_v3_shamir.dart';

/// Output of enabling recovery: the DEK wrapped under R, its public commitment,
/// and the distributable share envelopes. The caller persists the first two in
/// the vault material and distributes the shares one-per-destination (V-07).
class RecoveryEnableResult {
  const RecoveryEnableResult({
    required this.recoveryWrappedDek,
    required this.commit,
    required this.shares,
    required this.setId,
  });

  final WrappedDek recoveryWrappedDek;
  final Uint8List commit; // SHA-256(R)
  final List<Uint8List> shares; // encoded envelopes
  final Uint8List setId;
}

/// Wires the Shamir recovery envelope to the live DEK.
class VaultV3Recovery {
  VaultV3Recovery({VaultV3KeyHierarchy? hierarchy, VaultV3Shamir? shamir})
      : _kh = hierarchy ?? VaultV3KeyHierarchy(),
        _shamir = shamir ?? vaultV3Shamir;

  final VaultV3KeyHierarchy _kh;
  final VaultV3Shamir _shamir;

  /// Enables recovery for an unlocked vault whose [dek] is known.
  ///
  /// Generates a full-entropy R, wraps [dek] under R, and splits R into [n]
  /// shares (any [k] reconstruct). commit = SHA-256(R) is returned to publish
  /// alongside the shares.
  Future<RecoveryEnableResult> enable({
    required Uint8List dek,
    required Uint8List vaultId,
    required int n,
    required int k,
    int keyGeneration = 0,
  }) async {
    final r = _kh.generateRecoveryKey();
    final recoveryWrapped = await _kh.wrapDekWithRecoveryKey(
      dek: dek,
      recoveryKey: r,
      vaultId: vaultId,
      keyGeneration: keyGeneration,
    );
    final split = await _shamir.split(recoveryKey: r, n: n, k: k);
    return RecoveryEnableResult(
      recoveryWrappedDek: recoveryWrapped,
      commit: split.commit,
      shares: split.shares,
      setId: split.setId,
    );
  }

  /// Recovers the DEK from [shares].
  ///
  /// Reconstruction is fail-closed (vault_v3_shamir raises
  /// [ShamirVerifyException] on insufficient/mixed/tampered shares or a commit
  /// mismatch — never a wrong secret). The recovered R then unwraps the DEK; a
  /// wrong R also fails the wrap AEAD ([VaultV3KeyException]). The caller must
  /// force a password reset afterwards.
  Future<Uint8List> recoverDek({
    required List<Uint8List> shares,
    required Uint8List commit,
    required WrappedDek recoveryWrappedDek,
    required Uint8List vaultId,
  }) async {
    final r = await _shamir.combine(shares: shares, commit: commit);
    return _kh.unwrapDekWithRecoveryKey(
      wrapped: recoveryWrappedDek,
      recoveryKey: r,
      vaultId: vaultId,
    );
  }
}

final vaultV3Recovery = VaultV3Recovery();
