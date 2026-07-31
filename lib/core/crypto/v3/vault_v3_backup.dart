// v3 backup container — two-layer authenticated backup (DEV-P0-03-UI 子項 A).
// Design freeze: backup-schema-v3.md §2/§3/§4 + backup-material ruling
// (DEV-P0-03-A-backup-material-ruling-v1) §(a): the header embeds the full
// VaultV3Material so a new device can rebuild the DEK from the master password.
//
// Container (big-endian):
//   0            5   magic "SNCB3"
//   5            1   container_version = 0x03
//   6            2   header_len (uint16)
//   8   header_len   header_json (UTF-8)   -- carries VaultV3Material, counts
//   +N  12           nonce
//   +12 M            ciphertext = AES-256-GCM(inner_records_json, key=backup_key)
//   +M  16           tag
//
// Two layers (honest "2-layer", release-gate "AES-256 full encryption"):
//   * inner  — inner_records_json is the v3 boxes' on-disk values COPIED VERBATIM
//              (each field already a data_key AES-GCM envelope with V-06 per-field
//              AAD). Backup never decrypts a record: no plaintext ever materialises.
//   * outer  — the whole inner_records_json is sealed again under backup_key
//              (HKDF(DEK, 'sanctum/v3/backup'), KeyScope.backup). The header bytes
//              are the GCM AAD, so truncation / header tampering fails the tag.
//
// This module is PURE: no Hive / secure-storage / Flutter. The Hive glue (reading
// the v3 boxes, the transactional restore) lives in vault_v3_backup_hive.dart.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'vault_v3_keys.dart';
import 'vault_v3_live.dart' show VaultV3Material;

/// Backup container header field values.
class BackupV3 {
  BackupV3._();

  static const List<int> magic = <int>[0x53, 0x4E, 0x43, 0x42, 0x33]; // "SNCB3"
  static const int containerVersion = 0x03;
  static const int containerAlgAesGcm256 = 0x01;

  static const int magicLength = 5;
  static const int versionOffset = 5;
  static const int headerLenOffset = 6;
  static const int headerOffset = 8; // magic(5)+version(1)+header_len(2)
  static const int nonceLength = 12;
  static const int tagLength = 16;

  /// Current backup container schema (matches kV3SchemaVersion for records).
  static const int schemaVersion = 1;

  /// Guard: refuse absurd header sizes before allocating (defence in depth).
  static const int maxHeaderLen = 1 << 20; // 1 MiB of header JSON is already huge
}

/// Raised on any malformed / tampered / unauthenticated backup container.
///
/// Fail-closed by construction: a rejected container never yields partial data.
class BackupFormatException implements Exception {
  const BackupFormatException(this.reason);
  final String reason;
  @override
  String toString() => 'BackupFormatException: $reason';
}

/// The keys needed to seal/open a backup, derived from the master password.
class BackupKeys {
  const BackupKeys({
    required this.dek,
    required this.dataKey,
    required this.backupKey,
  });

  final Uint8List dek;
  final SecretKey dataKey; // opens the inner per-field envelopes after restore
  final SecretKey backupKey; // opens the outer container body
}

/// Parsed, still-unauthenticated backup header. Building one performs NO crypto:
/// the body is authenticated only in [VaultV3Backup.decodeBody].
class BackupHeader {
  const BackupHeader({
    required this.material,
    required this.schemaVersion,
    required this.recordCounts,
    required this.headerPrefix,
    required this.bodyOffset,
  });

  /// Full key material embedded per the backup-material ruling §(a).
  final VaultV3Material material;
  final int schemaVersion;
  final Map<String, int> recordCounts;

  /// The exact leading bytes (magic..header_json inclusive) used as the outer
  /// GCM AAD — read back verbatim so encrypt and decrypt bind identical bytes.
  final Uint8List headerPrefix;
  final int bodyOffset;
}

