// Tests for V-08 recovery live wiring (DEV-P0-03 B2-5a). Synthetic DEK only.
//
// Proves the DEK round-trips through Shamir recovery and that reconstruction is
// fail-closed end-to-end: insufficient/tampered shares raise explicit errors, and
// a recovered R bound to the wrong vault fails the wrap AEAD — never a wrong DEK.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_keys.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_recovery.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_shamir.dart';

void main() {
  final recovery = VaultV3Recovery();

  final dek = Uint8List.fromList(List<int>.generate(32, (i) => (i * 7) & 0xFF));
  final vaultId = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));

  test('enable then recover reconstructs the exact DEK', () async {
    final en = await recovery.enable(dek: dek, vaultId: vaultId, n: 5, k: 3);
    expect(en.shares, hasLength(5));
    expect(en.commit, hasLength(32));

    final got = await recovery.recoverDek(
      shares: [en.shares[0], en.shares[2], en.shares[4]],
      commit: en.commit,
      recoveryWrappedDek: en.recoveryWrappedDek,
      vaultId: vaultId,
    );
    expect(got, dek);
  });

  test('insufficient shares -> fail-closed (insufficientShares)', () async {
    final en = await recovery.enable(dek: dek, vaultId: vaultId, n: 5, k: 3);
    await expectLater(
      recovery.recoverDek(
        shares: [en.shares[0], en.shares[1]],
        commit: en.commit,
        recoveryWrappedDek: en.recoveryWrappedDek,
        vaultId: vaultId,
      ),
      throwsA(isA<ShamirVerifyException>()
          .having((e) => e.code, 'code', ShamirRejectCode.insufficientShares)),
    );
  });

  test('tampered (bit-flipped) share -> fail-closed (checksumFailed)', () async {
    final en = await recovery.enable(dek: dek, vaultId: vaultId, n: 5, k: 3);
    final bad = Uint8List.fromList(en.shares[0]);
    bad[28] ^= 0xFF;
    await expectLater(
      recovery.recoverDek(
        shares: [bad, en.shares[1], en.shares[2]],
        commit: en.commit,
        recoveryWrappedDek: en.recoveryWrappedDek,
        vaultId: vaultId,
      ),
      throwsA(isA<ShamirVerifyException>()
          .having((e) => e.code, 'code', ShamirRejectCode.checksumFailed)),
    );
  });

  test('recovered R bound to a wrong vault fails the wrap AEAD', () async {
    final en = await recovery.enable(dek: dek, vaultId: vaultId, n: 5, k: 3);
    final wrongVault = Uint8List.fromList(List<int>.generate(16, (i) => 200 + i));
    // R reconstructs (commit passes) but the wrap AAD is bound to the real vault,
    // so unwrapping under a different vaultId is rejected.
    await expectLater(
      recovery.recoverDek(
        shares: [en.shares[0], en.shares[1], en.shares[2]],
        commit: en.commit,
        recoveryWrappedDek: en.recoveryWrappedDek,
        vaultId: wrongVault,
      ),
      throwsA(isA<VaultV3KeyException>()),
    );
  });
}
