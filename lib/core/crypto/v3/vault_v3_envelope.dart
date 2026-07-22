// Vault v3 versioned authenticated envelope.
//
// Implements design-spec.md §3 (v1.0) with v1.1 revision §6 (DR-03).
// DEV-P0-03-B2-1. Additive only: existing v2 read/write paths are untouched.
//
// Layout (big-endian), per design-spec §3.1:
//   0   4   magic "SNC3"
//   4   1   format_version = 0x03
//   5   1   alg_id         = 0x01 (AES-256-GCM)
//   6   1   kdf_id         = 0x02 (Argon2id) | 0x01 (PBKDF2, legacy read-only)
//   7   1   key_scope      = 0x01 data | 0x02 verify | 0x03 backup
//   8   2   key_generation (uint16)
//   10  12  nonce
//   22  N   ciphertext
//   +N  16  tag
//
// AAD is NOT stored with the ciphertext; it is rebuilt by the caller from the
// record context at encrypt and decrypt time (design v1.1 §6, DR-03).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Header field values.
class VaultV3 {
  VaultV3._();

  static const List<int> magic = <int>[0x53, 0x4E, 0x43, 0x33]; // "SNC3"
  static const int formatVersion = 0x03;

  static const int algAesGcm256 = 0x01;

  static const int kdfPbkdf2Legacy = 0x01; // read-only, migration source
  static const int kdfArgon2id = 0x02;

  static const int headerLength = 22; // magic..nonce inclusive
  static const int aadHeaderLength = 10; // magic..key_generation
  static const int nonceLength = 12;
  static const int tagLength = 16;
  static const int uuidBytes = 16;
}

/// Which HKDF-derived subkey a ciphertext belongs to (design-spec §2.2).
enum KeyScope {
  data(0x01),
  verify(0x02),
  backup(0x03);

  const KeyScope(this.id);
  final int id;
}

/// Record family bound into the AAD (design-spec §3.3).
enum RecordType {
  password(0x01),
  diary(0x02),
  finance(0x03),
  image(0x04),
  verify(0x05),
  meta(0x06);

  const RecordType(this.id);
  final int id;
}

/// Per-record-type field identifiers (design-spec §3.4).
class FieldId {
  FieldId._();

  // password
  static const int pwSite = 0x01;
  static const int pwUsername = 0x02;
  static const int pwPassword = 0x03;
  static const int pwNotes = 0x04;

  // diary
  static const int diaryTitle = 0x01;
  static const int diaryContent = 0x02;
  static const int diaryMood = 0x03;
  static const int diaryTags = 0x04;

  // finance
  static const int finType = 0x01;
  static const int finCategory = 0x02;
  static const int finDescription = 0x03;
  static const int finAmount = 0x04;
  static const int finCurrency = 0x05;
  static const int finDate = 0x06;
  static const int finLineItems = 0x07;

  // image
  static const int imageBytes = 0x01;
  static const int imageIndexList = 0x02;

  // verify
  static const int verifyToken = 0x00;
}

/// Fixed record id used for singleton records (verify token, meta).
final Uint8List kSingletonRecordId = Uint8List(VaultV3.uuidBytes);

/// Raised whenever a v3 payload cannot be authenticated or parsed.
///
/// v3 decryption is fail-closed by construction: it never returns its input.
class VaultV3FormatException implements Exception {
  const VaultV3FormatException(this.reason);
  final String reason;
  @override
  String toString() => 'VaultV3FormatException: $reason';
}

/// Immutable description of the slot a ciphertext occupies.
///
/// Rebuilt by the caller at decrypt time; never persisted (DR-03).
class RecordContext {
  const RecordContext({
    required this.vaultId,
    required this.recordType,
    required this.recordId,
    required this.fieldId,
    required this.schemaVersion,
  });

  final Uint8List vaultId; // 16 bytes
  final RecordType recordType;
  final Uint8List recordId; // 16 bytes
  final int fieldId;
  final int schemaVersion;
}

/// Builds and parses v3 envelopes.
class VaultV3Envelope {
  VaultV3Envelope({Random? random, AesGcm? aesGcm})
      : _random = random ?? Random.secure(),
        _aesGcm = aesGcm ?? AesGcm.with256bits();

  final Random _random;
  final AesGcm _aesGcm;

