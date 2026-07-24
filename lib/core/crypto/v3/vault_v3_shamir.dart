// Versioned Shamir recovery-share envelope with verified reconstruction.
// DEV-P0-03 B2-4 (findings V-08, and V-07 distribution at the UI layer).
// Design freeze: design-spec.md §2.4, backup-schema-v3.md §6 (v1.1 DR-01/DR-02),
// Phase-B v1.1 revision §二/§三.
//
// This module is the DEK-free crypto core of the V-08 fix. It does NOT wire the
// recovery key into the live vault (R -> unwrap DEK -> access): that live
// integration is deferred to B2-5a, once the v3 DEK/KEK hierarchy is live. Here
// we build and verify the share format only, over a full-entropy recovery key R.
//
// Root-cause fix (DR-01): Shamir splits a full-entropy 256-bit recovery key R,
// NEVER the master password. The public commitment commit = SHA-256(R) is safe to
// store because R carries 256 bits of entropy — unlike SHA-256(password), it is
// not a brute-force oracle.
//
// Integrity (DR-02): per-share CRC32 detects ACCIDENTAL damage only (honestly
// labelled — not forgery resistance); the authoritative integrity check is the
// post-combine commit comparison SHA-256(combined) == commit, which rejects any
// reconstruction that is not exactly R. There is no set_mac_key.
//
// Reconstruction is fail-closed: every pre-combine check and the final commit
// check raises an explicit [ShamirVerifyException]; a wrong/insufficient/tampered
// share set NEVER silently returns a wrong secret.

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../shamir_service.dart';

/// Why a share set was rejected before/after reconstruction.
enum ShamirRejectCode {
  magicMismatch,
  unknownVersion,
  malformedShare,
  checksumFailed,
  setIdMismatch,
  duplicateIndex,
  thresholdMismatch,
  insufficientShares,
  commitMismatch,
}

/// Raised on any share-format or reconstruction failure. Reaching combine with a
/// bad set throws this instead of returning a wrong secret.
class ShamirVerifyException implements Exception {
  const ShamirVerifyException(this.code, this.message);

  final ShamirRejectCode code;
  final String message;

  @override
  String toString() => 'ShamirVerifyException(${code.name}): $message';
}

/// A decoded (and CRC-checked) share envelope.
class ParsedShare {
  const ParsedShare({
    required this.version,
    required this.setId,
    required this.threshold,
    required this.total,
    required this.index,
    required this.payload,
  });

  final int version;
  final Uint8List setId; // 16 bytes
  final int threshold;
  final int total;
  final int index; // GF(256) evaluation point x, 1..total
  final Uint8List payload; // share y-bytes of R
}

/// The output of splitting a recovery key: the encoded share envelopes plus the
/// public commitment to publish alongside them (in meta / backup header).
class RecoveryShareSet {
  const RecoveryShareSet({
    required this.setId,
    required this.threshold,
    required this.total,
    required this.shares,
    required this.commit,
  });

  final Uint8List setId;
  final int threshold;
  final int total;
  final List<Uint8List> shares; // encoded envelopes (bytes)
  final Uint8List commit; // SHA-256(R)
}

/// Builds and verifies versioned Shamir recovery shares over a full-entropy key.
class VaultV3Shamir {
  VaultV3Shamir({ShamirService? shamir}) : _shamir = shamir ?? shamirService;

  final ShamirService _shamir;

  static const List<int> _magic = [0x53, 0x4E, 0x43, 0x53, 0x33]; // "SNCS3"
  static const int _version = 0x03;
  static const int _setIdLen = 16;
  static const int _recoveryKeyLen = 32;

  // magic(5) + version(1) + set_id(16) + threshold(1) + total(1) + index(1)
  // + payload_len(2) + payload(N) + crc32(4)
  static const int _headerLen = 5 + 1 + _setIdLen + 1 + 1 + 1 + 2;
  static const int _crcLen = 4;

  /// A fresh full-entropy recovery key R (256-bit CSPRNG).
  Uint8List generateRecoveryKey() => _randomBytes(_recoveryKeyLen);

  /// commit = SHA-256(R). Safe to publish (R is full entropy).
  Future<Uint8List> commitOf(List<int> recoveryKey) async {
    final digest = await Sha256().hash(recoveryKey);
    return Uint8List.fromList(digest.bytes);
  }

  /// Splits [recoveryKey] into [n] shares, any [k] of which reconstruct it.
  /// Returns the encoded envelopes plus commit = SHA-256(R).
  Future<RecoveryShareSet> split({
    required Uint8List recoveryKey,
    required int n,
    required int k,
    Uint8List? setId,
  }) async {
    if (k < 2 || n < k || n > 255) {
      throw ArgumentError('invalid (n=$n, k=$k): need 2<=k<=n<=255');
    }
    final sid = setId ?? _randomBytes(_setIdLen);
    if (sid.length != _setIdLen) {
      throw ArgumentError('setId must be $_setIdLen bytes');
    }
    final rawShares = _shamir.split(recoveryKey, n, k); // each: [x, ...y]
    final encoded = <Uint8List>[];
    for (final rs in rawShares) {
      encoded.add(encodeShare(ParsedShare(
        version: _version,
        setId: sid,
        threshold: k,
        total: n,
        index: rs[0],
        payload: Uint8List.fromList(rs.sublist(1)),
      )));
    }
    return RecoveryShareSet(
      setId: sid,
      threshold: k,
      total: n,
      shares: encoded,
      commit: await commitOf(recoveryKey),
    );
  }

