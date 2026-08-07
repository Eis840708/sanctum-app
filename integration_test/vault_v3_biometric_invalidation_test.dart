// On-device enrollment-invalidation RETURN for V-05 (DEV-P0-03 B2-5a-native).
// Proves that enrolling a NEW device biometric invalidates the hw-bio KeyStore
// key (setInvalidatedByBiometricEnrollment(true)) so biometric unlock
// fails-closed while the master password still recovers the vault.
//
// Guided single run (no reinstall, state persists within the run):
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/vault_v3_biometric_invalidation_test.dart \
//     --profile -d <deviceId> \
//     --dart-define=SANCTUM_BIO_INVALIDATION=true \
//     --dart-define=SANCTUM_BIO_WAIT_SECONDS=120
//
// Operator (Eis) steps:
//   1. When the biometric prompt appears (enroll), authenticate once.
//   2. The test prints "ADD A NEW FINGERPRINT NOW" and waits N seconds.
//      Go to Settings > Security & privacy > Fingerprints, add a new
//      fingerprint, then return to the app. Do NOT tap anything else.
//   3. The test resumes and asserts biometric unlock is fail-closed (the
//      invalidated key throws before any prompt) and the password still works.
//
// Skipped unless SANCTUM_BIO_INVALIDATION=true so automated runs never block.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:sanctum/core/crypto/v3/vault_v3_biometric.dart';
import 'package:sanctum/core/storage/vault_service.dart';

const bool _kRun =
    bool.fromEnvironment('SANCTUM_BIO_INVALIDATION', defaultValue: false);
const int _kWaitSeconds =
    int.fromEnvironment('SANCTUM_BIO_WAIT_SECONDS', defaultValue: 120);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await vaultService.init();
  });

  test('enrollment-invalidation: biometric fails closed, password recovers',
      () async {
    if (!_kRun) {
      markTestSkipped('guided; run with --dart-define=SANCTUM_BIO_INVALIDATION='
          'true and add a new fingerprint when prompted');
      return;
    }
    await vaultService.clearVault();
    await vaultService.createVault('inval-pw');
    await vaultService.addPassword(
        site: 'inval.invalid', username: 'u', password: 'inval-secret');
    await vaultService.enableV3Biometric('inval-pw'); // prompt: authenticate once
    expect(await vaultService.hasV3Biometric, isTrue);

    debugPrint('==================================================');
    debugPrint('[bio-inval] ENROLLED. NOW add a NEW fingerprint:');
    debugPrint('[bio-inval]   Settings > Security & privacy > Fingerprints');
    debugPrint('[bio-inval] then return. Waiting ${_kWaitSeconds}s. Do NOT tap.');
    debugPrint('==================================================');
    await Future<void>.delayed(const Duration(seconds: _kWaitSeconds));

    // The new enrollment invalidated the key. Biometric unlock must fail closed
    // (KeyPermanentlyInvalidatedException at cipher.init -> no prompt shown).
    vaultService.lock();
    Object? err;
    try {
      await vaultService.unlockV3WithBiometric();
    } catch (e) {
      err = e;
    }
    debugPrint('[bio-inval] biometric unlock after new enrollment: '
        '${err.runtimeType}: $err');
    expect(err, isA<VaultV3BiometricException>(),
        reason: 'invalidated biometric must fail closed');
    expect(vaultService.isUnlocked, isFalse);

    // Fail-closed recovery: the master password still unlocks and data is intact.
    expect(await vaultService.unlock('inval-pw'), isTrue);
    final pws = await vaultService.getPasswords();
    expect(await vaultService.decryptPassword(pws.single), 'inval-secret');
    debugPrint('[bio-inval] PASS: fail-closed + password recovery + data intact');

    await vaultService.clearVault();
  }, timeout: const Timeout(Duration(seconds: _kWaitSeconds + 180)));
}