  /// Parses a 16-byte UUID from its canonical hyphenated string form.
  static Uint8List uuidToBytes(String uuid) {
    final hex = uuid.replaceAll('-', '');
    if (hex.length != 32) {
      throw const VaultV3FormatException('uuid must be 32 hex characters');
    }
    final out = Uint8List(VaultV3.uuidBytes);
    for (var i = 0; i < VaultV3.uuidBytes; i++) {
      final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) {
        throw const VaultV3FormatException('uuid contains non-hex characters');
      }
      out[i] = byte;
    }
    return out;
  }

  /// Serialises the 10 authenticated header bytes (offsets 0..9).
  static Uint8List buildHeaderPrefix({
    required int kdfId,
    required KeyScope scope,
    required int keyGeneration,
  }) {
    if (keyGeneration < 0 || keyGeneration > 0xFFFF) {
      throw const VaultV3FormatException('key_generation out of uint16 range');
    }
    final head = Uint8List(VaultV3.aadHeaderLength);
    head.setAll(0, VaultV3.magic);
    head[4] = VaultV3.formatVersion;
    head[5] = VaultV3.algAesGcm256;
    head[6] = kdfId;
    head[7] = scope.id;
    head[8] = (keyGeneration >> 8) & 0xFF;
    head[9] = keyGeneration & 0xFF;
    return head;
  }

  /// Canonical AAD: header prefix ‖ vault_id ‖ record_type ‖ record_id ‖
  /// field_id ‖ schema_version (design-spec §3.3).
  static Uint8List buildAad({
    required Uint8List headerPrefix,
    required RecordContext context,
  }) {
    if (context.vaultId.length != VaultV3.uuidBytes) {
      throw const VaultV3FormatException('vault_id must be 16 bytes');
    }
    if (context.recordId.length != VaultV3.uuidBytes) {
      throw const VaultV3FormatException('record_id must be 16 bytes');
    }
    if (context.fieldId < 0 || context.fieldId > 0xFF) {
      throw const VaultV3FormatException('field_id out of uint8 range');
    }
    if (context.schemaVersion < 0 || context.schemaVersion > 0xFFFF) {
      throw const VaultV3FormatException('schema_version out of uint16 range');
    }
    final builder = BytesBuilder(copy: false)
      ..add(headerPrefix)
      ..add(context.vaultId)
      ..addByte(context.recordType.id)
      ..add(context.recordId)
      ..addByte(context.fieldId)
      ..addByte((context.schemaVersion >> 8) & 0xFF)
      ..addByte(context.schemaVersion & 0xFF);
    return builder.toBytes();
  }

  /// Encrypts [plaintext] into a v3 envelope bound to [context].
  Future<Uint8List> encrypt({
    required List<int> plaintext,
    required SecretKey key,
    required RecordContext context,
    KeyScope scope = KeyScope.data,
    int kdfId = VaultV3.kdfArgon2id,
    int keyGeneration = 0,
  }) async {
    final headerPrefix = buildHeaderPrefix(
      kdfId: kdfId,
      scope: scope,
      keyGeneration: keyGeneration,
    );
    final aad = buildAad(headerPrefix: headerPrefix, context: context);
    final nonce = List<int>.generate(
      VaultV3.nonceLength,
      (_) => _random.nextInt(256),
    );
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: aad,
    );
    return (BytesBuilder(copy: false)
          ..add(headerPrefix)
          ..add(box.nonce)
          ..add(box.cipherText)
          ..add(box.mac.bytes))
        .toBytes();
  }

  /// Encrypts a UTF-8 string and returns the Base64 form used by Hive fields.
  Future<String> encryptStringToBase64({
    required String plaintext,
    required SecretKey key,
    required RecordContext context,
    KeyScope scope = KeyScope.data,
    int keyGeneration = 0,
  }) async {
    final bytes = await encrypt(
      plaintext: utf8.encode(plaintext),
      key: key,
      context: context,
      scope: scope,
      keyGeneration: keyGeneration,
    );
    return base64.encode(bytes);
  }

  /// Returns true when [bytes] carries the v3 magic and format version.
  ///
  /// Version is decided by this explicit marker, never by trial decryption
  /// (design-spec §3.1; guards the V-04 class of defect).
  static bool isV3(List<int> bytes) {
    if (bytes.length < VaultV3.headerLength + VaultV3.tagLength) return false;
    for (var i = 0; i < VaultV3.magic.length; i++) {
      if (bytes[i] != VaultV3.magic[i]) return false;
    }
    return bytes[4] == VaultV3.formatVersion;
  }

  /// Parsed, still-unauthenticated header of a v3 envelope.
  static ({int kdfId, int scopeId, int keyGeneration}) parseHeader(
    List<int> bytes,
  ) {
    if (!isV3(bytes)) {
      throw const VaultV3FormatException('not a v3 envelope');
    }
    if (bytes[5] != VaultV3.algAesGcm256) {
      throw const VaultV3FormatException('unsupported alg_id');
    }
    final kdfId = bytes[6];
    if (kdfId != VaultV3.kdfArgon2id && kdfId != VaultV3.kdfPbkdf2Legacy) {
      throw const VaultV3FormatException('unsupported kdf_id');
    }
    return (
      kdfId: kdfId,
      scopeId: bytes[7],
      keyGeneration: (bytes[8] << 8) | bytes[9],
    );
  }

  /// Authenticates and decrypts a v3 envelope.
  ///
  /// Throws [VaultV3FormatException] or [SecretBoxAuthenticationError] on any
  /// failure. It never returns the input.
  Future<Uint8List> decrypt({
    required List<int> envelope,
    required SecretKey key,
    required RecordContext context,
  }) async {
    final header = parseHeader(envelope);
    if (envelope.length < VaultV3.headerLength + VaultV3.tagLength) {
      throw const VaultV3FormatException('envelope shorter than minimum');
    }
    final scope = KeyScope.values.firstWhere(
      (s) => s.id == header.scopeId,
      orElse: () => throw const VaultV3FormatException('unknown key_scope'),
    );
    final headerPrefix = buildHeaderPrefix(
      kdfId: header.kdfId,
      scope: scope,
      keyGeneration: header.keyGeneration,
    );
    final aad = buildAad(headerPrefix: headerPrefix, context: context);
    final nonce = envelope.sublist(
      VaultV3.aadHeaderLength,
      VaultV3.headerLength,
    );
    final tagStart = envelope.length - VaultV3.tagLength;
    final cipherText = envelope.sublist(VaultV3.headerLength, tagStart);
    final mac = Mac(envelope.sublist(tagStart));
    final clear = await _aesGcm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: key,
      aad: aad,
    );
    return Uint8List.fromList(clear);
  }

  /// Decrypts a Base64 v3 envelope back to its UTF-8 string.
  Future<String> decryptBase64ToString({
    required String encoded,
    required SecretKey key,
    required RecordContext context,
  }) async {
    late final Uint8List raw;
    try {
      raw = base64.decode(encoded);
    } on FormatException {
      throw const VaultV3FormatException('payload is not valid base64');
    }
    return utf8.decode(await decrypt(
      envelope: raw,
      key: key,
      context: context,
    ));
  }
}