/// Builds and opens the v3 backup container.
class VaultV3Backup {
  VaultV3Backup({Random? random, AesGcm? aesGcm, VaultV3KeyHierarchy? hierarchy})
      : _random = random ?? Random.secure(),
        _aesGcm = aesGcm ?? AesGcm.with256bits(),
        _kh = hierarchy ?? VaultV3KeyHierarchy();

  final Random _random;
  final AesGcm _aesGcm;
  final VaultV3KeyHierarchy _kh;

  /// Re-derives the DEK-based key set from the master password + embedded
  /// material. A wrong password fails the wrapped-DEK AEAD tag and throws
  /// [VaultV3KeyException] (the backup's password check — no separate verifyHash).
  Future<BackupKeys> deriveKeys({
    required String password,
    required VaultV3Material material,
  }) async {
    final kek =
        await _kh.deriveKek(password: password, descriptor: material.descriptor);
    final dek = await _kh.unwrapDekWithKek(
      wrapped: material.wrappedDek,
      kek: kek,
      vaultId: material.vaultId,
    );
    final keys = await _kh.deriveSubkeys(
      dek: dek,
      vaultId: material.vaultId,
      keyGeneration: material.wrappedDek.keyGeneration,
    );
    return BackupKeys(dek: dek, dataKey: keys.dataKey, backupKey: keys.backupKey);
  }

