// Vault v3 key hierarchy — Option 2 (design-spec.md §2, v1.1 §4).
//
//   master password --Argon2id(salt, params)--> KEK
//   DEK (32B, CSPRNG) is wrapped by the KEK; the password never encrypts records
//   data/verify/backup subkeys come from HKDF over the DEK (domain separation)
//   recovery key R (32B, full entropy) wraps the same DEK (v1.1 §4, DR-01)
//
// DEV-P0-03-B2-1. Additive only: existing v2 paths are untouched.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'vault_v3_envelope.dart';

/// How the master password is normalised before the KDF runs.
///
/// design-spec §3.2 specifies NFC. Dart has no built-in Unicode normalisation
/// and no NFC package is currently vendored, so [nfc] is declared but not yet
/// selectable; [none] records honestly what the KDF actually consumed.
/// Raised to the director as a design/implementation gap (see B2-1 submission).
enum PasswordNormalization {
  none('none'),
  nfc('NFC');

  const PasswordNormalization(this.label);
  final String label;
}

/// Self-describing Argon2id parameters (design-spec §3.2).
///
/// Persisted with the vault so the KDF can be upgraded without guessing.
class KdfDescriptor {
  const KdfDescriptor({
    required this.salt,
    required this.memoryKib,
    required this.iterations,
    required this.lanes,
    this.kdfId = VaultV3.kdfArgon2id,
    this.argonVersion = 0x13,
    this.outLength = 32,
    this.normalization = PasswordNormalization.none,
  });

  final Uint8List salt;
  final int memoryKib;
  final int iterations;
  final int lanes;
  final int kdfId;
  final int argonVersion;
  final int outLength;
  final PasswordNormalization normalization;

  /// Conservative API-24-safe starting point. Final values are decided by the
  /// on-device measurement required by the B2-1 work order, never by desktop
  /// numbers (validation-plan §3.3).
  static const int defaultMemoryKib = 19 * 1024; // 19 MiB (OWASP min profile)
  static const int defaultIterations = 2;
  static const int defaultLanes = 1;

  Map<String, Object?> toJson() => <String, Object?>{
        'kdf_id': kdfId,
        'version': argonVersion,
        'mem_kib': memoryKib,
        'iterations': iterations,
        'lanes': lanes,
        'salt': base64.encode(salt),
        'out_len': outLength,
        'normalization': normalization.label,
      };

  static KdfDescriptor fromJson(Map<String, Object?> json) => KdfDescriptor(
        salt: base64.decode(json['salt']! as String),
        memoryKib: json['mem_kib']! as int,
        iterations: json['iterations']! as int,
        lanes: json['lanes']! as int,
        kdfId: json['kdf_id']! as int,
        argonVersion: json['version']! as int,
        outLength: json['out_len']! as int,
        normalization: PasswordNormalization.values.firstWhere(
          (n) => n.label == json['normalization'],
          orElse: () => PasswordNormalization.none,
        ),
      );
}

/// Wrapped DEK blob plus the nonce needed to unwrap it.
class WrappedDek {
  const WrappedDek({required this.bytes, required this.keyGeneration});

  final Uint8List bytes; // nonce ‖ ciphertext ‖ tag
  final int keyGeneration;

  Map<String, Object?> toJson() => <String, Object?>{
        'blob': base64.encode(bytes),
        'key_generation': keyGeneration,
      };

  static WrappedDek fromJson(Map<String, Object?> json) => WrappedDek(
        bytes: base64.decode(json['blob']! as String),
        keyGeneration: json['key_generation']! as int,
      );
}

/// Raised when a DEK cannot be unwrapped (wrong password / tampered blob).
class VaultV3KeyException implements Exception {
  const VaultV3KeyException(this.reason);
  final String reason;
  @override
  String toString() => 'VaultV3KeyException: $reason';
}

/// The in-memory key set held while the vault is unlocked.
class VaultV3Keys {
  const VaultV3Keys({
    required this.dek,
    required this.dataKey,
    required this.verifyKey,
    required this.backupKey,
    required this.keyGeneration,
  });

