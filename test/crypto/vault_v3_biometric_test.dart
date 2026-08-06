// Host-side tests for the V-05 biometric orchestration (DEV-P0-03 B2-5a-native
// stage 1b-i). The native KeyStore/BiometricPrompt side (stage 1b-ii) is
// verified on-device; here the MethodChannel is mocked so we can assert the
// Dart contract: AAD symmetry, additive/opt-in semantics, fail-closed handling,
// and material round-trip. No real biometric, no device.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_biometric.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_keys.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_live.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Uint8List vaultId() =>
      Uint8List.fromList(List<int>.generate(16, (i) => i + 1));

  VaultV3Material material({int keyGen = 0, WrappedDek? bio}) => VaultV3Material(
        vaultId: vaultId(),
        wrappedDek: WrappedDek(
            bytes: Uint8List.fromList(List<int>.filled(60, 9)),
            keyGeneration: keyGen),
        descriptor: KdfDescriptor.forNewParameters(salt: Uint8List(32)),
        biometricWrappedDek: bio,
      );

  /// Installs a mock handler on a uniquely-named channel and returns both the
  /// wired orchestration and a record of the calls it receives.
  ({VaultV3Biometric bio, List<MethodCall> calls, void Function() clear})
      wire(Future<Object?>? Function(MethodCall) handler, {String? name}) {
    final channel = MethodChannel(name ?? 'test/keyauth/${handler.hashCode}');
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
    final bio = VaultV3Biometric(channel: Vault3KeyAuthChannel(channel));
    return (
      bio: bio,
      calls: calls,
      clear: () => messenger.setMockMethodCallHandler(channel, null),
    );
  }

  group('AAD symmetry (V-06)', () {
    test('enroll binds AAD = buildWrapAad(vaultId, hw-bio, keyGen)', () async {
      final w = wire((call) async {
        if (call.method == 'enroll') {
          return Uint8List.fromList(List<int>.filled(60, 3));
        }
        return null;
      });
      addTearDown(w.clear);
      final m = material(keyGen: 5);
      await w.bio.enroll(dek: Uint8List(32), material: m);

      final enrollCall = w.calls.singleWhere((c) => c.method == 'enroll');
      final args = (enrollCall.arguments as Map).cast<String, Object?>();
      final expectedAad = VaultV3KeyHierarchy.buildWrapAad(
        vaultId: m.vaultId,
        label: VaultV3Biometric.hwBioLabel,
        keyGeneration: 5,
      );
      expect(args['aad'], expectedAad);
      expect(args['keyGeneration'], 5);
      expect(args['vaultId'], m.vaultId);
    });
  });

  group('additive / opt-in', () {
    test('enroll adds hw-bio wrap without touching the password wrap', () async {
      final blob = Uint8List.fromList(List<int>.filled(60, 7));
      final w = wire((call) async => call.method == 'enroll' ? blob : null);
      addTearDown(w.clear);
      final m = material(keyGen: 2);
      final updated = await w.bio.enroll(dek: Uint8List(32), material: m);

      expect(updated.biometricWrappedDek, isNotNull);
      expect(updated.biometricWrappedDek!.bytes, blob);
      expect(updated.biometricWrappedDek!.keyGeneration, 2);
      // password wrap untouched:
      expect(updated.wrappedDek.bytes, m.wrappedDek.bytes);
      expect(updated.wrappedDek.keyGeneration, m.wrappedDek.keyGeneration);
    });

    test('disable removes hw-bio wrap, keeps password wrap', () async {
      final w = wire((call) async => call.method == 'disable' ? true : null);
      addTearDown(w.clear);
      final m = material(
          bio: WrappedDek(bytes: Uint8List(60), keyGeneration: 0));
      final updated = await w.bio.disable(m);

      expect(updated.biometricWrappedDek, isNull);
      expect(updated.wrappedDek.bytes, m.wrappedDek.bytes);
      expect(w.calls.single.method, 'disable');
    });

    test('disable still drops the wrap even if native delete throws', () async {
      final w = wire((call) async =>
          throw PlatformException(code: 'keystore-error'));
      addTearDown(w.clear);
      final m = material(
          bio: WrappedDek(bytes: Uint8List(60), keyGeneration: 0));
      final updated = await w.bio.disable(m);
      expect(updated.biometricWrappedDek, isNull);
    });
  });

  group('unlock round-trip', () {
    test('returns the same data subkey as deriving from the DEK', () async {
      final dek = Uint8List.fromList(List<int>.generate(32, (i) => i * 3 + 1));
      final w = wire((call) async => call.method == 'unlock' ? dek : null);
      addTearDown(w.clear);
      final m = material(
          keyGen: 4,
          bio: WrappedDek(bytes: Uint8List(60), keyGeneration: 4));

      final got = await w.bio.unlock(m);
      final expected = await VaultV3KeyHierarchy().deriveSubkeys(
        dek: dek,
        vaultId: m.vaultId,
        keyGeneration: 4,
      );
      expect(await got.extractBytes(),
          await expected.dataKey.extractBytes());

      // unlock binds the hw-bio AAD too:
      final unlockCall = w.calls.singleWhere((c) => c.method == 'unlock');
      final args = (unlockCall.arguments as Map).cast<String, Object?>();
      expect(
          args['aad'],
          VaultV3KeyHierarchy.buildWrapAad(
              vaultId: m.vaultId,
              label: VaultV3Biometric.hwBioLabel,
              keyGeneration: 4));
    });
  });

  group('fail-closed', () {
    test('unlock with no biometric wrap throws, no channel call', () async {
      var called = false;
      final w = wire((call) async {
        called = true;
        return null;
      });
      addTearDown(w.clear);
      expect(
        () => w.bio.unlock(material()), // no bio wrap
        throwsA(isA<VaultV3BiometricException>()),
      );
      expect(called, isFalse);
    });

    test('native PlatformException on unlock -> VaultV3BiometricException',
        () async {
      final w = wire((call) async =>
          throw PlatformException(code: 'auth-cancelled'));
      addTearDown(w.clear);
      final m = material(bio: WrappedDek(bytes: Uint8List(60), keyGeneration: 0));
      await expectLater(
          w.bio.unlock(m), throwsA(isA<VaultV3BiometricException>()));
    });

    test('native returns wrong-length DEK -> throws', () async {
      final w = wire((call) async =>
          call.method == 'unlock' ? Uint8List(16) : null);
      addTearDown(w.clear);
      final m = material(bio: WrappedDek(bytes: Uint8List(60), keyGeneration: 0));
      await expectLater(
          w.bio.unlock(m), throwsA(isA<VaultV3BiometricException>()));
    });

    test('enroll rejects a non-32-byte DEK before calling native', () async {
      var called = false;
      final w = wire((call) async {
        called = true;
        return Uint8List(60);
      });
      addTearDown(w.clear);
      await expectLater(
        w.bio.enroll(dek: Uint8List(16), material: material()),
        throwsA(isA<VaultV3BiometricException>()),
      );
      expect(called, isFalse);
    });

    test('missing plugin -> capability unavailable, enroll/unlock throw',
        () async {
      // A channel with no mock handler raises MissingPluginException.
      final bio = VaultV3Biometric(
          channel: const Vault3KeyAuthChannel(
              MethodChannel('test/keyauth/missing')));
      final cap = await bio.capability();
      expect(cap.available, isFalse);
      await expectLater(
        bio.enroll(dek: Uint8List(32), material: material()),
        throwsA(isA<VaultV3BiometricException>()),
      );
      final m = material(bio: WrappedDek(bytes: Uint8List(60), keyGeneration: 0));
      await expectLater(
          bio.unlock(m), throwsA(isA<VaultV3BiometricException>()));
    });
  });

  group('capability', () {
    test('maps native fields', () async {
      final w = wire((call) async => call.method == 'capability'
          ? <String, Object?>{
              'available': true,
              'strongBox': false,
              'insideSecureHardware': true,
              'reason': null,
            }
          : null);
      addTearDown(w.clear);
      final cap = await w.bio.capability();
      expect(cap.available, isTrue);
      expect(cap.strongBox, isFalse);
      expect(cap.insideSecureHardware, isTrue);
    });
  });

  group('material serialization', () {
    test('biometric wrap survives encode/decode', () {
      final m = material(keyGen: 3).withBiometric(
        biometricWrappedDek: WrappedDek(
            bytes: Uint8List.fromList(List<int>.generate(60, (i) => i)),
            keyGeneration: 3),
      );
      final round = VaultV3Material.decode(m.encode());
      expect(round.biometricWrappedDek, isNotNull);
      expect(round.biometricWrappedDek!.bytes, m.biometricWrappedDek!.bytes);
      expect(round.biometricWrappedDek!.keyGeneration, 3);
    });

    test('withRecovery preserves the biometric wrap', () {
      final m = material().withBiometric(
          biometricWrappedDek: WrappedDek(bytes: Uint8List(60), keyGeneration: 0));
      final withRec = m.withRecovery(
        recoveryWrappedDek: WrappedDek(bytes: Uint8List(60), keyGeneration: 0),
        recoveryCommit: Uint8List(32),
      );
      expect(withRec.biometricWrappedDek, isNotNull);
      expect(withRec.recoveryWrappedDek, isNotNull);
    });

    test('material with no biometric wrap omits the JSON key', () {
      expect(material().encode(), isNot(contains('biometric_dek')));
    });
  });
}
