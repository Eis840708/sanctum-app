// V-05 biometric auth-bound DEK wrap — Dart orchestration (DEV-P0-03 B2-5a-native
// stage 1b). Director-approved contract: DEV-P0-03-B2-5a-native-dependency-
// assessment-v1.
//
// This is the THIRD wrap path for the v3 DEK, parallel to the password-KEK wrap
// and the recovery-key wrap. The DEK is wrapped a third time by a hardware
// Android KeyStore key whose use is gated by BiometricPrompt (CryptoObject). The
// native side (KeyAuthChannel.kt, stage 1b-ii) owns the KeyStore key and the
// biometric prompt; this Dart layer owns the blob format binding (same AAD as
// the other wraps, V-06) and the fail-closed orchestration.
//
// Hard invariants (director ruling):
//   * ADDITIVE / opt-in: the password wrap is NEVER removed. Enrolling or
//     disabling biometric only touches [VaultV3Material.biometricWrappedDek].
//   * v3-only.
//   * NO raw key artifact: the stored unlock artifact is an AEAD blob that only
//     the hardware key + a biometric auth can open — not raw session-key bytes.
//   * fail-closed: any native error, a missing wrap, or an unavailable capability
//     raises, never silently falls back or leaks key material.
//   * the master password remains the recovery root; biometric is convenience.
//
// The crypto core three files (crypto_service / shamir_service / models) and
// vault_v3_keys.dart are untouched: this reuses WrappedDek, buildWrapAad and
// deriveSubkeys as-is.
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';

import 'vault_v3_keys.dart';
import 'vault_v3_live.dart';

/// Hardware-biometric capability of the current device, as reported by native.
class BiometricCapability {
  const BiometricCapability({
    required this.available,
    required this.strongBox,
    required this.insideSecureHardware,
    this.reason,
  });

  /// True only when a hardware-backed, auth-required KeyStore key can be created
  /// AND a biometric is enrolled. When false, the vault stays password-only.
  final bool available;

  /// True when the key is StrongBox-backed (API 28+ with a secure element).
  /// API 24 devices are TEE-backed but not StrongBox.
  final bool strongBox;

  /// True when the KeyStore key resides in secure hardware (TEE/StrongBox). A
  /// software-backed key is treated as NOT available — never a false hardware
  /// promise.
  final bool insideSecureHardware;

  /// Non-secret human/diagnostic reason when [available] is false.
  final String? reason;

  static BiometricCapability fromMap(Map<Object?, Object?> map) =>
      BiometricCapability(
        available: map['available'] == true,
        strongBox: map['strongBox'] == true,
        insideSecureHardware: map['insideSecureHardware'] == true,
        reason: map['reason'] as String?,
      );

  static const BiometricCapability unavailable = BiometricCapability(
    available: false,
    strongBox: false,
    insideSecureHardware: false,
    reason: 'channel-unavailable',
  );
}

/// Raised when a biometric operation fails. Fail-closed: the caller must fall
/// back to the master password, never to a weaker path.
class VaultV3BiometricException implements Exception {
  const VaultV3BiometricException(this.reason);
  final String reason;
  @override
  String toString() => 'VaultV3BiometricException: $reason';
}

/// Thin MethodChannel client for the native key-auth channel. Injectable so the
/// orchestration is host-testable with a mocked channel.
class Vault3KeyAuthChannel {
  const Vault3KeyAuthChannel([this.channel = _default]);

  static const MethodChannel _default =
      MethodChannel('com.sanctum.vault/keyauth');

  final MethodChannel channel;

  Future<Map<Object?, Object?>> capability() async {
    final res = await channel.invokeMethod<Map<Object?, Object?>>('capability');
    return res ?? const <Object?, Object?>{};
  }

  /// Wraps [dek] under the hardware key (requires a biometric auth on the native
  /// side). Returns the wrap blob (iv‖ct‖tag).
  Future<Uint8List> enroll({
    required Uint8List dek,
    required Uint8List vaultId,
    required int keyGeneration,
    required Uint8List aad,
  }) async {
    final blob = await channel.invokeMethod<Uint8List>('enroll', <String, Object?>{
      'dek': dek,
      'vaultId': vaultId,
      'keyGeneration': keyGeneration,
      'aad': aad,
    });
    if (blob == null) {
      throw const VaultV3BiometricException('enroll returned no blob');
    }
    return blob;
  }

  /// Unwraps the DEK from [blob] after a biometric auth (native CryptoObject).
  Future<Uint8List> unlock({
    required Uint8List blob,
    required Uint8List vaultId,
    required Uint8List aad,
  }) async {
    final dek = await channel.invokeMethod<Uint8List>('unlock', <String, Object?>{
      'blob': blob,
      'vaultId': vaultId,
      'aad': aad,
    });
    if (dek == null) {
      throw const VaultV3BiometricException('unlock returned no key');
    }
    return dek;
  }