  /// Reconstructs R from [shares], fail-closed.
  ///
  /// Pre-combine: every share decodes + CRC-passes; all share a set_id; indices
  /// are unique; threshold/total agree; at least `threshold` shares are present
  /// (extras beyond threshold are ignored). Post-combine: SHA-256(result) must
  /// equal [commit]. Any failure raises [ShamirVerifyException].
  Future<Uint8List> combine({
    required List<Uint8List> shares,
    required Uint8List commit,
  }) async {
    if (shares.isEmpty) {
      throw const ShamirVerifyException(
          ShamirRejectCode.insufficientShares, 'no shares provided');
    }
    final parsed = shares.map(decodeShare).toList();

    final first = parsed.first;
    for (final p in parsed) {
      if (!_bytesEqual(p.setId, first.setId)) {
        throw const ShamirVerifyException(
            ShamirRejectCode.setIdMismatch, 'shares belong to different sets');
      }
      if (p.threshold != first.threshold || p.total != first.total) {
        throw const ShamirVerifyException(ShamirRejectCode.thresholdMismatch,
            'inconsistent threshold/total across shares');
      }
    }

    final seen = <int>{};
    for (final p in parsed) {
      if (!seen.add(p.index)) {
        throw ShamirVerifyException(
            ShamirRejectCode.duplicateIndex, 'duplicate share index ${p.index}');
      }
    }

    final threshold = first.threshold;
    if (parsed.length < threshold) {
      throw ShamirVerifyException(ShamirRejectCode.insufficientShares,
          'need $threshold shares, got ${parsed.length}');
    }

    // Extras beyond threshold are ignored; commit is the authority on the result.
    final selected = parsed.take(threshold).toList();
    final rawShares = selected
        .map((p) => Uint8List.fromList([p.index, ...p.payload]))
        .toList();
    final r = Uint8List.fromList(_shamir.combine(rawShares));

    final calc = await commitOf(r);
    if (!_bytesEqual(calc, commit)) {
      throw const ShamirVerifyException(ShamirRejectCode.commitMismatch,
          'reconstructed secret does not match commitment');
    }
    return r;
  }

  /// Serialises a share to its byte envelope (with trailing CRC32).
  Uint8List encodeShare(ParsedShare s) {
    if (s.payload.length > 0xFFFF) {
      throw ArgumentError('payload too large');
    }
    final body = BytesBuilder();
    body.add(_magic);
    body.addByte(_version);
    body.add(s.setId);
    body.addByte(s.threshold & 0xFF);
    body.addByte(s.total & 0xFF);
    body.addByte(s.index & 0xFF);
    body.addByte((s.payload.length >> 8) & 0xFF);
    body.addByte(s.payload.length & 0xFF);
    body.add(s.payload);
    final bytes = body.toBytes();
    final crc = _crc32(bytes);
    final out = BytesBuilder()
      ..add(bytes)
      ..addByte((crc >> 24) & 0xFF)
      ..addByte((crc >> 16) & 0xFF)
      ..addByte((crc >> 8) & 0xFF)
      ..addByte(crc & 0xFF);
    return out.toBytes();
  }

  /// Parses + CRC-checks a share envelope. Throws [ShamirVerifyException] on any
  /// structural / version / checksum problem.
  ParsedShare decodeShare(Uint8List raw) {
    if (raw.length < _headerLen + _crcLen) {
      throw const ShamirVerifyException(
          ShamirRejectCode.malformedShare, 'share too short');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (raw[i] != _magic[i]) {
        throw const ShamirVerifyException(
            ShamirRejectCode.magicMismatch, 'bad magic');
      }
    }
    final version = raw[5];
    if (version != _version) {
      throw ShamirVerifyException(
          ShamirRejectCode.unknownVersion, 'unsupported share version $version');
    }
    final setId = Uint8List.fromList(raw.sublist(6, 6 + _setIdLen));
    final threshold = raw[22];
    final total = raw[23];
    final index = raw[24];
    final payloadLen = (raw[25] << 8) | raw[26];
    const payloadStart = _headerLen;
    final payloadEnd = payloadStart + payloadLen;
    if (raw.length != payloadEnd + _crcLen) {
      throw const ShamirVerifyException(
          ShamirRejectCode.malformedShare, 'declared length mismatch');
    }
    final stored = (raw[payloadEnd] << 24) |
        (raw[payloadEnd + 1] << 16) |
        (raw[payloadEnd + 2] << 8) |
        raw[payloadEnd + 3];
    final calc = _crc32(raw.sublist(0, payloadEnd));
    if ((stored & 0xFFFFFFFF) != calc) {
      throw const ShamirVerifyException(
          ShamirRejectCode.checksumFailed, 'CRC32 mismatch (accidental damage)');
    }
    if (threshold < 2 || total < threshold || index < 1 || index > total) {
      throw const ShamirVerifyException(
          ShamirRejectCode.malformedShare, 'invalid threshold/total/index');
    }
    return ParsedShare(
      version: version,
      setId: setId,
      threshold: threshold,
      total: total,
      index: index,
      payload: Uint8List.fromList(raw.sublist(payloadStart, payloadEnd)),
    );
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  static Uint8List _randomBytes(int n) {
    final rng = Random.secure();
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = rng.nextInt(256);
    }
    return b;
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static final List<int> _crcTable = _buildCrcTable();

  static List<int> _buildCrcTable() {
    final table = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var j = 0; j < 8; j++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[i] = c;
    }
    return table;
  }

  static int _crc32(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final b in bytes) {
      crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >>> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}

final vaultV3Shamir = VaultV3Shamir();
