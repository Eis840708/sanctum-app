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
import 'vendor/unorm/unorm.dart' as unorm;

/// How the master password is normalised before the KDF runs.
///
/// design-spec §3.2 specifies NFC. Implemented in B2-2 via the vendored `unorm`
/// normalizer (DEV-P0-03-B2-2-NFC-and-guard-rulings-v1 §三). The chosen form is
/// recorded in the [KdfDescriptor] so a vault always re-applies the same
/// normalisation it was created with (self-describing; supports later change
/// without guessing). [none] remains for vaults created before NFC shipped.
enum PasswordNormalization {
  none('none'),
  nfc('NFC');

  const PasswordNormalization(this.label);
  final String label;

  /// Applies this normalisation to [password] before it is fed to the KDF.
  String apply(String password) {
    switch (this) {
      case PasswordNormalization.none:
        return password;
      case PasswordNormalization.nfc:
        return unorm.nfc(password);
    }
  }
}

/// Raised when new Argon2id parameters would fall below the security floor.
///
/// Only new-parameter paths raise this. Reading an existing vault never does
/// (see [KdfDescriptor.forNewParameters] vs [KdfDescriptor.fromJson]).
class KdfFloorViolation implements Exception {
  const KdfFloorViolation(this.reason);
  final String reason;
  @override
  String toString() => 'KdfFloorViolation: $reason';
}

/// Raised when read-back Argon2id parameters exceed the safety ceiling
/// (red-team RT-C-04). A malicious backup/header could otherwise specify an
/// absurd memory/iteration cost that OOMs or hangs the device while deriving the
/// KEK — before any password is verified (pre-auth DoS). This is an UPPER bound
/// only: the floor and the "an existing vault below the floor is still readable"
/// behaviour are unchanged.
class KdfCeilingViolation implements Exception {
  const KdfCeilingViolation(this.reason);
  final String reason;
  @override
  String toString() => 'KdfCeilingViolation: $reason';
}

/// Self-describing Argon2id parameters (design-spec §3.2).
///
/// Persisted with the vault so the KDF can be upgraded without guessing.
///
/// Security floor (director ruling DEV-P0-03-B2-2 §二): the OWASP minimum
/// 19 MiB / t=2 / p=1 must never be produced for NEW parameters. If a device
/// is too slow the accepted responses are, in order: (i) accept a longer
/// unlock time; (ii) raise [lanes]; (iii) NEVER lower [memoryKib]. Existing
/// vaults are read back unconditionally, even below the floor, so that a vault
/// recorded with weaker parameters can still be unlocked (a floor on the read
/// path would brick it — permanent data loss).
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

  /// Builds a descriptor for a NEW parameter set (new vault, KEK upgrade,
  /// password change, backup re-encryption) and ENFORCES the security floor.
  ///
  /// Throws [KdfFloorViolation] — never silently clamps — when parameters fall
  /// below 19 MiB / t=2 / p=1.
  factory KdfDescriptor.forNewParameters({
    required Uint8List salt,
    int memoryKib = defaultMemoryKib,
    int iterations = defaultIterations,
    int lanes = defaultLanes,
    PasswordNormalization normalization = PasswordNormalization.none,
  }) {
    if (memoryKib < floorMemoryKib) {
      throw KdfFloorViolation(
        'memoryKib $memoryKib below floor $floorMemoryKib; raising lanes or '
        'accepting a longer unlock time is allowed, lowering memory is not',
      );
    }
    if (iterations < floorIterations) {
      throw KdfFloorViolation(
          'iterations $iterations below floor $floorIterations');
    }
    if (lanes < floorLanes) {
      throw KdfFloorViolation('lanes $lanes below floor $floorLanes');
    }
    return KdfDescriptor(
      salt: salt,
      memoryKib: memoryKib,
      iterations: iterations,
      lanes: lanes,
      normalization: normalization,
    );
  }

  /// OWASP minimum floor (director ruling DEV-P0-03-B2-1 §1.2.4). Hard.
  static const int floorMemoryKib = 19 * 1024; // 19 MiB
  static const int floorIterations = 2;
  static const int floorLanes = 1;

  /// True when these parameters sit below the security floor. Used to flag an
  /// existing vault for a recommended KEK upgrade — never to block unlocking.
  bool get belowSecurityFloor =>
      memoryKib < floorMemoryKib ||
      iterations < floorIterations ||
      lanes < floorLanes;

  /// Safety ceiling for read-back parameters (red-team RT-C-04, director ruling).
  /// Rejects an absurd Argon2id cost BEFORE it is run, so a hostile backup/header
  /// cannot OOM/hang the device pre-auth. Upper bound only — never touches the
  /// floor or the below-floor read compatibility.
  static const int ceilingMemoryKib = 512 * 1024; // 512 MiB
  static const int ceilingIterations = 16;
  static const int ceilingLanes = 8;
  static const int requiredOutLength = 32;
  static const int requiredArgonVersion = 0x13;

  /// Throws [KdfCeilingViolation] if these parameters exceed the safety ceiling
  /// or use a non-canonical shape (kdf/version/out_len). Must run before any
  /// Argon2 derivation. Does NOT enforce the floor — a legitimate weak/old vault
  /// (below the floor but within the ceiling) still passes and stays readable.
  void checkReadBounds() {
    if (kdfId != VaultV3.kdfArgon2id) {
      throw KdfCeilingViolation('kdf_id $kdfId is not Argon2id');
    }
    if (argonVersion != requiredArgonVersion) {
      throw KdfCeilingViolation(
          'argon version $argonVersion != $requiredArgonVersion');
    }
    if (outLength != requiredOutLength) {
      throw KdfCeilingViolation('out_len $outLength != $requiredOutLength');
    }
    if (memoryKib > ceilingMemoryKib) {
      throw KdfCeilingViolation(
          'mem_kib $memoryKib above ceiling $ceilingMemoryKib');
    }
    if (iterations > ceilingIterations) {
      throw KdfCeilingViolation(
          'iterations $iterations above ceiling $ceilingIterations');
    }
    if (lanes > ceilingLanes) {
      throw KdfCeilingViolation('lanes $lanes above ceiling $ceilingLanes');
    }
  }

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

  static KdfDescriptor fromJson(Map<String, Object?> json) {
    final descriptor = KdfDescriptor(
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
    // RT-C-04: reject an absurd/hostile cost at the earliest read point, before
    // it can ever reach Argon2 (pre-auth DoS). Ceiling only — below-floor read
    // compatibility is unaffected.
    descriptor.checkReadBounds();
    return descriptor;
  }
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
    // RT-C-04 defensive guard: never run Argon2 with an above-ceiling cost, even
    // if a descriptor reached here by a path other than fromJson. Fail-closed.
    descriptor.checkReadBounds();
    final argon2id = Argon2id(
      parallelism: descriptor.lanes,
      memory: descriptor.memoryKib,
      iterations: descriptor.iterations,
      hashLength: descriptor.outLength,
    );
    // Normalise per the descriptor so the same password always yields the same
    // KEK regardless of the input method's byte sequence (design-spec §3.2).
    final normalized = descriptor.normalization.apply(password);
    return argon2id.deriveKey(
      secretKey: SecretKey(utf8.encode(normalized)),
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
