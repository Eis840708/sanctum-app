// Tests for the versioned Shamir recovery envelope + verified combine (V-08).
// DEV-P0-03 B2-4. Synthetic recovery keys only — no real vault, no real password.
//
// Proves: full-entropy R round-trips; commit = SHA-256(R) matches a known-answer
// vector; and reconstruction is FAIL-CLOSED — every malformed / insufficient /
// mixed / tampered share set raises an explicit ShamirVerifyException instead of
// silently returning a wrong secret (the V-08 defect).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_shamir.dart';

void main() {
  final s = VaultV3Shamir();

  // Fixed 32-byte synthetic recovery keys.
  final rZeros = Uint8List(32); // all 0x00
  final rSeq = Uint8List.fromList(List<int>.generate(32, (i) => i));

  group('commit (SHA-256 of R) known-answer', () {
    test('commit(0x00 * 32) matches the published SHA-256 vector', () async {
      final commit = await s.commitOf(rZeros);
      expect(_hex(commit),
          '66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925');
    });
  });

  group('round-trip split/combine over full-entropy R', () {
    test('any k of n shares reconstruct R (k=3, n=5)', () async {
      final set = await s.split(recoveryKey: rSeq, n: 5, k: 3);
      expect(set.threshold, 3);
      expect(set.total, 5);
      expect(set.shares, hasLength(5));

      // Every 3-subset (first three, last three, a spread) reconstructs R.
      for (final pick in [
        [0, 1, 2],
        [2, 3, 4],
        [0, 2, 4],
      ]) {
        final r = await s.combine(
          shares: [for (final i in pick) set.shares[i]],
          commit: set.commit,
        );
        expect(r, rSeq, reason: 'subset $pick failed to reconstruct');
      }
    });

    test('extra shares beyond threshold are accepted (all 5 for k=3)', () async {
      final set = await s.split(recoveryKey: rSeq, n: 5, k: 3);
      final r = await s.combine(shares: set.shares, commit: set.commit);
      expect(r, rSeq);
    });

    test('generateRecoveryKey produces 32 bytes and round-trips', () async {
      final r = s.generateRecoveryKey();
      expect(r, hasLength(32));
      final set = await s.split(recoveryKey: r, n: 4, k: 2);
      final out = await s.combine(
          shares: [set.shares[1], set.shares[3]], commit: set.commit);
      expect(out, r);
    });
  });

  group('fail-closed reconstruction (V-08 core: never a wrong secret)', () {
    late RecoveryShareSet set;
    setUp(() async {
      set = await s.split(recoveryKey: rSeq, n: 5, k: 3);
    });

    test('insufficient shares -> insufficientShares', () {
      expect(
        () => s.combine(shares: [set.shares[0], set.shares[1]], commit: set.commit),
        throwsCode(ShamirRejectCode.insufficientShares),
      );
    });

    test('duplicate index -> duplicateIndex', () {
      expect(
        () => s.combine(
            shares: [set.shares[0], set.shares[0], set.shares[1]],
            commit: set.commit),
        throwsCode(ShamirRejectCode.duplicateIndex),
      );
    });

    test('mixed sets -> setIdMismatch', () async {
      final other = await s.split(recoveryKey: rZeros, n: 5, k: 3);
      expect(
        () => s.combine(
            shares: [set.shares[0], set.shares[1], other.shares[2]],
            commit: set.commit),
        throwsCode(ShamirRejectCode.setIdMismatch),
      );
    });

    test('bit-flip in payload -> checksumFailed', () {
      final tampered = Uint8List.fromList(set.shares[0]);
      tampered[28] ^= 0xFF; // flip a payload byte, CRC now wrong
      expect(
        () => s.combine(
            shares: [tampered, set.shares[1], set.shares[2]], commit: set.commit),
        throwsCode(ShamirRejectCode.checksumFailed),
      );
    });

    test('truncated share -> malformedShare', () {
      final truncated =
          Uint8List.fromList(set.shares[0].sublist(0, set.shares[0].length - 6));
      expect(
        () => s.combine(
            shares: [truncated, set.shares[1], set.shares[2]], commit: set.commit),
        throwsCode(ShamirRejectCode.malformedShare),
      );
    });

    test('wrong magic -> magicMismatch', () {
      final bad = Uint8List.fromList(set.shares[0]);
      bad[0] ^= 0xFF;
      expect(
        () => s.combine(
            shares: [bad, set.shares[1], set.shares[2]], commit: set.commit),
        throwsCode(ShamirRejectCode.magicMismatch),
      );
    });

    test('unknown version -> unknownVersion', () {
      final bad = Uint8List.fromList(set.shares[0]);
      bad[5] = 0x04; // version byte
      expect(
        () => s.combine(
            shares: [bad, set.shares[1], set.shares[2]], commit: set.commit),
        throwsCode(ShamirRejectCode.unknownVersion),
      );
    });

    test('tampered-but-CRC-valid share -> commitMismatch (commit is authority)',
        () async {
      // Re-encode share 0 with a mutated payload so CRC is valid but the value
      // is wrong. A malicious holder cannot make the result equal R.
      final p = s.decodeShare(set.shares[0]);
      final badPayload = Uint8List.fromList(p.payload);
      badPayload[0] ^= 0xFF;
      final forged = s.encodeShare(ParsedShare(
        version: p.version,
        setId: p.setId,
        threshold: p.threshold,
        total: p.total,
        index: p.index,
        payload: badPayload,
      ));
      // CRC must pass (proves the check below is the commit, not the checksum).
      expect(() => s.decodeShare(forged), returnsNormally);
      expect(
        () => s.combine(
            shares: [forged, set.shares[1], set.shares[2]], commit: set.commit),
        throwsCode(ShamirRejectCode.commitMismatch),
      );
    });

    test('inconsistent threshold across shares -> thresholdMismatch', () {
      final p = s.decodeShare(set.shares[0]);
      final forged = s.encodeShare(ParsedShare(
        version: p.version,
        setId: p.setId,
        threshold: 4, // differs from the set's k=3
        total: p.total,
        index: p.index,
        payload: p.payload,
      ));
      expect(
        () => s.combine(
            shares: [forged, set.shares[1], set.shares[2]], commit: set.commit),
        throwsCode(ShamirRejectCode.thresholdMismatch),
      );
    });

    test('empty share list -> insufficientShares', () {
      expect(
        () => s.combine(shares: [], commit: set.commit),
        throwsCode(ShamirRejectCode.insufficientShares),
      );
    });
  });
}

Matcher throwsCode(ShamirRejectCode code) => throwsA(
      isA<ShamirVerifyException>().having((e) => e.code, 'code', code),
    );

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