  /// Encodes a backup container. [recordsByBox] maps a stable box token to
  /// {recordId -> raw on-disk stored string}; values are copied verbatim (already
  /// encrypted), never decrypted here. [backupKey] seals the outer layer.
  Future<Uint8List> encode({
    required VaultV3Material material,
    required Map<String, Map<String, String>> recordsByBox,
    required SecretKey backupKey,
    required DateTime createdAt,
    int schemaVersion = BackupV3.schemaVersion,
  }) async {
    final counts = <String, int>{
      for (final e in recordsByBox.entries) e.key: e.value.length,
    };
    final headerMap = <String, Object?>{
      'v': BackupV3.containerVersion,
      'schemaVersion': schemaVersion,
      'containerAlg': BackupV3.containerAlgAesGcm256,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'recordCounts': counts,
      // Ruling §(a): full material (vaultId + wrappedDek + descriptor + optional
      // recovery) so a new device rebuilds the DEK from the master password.
      'material': material.toJson(),
    };
    final headerBytes = utf8.encode(jsonEncode(headerMap));
    if (headerBytes.length > BackupV3.maxHeaderLen) {
      throw const BackupFormatException('header too large');
    }
    final prefix = _buildPrefix(headerBytes);

    final plaintext = utf8.encode(jsonEncode(recordsByBox));
    final nonce =
        List<int>.generate(BackupV3.nonceLength, (_) => _random.nextInt(256));
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: backupKey,
      nonce: nonce,
      aad: prefix,
    );
    return (BytesBuilder(copy: false)
          ..add(prefix)
          ..add(box.nonce)
          ..add(box.cipherText)
          ..add(box.mac.bytes))
        .toBytes();
  }

  Uint8List _buildPrefix(List<int> headerBytes) {
    final len = headerBytes.length;
    final out = BytesBuilder(copy: false)
      ..add(BackupV3.magic)
      ..addByte(BackupV3.containerVersion)
      ..addByte((len >> 8) & 0xFF)
      ..addByte(len & 0xFF)
      ..add(headerBytes);
    return out.toBytes();
  }

  /// Returns true when [bytes] carries the backup magic + container version.
  /// Version is decided by this explicit marker, never by trial decryption
  /// (design §4 version negotiation; guards the V-04 class of defect).
  static bool isBackupV3(List<int> bytes) {
    if (bytes.length < BackupV3.headerOffset) return false;
    for (var i = 0; i < BackupV3.magic.length; i++) {
      if (bytes[i] != BackupV3.magic[i]) return false;
    }
    return bytes[BackupV3.versionOffset] == BackupV3.containerVersion;
  }

  /// Parses + validates the plaintext header. No body authentication yet.
  /// Rejects unknown magic / version explicitly (design §4).
  BackupHeader parseHeader(Uint8List bytes) {
    if (!isBackupV3(bytes)) {
      throw const BackupFormatException('not a v3 backup container');
    }
    final headerLen =
        (bytes[BackupV3.headerLenOffset] << 8) | bytes[BackupV3.headerLenOffset + 1];
    if (headerLen <= 0 || headerLen > BackupV3.maxHeaderLen) {
      throw const BackupFormatException('invalid header length');
    }
    final bodyOffset = BackupV3.headerOffset + headerLen;
    if (bytes.length < bodyOffset + BackupV3.nonceLength + BackupV3.tagLength) {
      throw const BackupFormatException('container shorter than minimum');
    }
    final headerBytes = bytes.sublist(BackupV3.headerOffset, bodyOffset);
    late final Map<String, Object?> headerMap;
    try {
      headerMap = (jsonDecode(utf8.decode(headerBytes)) as Map).cast<String, Object?>();
    } catch (_) {
      throw const BackupFormatException('header is not valid JSON');
    }
    final ver = headerMap['v'];
    if (ver is! int || ver != BackupV3.containerVersion) {
      throw const BackupFormatException('unsupported container version in header');
    }
    final materialJson = headerMap['material'];
    if (materialJson is! Map) {
      throw const BackupFormatException('header missing material');
    }
    late final VaultV3Material material;
    try {
      material = VaultV3Material.fromJson(materialJson.cast<String, Object?>());
    } catch (_) {
      throw const BackupFormatException('header material malformed');
    }
    final counts = <String, int>{};
    final rc = headerMap['recordCounts'];
    if (rc is Map) {
      rc.forEach((k, v) {
        if (v is int) counts[k.toString()] = v;
      });
    }
    return BackupHeader(
      material: material,
      schemaVersion: headerMap['schemaVersion'] as int? ?? BackupV3.schemaVersion,
      recordCounts: counts,
      headerPrefix: bytes.sublist(0, bodyOffset),
      bodyOffset: bodyOffset,
    );
  }

  /// Authenticates + decrypts the outer body and returns the verbatim inner
  /// records ({box token -> {recordId -> raw stored string}}). Throws
  /// [BackupFormatException] or [SecretBoxAuthenticationError] on any tamper /
  /// wrong key — never returns partial data.
  Future<Map<String, Map<String, String>>> decodeBody({
    required Uint8List bytes,
    required BackupHeader header,
    required SecretKey backupKey,
  }) async {
    final body = bytes.sublist(header.bodyOffset);
    if (body.length < BackupV3.nonceLength + BackupV3.tagLength) {
      throw const BackupFormatException('body shorter than minimum');
    }
    final tagStart = body.length - BackupV3.tagLength;
    final clear = await _aesGcm.decrypt(
      SecretBox(
        body.sublist(BackupV3.nonceLength, tagStart),
        nonce: body.sublist(0, BackupV3.nonceLength),
        mac: Mac(body.sublist(tagStart)),
      ),
      secretKey: backupKey,
      aad: header.headerPrefix,
    );
    late final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(clear));
    } catch (_) {
      throw const BackupFormatException('inner records not valid JSON');
    }
    if (decoded is! Map) {
      throw const BackupFormatException('inner records malformed');
    }
    final out = <String, Map<String, String>>{};
    decoded.forEach((box, records) {
      if (records is! Map) {
        throw BackupFormatException('box "$box" is not an object');
      }
      final m = <String, String>{};
      records.forEach((id, raw) {
        if (raw is! String) {
          throw BackupFormatException('record "$id" is not a string');
        }
        m[id.toString()] = raw;
      });
      out[box.toString()] = m;
    });
    return out;
  }
}

/// Shared default instance.
final vaultV3Backup = VaultV3Backup();
