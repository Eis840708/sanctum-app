// On-device RETURN harness for V-05 biometric auth-bound (DEV-P0-03 B2-5a-native
// stage 1b-iii). Drives the REAL VaultService against the REAL native
// KeyStore/BiometricPrompt channel on a physical device.
//
// Run (profile) on a device:
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/vault_v3_biometric_return_test.dart \
//     --profile -d <deviceId>
//
// Two tiers:
//  * NON-INTERACTIVE (always): v2 unlock zero-regression, v3 DEK round-trip,
//    real capability() shape, and the no-hardware fallback (a device without a
//    usable hardware biometric must make enroll fail-closed). These need no
//    fingerprint and run headless.
//  * INTERACTIVE (only with --dart-define=SANCTUM_BIO_INTERACTIVE=true): the
//    enroll -> unlock round-trip, which pops a real BiometricPrompt the operator
//    (Eis) must satisfy with a fingerprint. Skipped by default so an automated
//    run never hangs. Enrollment-invalidation (add a NEW fingerprint in device
//    settings, expect the wrap to fail-closed) is a manual step documented in
//    the stage 1b evidence file — it cannot be driven from a test.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:sanctum/core/crypto/v3/vault_v3_biometric.dart';
import 'package:sanctum/core/storage/vault_service.dart';

const bool _kInteractive =
    bool.fromEnvironment('SANCTUM_BIO_INTERACTIVE', defaultValue: false);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await vaultService.init();
  });

  test('v3 DEK round-trip through the real VaultService (no biometric)',
      () async {
    await vaultService.createVault('return-pw-1');
    await vaultService.addPassword(
        site: 'return.invalid', username: 'u', password: 'return-secret');
    vaultService.lock();
    expect(vaultService.isUnlocked, isFalse);
    expect(await vaultService.unlock('return-pw-1'), isTrue);
    final pws = await vaultService.getPasswords();
    expect(await vaultService.decryptPassword(pws.single), 'return-secret');
  });

  test('capability() is well-formed on this device', () async {
    final cap = await VaultV3Biometric().capability();
    debugPrint('[bio-return] capability: available=${cap.available} '
        'strongBox=${cap.strongBox} secureHw=${cap.insideSecureHardware} '
        'reason=${cap.reason}');
    // Contract: a software-only key is never reported available.
    if (cap.available) {
      expect(cap.insideSecureHardware, isTrue);
    }
  });

  test('no usable hardware biometric -> enroll is fail-closed', () async {
    final cap = await VaultV3Biometric().capability();
    if (cap.available) {
      debugPrint('[bio-return] capability available; fallback branch skipped.');
      return;
    }
    await vaultService.createVault('return-pw-2');
    await expectLater(
      vaultService.enableV3Biometric('return-pw-2'),
      throwsA(isA<VaultV3BiometricException>()),
    );
    expect(await vaultService.hasV3Biometric, isFalse);
  });

  test('INTERACTIVE: enroll -> lock -> biometric unlock round-trip',
      () async {
    if (!_kInteractive) {
      markTestSkipped('interactive; run with '
          '--dart-define=SANCTUM_BIO_INTERACTIVE=true and tap the fingerprint');
      return;
    }
    await vaultService.createVault('return-pw-3');
    await vaultService.addPassword(
        site: 'bio.invalid', username: 'u', password: 'bio-secret');
    await vaultService.enableV3Biometric('return-pw-3'); // prompt #1
    expect(await vaultService.hasV3Biometric, isTrue);
    vaultService.lock();
    await vaultService.unlockV3WithBiometric(); // prompt #2
    expect(vaultService.isUnlocked, isTrue);
    final pws = await vaultService.getPasswords();
    expect(await vaultService.decryptPassword(pws.single), 'bio-secret');
    await vaultService.disableV3Biometric();
    expect(await vaultService.hasV3Biometric, isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
