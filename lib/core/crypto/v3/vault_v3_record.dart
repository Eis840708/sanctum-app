// v3 full-record per-field encryption codec (DEV-P0-03 B2-5b, option C).
// Design freeze: design-spec §3.1/§3.3/§3.4/§5, v1.1 §6 (DR-03),
// storage supplement v1.3-delta.
//
// A record's fields are each sealed in their OWN v3 authenticated envelope
// (per-field V-06 AAD: vaultId ‖ recordType ‖ recordId ‖ fieldId ‖
// schemaVersion) and serialised as JSON {"sv":<schema>,"f":{"<fieldId>":
// "<base64 envelope>"}} for storage in an independent v3 box. Encryption
// granularity is unchanged from the typed-box design — only the storage location
// moves. models.dart / typed adapters are untouched.
//
// This codec deals in fieldId -> plaintext STRING maps; the caller
// (VaultService) converts typed fields (double / DateTime / List) to/from their
// canonical string form (supplement §6).

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'vault_v3_envelope.dart';

/// Full field_id enumeration: design-spec §3.4 base plus the v1.3-delta
/// extensions for the timestamp / iconEmoji fields that §5 requires encrypted
/// but §3.4 did not enumerate. Values are unique within each record type.
class V3FieldId {
  V3FieldId._();

  // password (RecordType.password)
  static const int pwSite = 0x01;
  static const int pwUsername = 0x02;
  static const int pwPassword = 0x03;
  static const int pwNotes = 0x04;
  static const int pwIconEmoji = 0x05; // v1.3-delta
  static const int pwCreatedAt = 0x06; // v1.3-delta
  static const int pwUpdatedAt = 0x07; // v1.3-delta

  // diary (RecordType.diary)
  static const int diaryTitle = 0x01;
  static const int diaryContent = 0x02;
  static const int diaryMood = 0x03;
  static const int diaryTags = 0x04;
  static const int diaryCreatedAt = 0x05; // v1.3-delta
  static const int diaryUpdatedAt = 0x06; // v1.3-delta

  // finance (RecordType.finance)
  static const int finType = 0x01;
  static const int finCategory = 0x02;
  static const int finDescription = 0x03;
  static const int finAmount = 0x04;
  static const int finCurrency = 0x05;
  static const int finDate = 0x06;
  static const int finLineItems = 0x07;
  static const int finCreatedAt = 0x08; // v1.3-delta

  // image (RecordType.image)
  static const int imageBytes = 0x01;
  static const int imageIndexList = 0x02;
}

/// Serialised-record keys.
const String _kSchemaVersion = 'sv';
const String _kFields = 'f';

/// Current v3 record schema version (supplement §2).
const int kV3SchemaVersion = 1;

/// Encodes/decodes a record's per-field v3 envelopes to/from its stored JSON.
class VaultV3RecordCodec {
  VaultV3RecordCodec({VaultV3Envelope? envelope})
      : _envelope = envelope ?? VaultV3Envelope();

  final VaultV3Envelope _envelope;

  /// Derives the 16-byte record id used in the AAD from an arbitrary id string
  /// (supplement §5): SHA-256(utf8(id))[0..16). Deterministic; works for ids
  /// that are not canonical UUIDs (legacy / imported / singleton).
  static Future<Uint8List> recordIdBytes(String id) async {
    final digest = await Sha256().hash(utf8.encode(id));
    return Uint8List.fromList(digest.bytes.sublist(0, VaultV3.uuidBytes));
  }

  /// Seals [fields] (fieldId -> plaintext) into per-field v3 envelopes and
  /// returns the JSON string stored in the v3 box.
  Future<String> encode({
    required RecordType recordType,
    required String id,
    required Map<int, String> fields,
    required SecretKey dataKey,
    required Uint8List vaultId,
    int schemaVersion = kV3SchemaVersion,
    int keyGeneration = 0,
  }) async {
    final rid = await recordIdBytes(id);
    final out = <String, String>{};
    for (final entry in fields.entries) {
      out[entry.key.toString()] = await _envelope.encryptStringToBase64(
        plaintext: entry.value,
        key: dataKey,
        context: RecordContext(
          vaultId: vaultId,
          recordType: recordType,
          recordId: rid,
          fieldId: entry.key,
          schemaVersion: schemaVersion,
        ),
        keyGeneration: keyGeneration,
      );
    }
    return jsonEncode(<String, Object?>{
      _kSchemaVersion: schemaVersion,
      _kFields: out,
    });
  }

  /// Authenticates and decrypts a stored record back to a fieldId -> plaintext
  /// map. Fail-closed: any tampering / cross-slot reuse raises
  /// [VaultV3FormatException] or [SecretBoxAuthenticationError].
  Future<Map<int, String>> decode({
    required RecordType recordType,
    required String id,
    required String stored,
    required SecretKey dataKey,
    required Uint8List vaultId,
  }) async {
    final map = (jsonDecode(stored) as Map).cast<String, Object?>();
    final schemaVersion = map[_kSchemaVersion] as int? ?? kV3SchemaVersion;
    final fields = (map[_kFields] as Map).cast<String, Object?>();
    final rid = await recordIdBytes(id);
    final out = <int, String>{};
    for (final entry in fields.entries) {
      final fieldId = int.parse(entry.key);
      final clear = await _envelope.decrypt(
        envelope: base64.decode(entry.value! as String),
        key: dataKey,
        context: RecordContext(
          vaultId: vaultId,
          recordType: recordType,
          recordId: rid,
          fieldId: fieldId,
          schemaVersion: schemaVersion,
        ),
      );
      out[fieldId] = utf8.decode(clear);
    }
    return out;
  }
}

final vaultV3RecordCodec = VaultV3RecordCodec();