  final SecretKey dek;
  final SecretKey dataKey;
  final SecretKey verifyKey;
  final SecretKey backupKey;
  final int keyGeneration;
}

/// Builds and unwraps the v3 key hierarchy.
class VaultV3KeyHierarchy {
  VaultV3KeyHierarchy({Random? random, AesGcm? aesGcm})
      : _random = random ?? Random.secure(),
        _aesGcm = aesGcm ?? AesGcm.with256bits();

  final Random _random;
  final AesGcm _aesGcm;

  static const String _infoData = 'sanctum/v3/data';
  static const String _infoVerify = 'sanctum/v3/verify';
  static const String _infoBackup = 'sanctum/v3/backup';

  static const List<int> _wrapLabelPassword = <int>[
    0x64, 0x65, 0x6B, 0x2D, 0x77, 0x72, 0x61, 0x70, // "dek-wrap"
  ];
  static const List<int> _wrapLabelRecovery = <int>[
    0x72, 0x65, 0x63, 0x6F, 0x76, 0x65, 0x72, 0x79, // "recovery"
  ];

  /// Generates [length] cryptographically random bytes.
  Uint8List randomBytes(int length) => Uint8List.fromList(
        List<int>.generate(length, (_) => _random.nextInt(256)),
      );

  /// Fresh 32-byte salt for the KDF descriptor.
  Uint8List generateSalt() => randomBytes(32);

  /// Fresh random Data Encryption Key. Never derived from the password.
  Uint8List generateDek() => randomBytes(32);

  /// Fresh full-entropy recovery key R (design v1.1 §4, DR-01).
  ///
  /// Shamir splits this value, never the master password, so the public
  /// commitment SHA-256(R) is not a brute-force oracle.
  Uint8List generateRecoveryKey() => randomBytes(32);