  Future<bool> disable(Uint8List vaultId) async {
    final ok = await channel
        .invokeMethod<bool>('disable', <String, Object?>{'vaultId': vaultId});
    return ok ?? false;
  }
}

/// Orchestrates the biometric hw-bio wrap over the v3 DEK.
class VaultV3Biometric {
  VaultV3Biometric({
    Vault3KeyAuthChannel? channel,
    VaultV3KeyHierarchy? hierarchy,
  })  : _channel = channel ?? const Vault3KeyAuthChannel(),
        _kh = hierarchy ?? VaultV3KeyHierarchy();

  final Vault3KeyAuthChannel _channel;
  final VaultV3KeyHierarchy _kh;

  /// AAD label for the biometric wrap: bytes of "hw-bio". Distinct from the
  /// password ("dek-wrap") and recovery ("recovery") labels so a blob from one
  /// path can never be unwrapped as another (V-06 binding).
  static const List<int> hwBioLabel = <int>[
    0x68, 0x77, 0x2D, 0x62, 0x69, 0x6F, // "hw-bio"
  ];

  Uint8List _aad(Uint8List vaultId, int keyGeneration) =>
      VaultV3KeyHierarchy.buildWrapAad(
        vaultId: vaultId,
        label: hwBioLabel,
        keyGeneration: keyGeneration,
      );

  /// Queries whether a hardware-backed, biometric-gated wrap can be offered.
  Future<BiometricCapability> capability() async {
    try {
      return BiometricCapability.fromMap(await _channel.capability());
    } on PlatformException catch (e) {
      return BiometricCapability(
        available: false,
        strongBox: false,
        insideSecureHardware: false,
        reason: e.code,
      );
    } on MissingPluginException {
      return BiometricCapability.unavailable;
    }
  }

  /// Enrolls biometric unlock for [material], given the [dek] the caller already
  /// recovered via the master password. Returns updated material carrying the
  /// hw-bio wrap. The password wrap is untouched (additive/opt-in).
  ///
  /// [dek] must be 32 bytes.
  Future<VaultV3Material> enroll({
    required Uint8List dek,
    required VaultV3Material material,
  }) async {
    if (dek.length != 32) {
      throw const VaultV3BiometricException('DEK must be 32 bytes');
    }
    final keyGeneration = material.wrappedDek.keyGeneration;
    try {
      final blob = await _channel.enroll(
        dek: dek,
        vaultId: material.vaultId,
        keyGeneration: keyGeneration,
        aad: _aad(material.vaultId, keyGeneration),
      );
      return material.withBiometric(
        biometricWrappedDek:
            WrappedDek(bytes: blob, keyGeneration: keyGeneration),
      );
    } on PlatformException catch (e) {
      throw VaultV3BiometricException('enroll failed: ${e.code}');
    } on MissingPluginException {
      throw const VaultV3BiometricException('enroll failed: channel unavailable');
    }
  }

  /// Unlocks [material] with biometric, returning the data (session) subkey.
  /// Fail-closed: throws if no biometric wrap exists or native auth fails —
  /// the caller must then use the master password.
  Future<SecretKey> unlock(VaultV3Material material) async =>
      (await unlockKeys(material)).dataKey;

  /// Unlocks [material] with biometric, returning the full derived key set.
  Future<VaultV3Keys> unlockKeys(VaultV3Material material) async {
    final wrap = material.biometricWrappedDek;
    if (wrap == null) {
      throw const VaultV3BiometricException('vault has no biometric wrap');
    }
    final Uint8List dek;
    try {
      dek = await _channel.unlock(
        blob: wrap.bytes,
        vaultId: material.vaultId,
        aad: _aad(material.vaultId, wrap.keyGeneration),
      );
    } on PlatformException catch (e) {
      throw VaultV3BiometricException('unlock failed: ${e.code}');
    } on MissingPluginException {
      throw const VaultV3BiometricException('unlock failed: channel unavailable');
    }
    if (dek.length != 32) {
      throw const VaultV3BiometricException('unwrapped DEK has wrong length');
    }
    return _kh.deriveSubkeys(
      dek: dek,
      vaultId: material.vaultId,
      keyGeneration: wrap.keyGeneration,
    );
  }

  /// Disables biometric unlock: drops the native KeyStore key and the stored
  /// hw-bio wrap. Password + recovery wraps are untouched. Returns updated
  /// material. Best-effort on the native delete; the wrap is always removed
  /// from the material so a stale blob can never be used.
  Future<VaultV3Material> disable(VaultV3Material material) async {
    try {
      await _channel.disable(material.vaultId);
    } on PlatformException {
      // Ignore: the durable wrap is being removed regardless, so a leftover
      // KeyStore key is inert.
    } on MissingPluginException {
      // Same — nothing durable to protect once the wrap is gone.
    }
    return material.withoutBiometric();
  }
}