  /// Derives the password KEK with Argon2id.
  Future<SecretKey> deriveKek({
    required String password,
    required KdfDescriptor descriptor,
  }) async {
    if (descriptor.kdfId != VaultV3.kdfArgon2id) {
      throw const VaultV3KeyException('descriptor is not Argon2id');
    }
    final argon2id = Argon2id(
      parallelism: descriptor.lanes,
      memory: descriptor.memoryKib,
      iterations: descriptor.iterations,
      hashLength: descriptor.outLength,
    );
    return argon2id.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: descriptor.salt,
    );
  }

  /// AAD binding a wrap blob to its vault, purpose and generation
  /// (design-spec §2.1, v1.1 §4).
  static Uint8List buildWrapAad({
    required Uint8List vaultId,
    required List<int> label,
    required int keyGeneration,
  }) {
    if (vaultId.length != VaultV3.uuidBytes) {
      throw const VaultV3KeyException('vault_id must be 16 bytes');
    }
    return (BytesBuilder(copy: false)
          ..add(vaultId)
          ..addByte(RecordType.meta.id)
          ..add(label)
          ..addByte((keyGeneration >> 8) & 0xFF)
          ..addByte(keyGeneration & 0xFF))
        .toBytes();
  }

  Future<WrappedDek> _wrap({
    required Uint8List dek,
    required SecretKey wrappingKey,
    required Uint8List vaultId,
    required List<int> label,
    required int keyGeneration,
  }) async {
    final nonce = List<int>.generate(
      VaultV3.nonceLength,
      (_) => _random.nextInt(256),
    );
    final box = await _aesGcm.encrypt(
      dek,
      secretKey: wrappingKey,
      nonce: nonce,
      aad: buildWrapAad(
        vaultId: vaultId,
        label: label,
        keyGeneration: keyGeneration,
      ),
    );
    final blob = (BytesBuilder(copy: false)
          ..add(box.nonce)
          ..add(box.cipherText)
          ..add(box.mac.bytes))
        .toBytes();
    return WrappedDek(bytes: blob, keyGeneration: keyGeneration);
  }

  Future<Uint8List> _unwrap({
    required WrappedDek wrapped,
    required SecretKey wrappingKey,
    required Uint8List vaultId,
    required List<int> label,
  }) async {
    final blob = wrapped.bytes;
    if (blob.length < VaultV3.nonceLength + VaultV3.tagLength) {
      throw const VaultV3KeyException('wrapped DEK shorter than minimum');
    }
    final tagStart = blob.length - VaultV3.tagLength;
    try {
      final clear = await _aesGcm.decrypt(
        SecretBox(
          blob.sublist(VaultV3.nonceLength, tagStart),
          nonce: blob.sublist(0, VaultV3.nonceLength),
          mac: Mac(blob.sublist(tagStart)),
        ),
        secretKey: wrappingKey,
        aad: buildWrapAad(
          vaultId: vaultId,
          label: label,
          keyGeneration: wrapped.keyGeneration,
        ),
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const VaultV3KeyException('DEK unwrap failed: wrong key or tampered blob');
    }
  }

  /// Wraps [dek] under the password-derived KEK.
  Future<WrappedDek> wrapDekWithKek({
    required Uint8List dek,
    required SecretKey kek,
    required Uint8List vaultId,
    int keyGeneration = 0,
  }) =>
      _wrap(
        dek: dek,
        wrappingKey: kek,
        vaultId: vaultId,
        label: _wrapLabelPassword,
        keyGeneration: keyGeneration,
      );

  /// Wraps [dek] under a full-entropy recovery key (v1.1 §4).
  Future<WrappedDek> wrapDekWithRecoveryKey({
    required Uint8List dek,
    required Uint8List recoveryKey,
    required Uint8List vaultId,
    int keyGeneration = 0,
  }) =>
      _wrap(
        dek: dek,
        wrappingKey: SecretKey(recoveryKey),
        vaultId: vaultId,
        label: _wrapLabelRecovery,
        keyGeneration: keyGeneration,
      );

  Future<Uint8List> unwrapDekWithKek({
    required WrappedDek wrapped,
    required SecretKey kek,
    required Uint8List vaultId,
  }) =>
      _unwrap(
        wrapped: wrapped,
        wrappingKey: kek,
        vaultId: vaultId,
        label: _wrapLabelPassword,
      );

  Future<Uint8List> unwrapDekWithRecoveryKey({
    required WrappedDek wrapped,
    required Uint8List recoveryKey,
    required Uint8List vaultId,
  }) =>
      _unwrap(
        wrapped: wrapped,
        wrappingKey: SecretKey(recoveryKey),
        vaultId: vaultId,
        label: _wrapLabelRecovery,
      );

  /// Public commitment to a recovery key (design v1.1 §3/§4).
  ///
  /// Safe to publish because R carries 256 bits of entropy: unlike a hash of
  /// the master password, this is not a brute-force oracle.
  Future<Uint8List> recoveryCommitment(Uint8List recoveryKey) async {
    final digest = await Sha256().hash(recoveryKey);
    return Uint8List.fromList(digest.bytes);
  }

  /// Derives the domain-separated subkeys from the DEK (design-spec §2.2).
  Future<VaultV3Keys> deriveSubkeys({
    required Uint8List dek,
    required Uint8List vaultId,
    required int keyGeneration,
  }) async {
    Future<SecretKey> expand(String info) async {
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      return hkdf.deriveKey(
        secretKey: SecretKey(dek),
        nonce: vaultId,
        info: utf8.encode(info),
      );
    }

    return VaultV3Keys(
      dek: SecretKey(dek),
      dataKey: await expand(_infoData),
      verifyKey: await expand(_infoVerify),
      backupKey: await expand(_infoBackup),
      keyGeneration: keyGeneration,
    );
  }

  /// Unlocks a vault: password → KEK → DEK → subkeys.
  Future<VaultV3Keys> unlockWithPassword({
    required String password,
    required KdfDescriptor descriptor,
    required WrappedDek wrappedDek,
    required Uint8List vaultId,
  }) async {
    final kek = await deriveKek(password: password, descriptor: descriptor);
    final dek = await unwrapDekWithKek(
      wrapped: wrappedDek,
      kek: kek,
      vaultId: vaultId,
    );
    return deriveSubkeys(
      dek: dek,
      vaultId: vaultId,
      keyGeneration: wrappedDek.keyGeneration,
    );
  }
}
