// V-05 end-to-end UI-layer gate (DEV-P0-03-BUG-biometric, dispatch item 2 & 3).
//
// These tests DRIVE THE LOCK SCREEN ITSELF (not just the service) — the exact
// "UI -> service wiring" layer whose absence let the P1 bug ship. They assert:
//   • v3 vault, biometric enrolled  -> the button IS shown, tapping it takes the
//     native KeyAuthChannel path, and the auth state becomes unlocked. (item 2)
//   • biometric NOT enrolled        -> the button is NOT shown. (item 2)
//   • native biometric fails (key-invalidated / enrollment-invalidation)
//                                    -> fail-closed: stays locked and the UI
//     shows the "use your password" guidance, no silent bounce. (item 3)
//   • no biometric hardware          -> the button is NOT shown (fail-closed). (item 3)
//
// canUseBiometric() is made true by overriding LocalAuthPlatform.instance with a
// fake — the local_auth platform channel (pigeon) is unavailable under
// `flutter test`, so without this the button could never render in a test. The
// native crypto path uses the com.sanctum.vault/keyauth channel, faked here as an
// in-memory KeyStore. Synthetic data only; no device, no real biometric.
//
// The on-device RETURN (real BiometricPrompt + real fingerprint) is a separate,
// mandatory acceptance step run by the director (ADB) + Eis — see the dispatch.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // also provides Uint8List
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:sanctum/core/i18n/strings.dart';
import 'package:sanctum/core/models/models.dart';
import 'package:sanctum/core/storage/providers.dart';
import 'package:sanctum/core/storage/vault_service.dart';
import 'package:sanctum/features/auth/screens/lock_screen.dart';
import 'package:sanctum/shared/theme/app_theme.dart';

// ── Fake local_auth platform (so canUseBiometric() is true in tests) ──────────
class _FakeLocalAuth extends LocalAuthPlatform with MockPlatformInterfaceMixin {
  _FakeLocalAuth({this.available = true});
  bool available;
  int authCalls = 0;

  @override
  Future<bool> isDeviceSupported() async => available;
  @override
  Future<bool> deviceSupportsBiometrics() async => available;
  @override
  Future<List<BiometricType>> getEnrolledBiometrics() async =>
      available ? <BiometricType>[BiometricType.fingerprint] : <BiometricType>[];
  @override
  Future<bool> authenticate({
    required String localizedReason,
    required Iterable<AuthMessages> authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    authCalls++;
    return true;
  }

  @override
  Future<bool> stopAuthentication() async => true;
}

final Map<String, String> _secure = {};
final Map<String, List<int>> _hw = {}; // vaultId(hex) -> DEK (fake KeyStore)
final List<String> _keyauthCalls = [];
bool _simulateInvalidated = false;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Widget _app(Widget child, ProviderContainer container) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData.dark()
            .copyWith(extensions: const <ThemeExtension<dynamic>>[SanctumColors.dark]),
        home: child,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final tmp = await Directory.systemTemp.createTemp('bio_ui_');
    const pp = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(pp, (c) async => tmp.path);

    const ss = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    messenger.setMockMethodCallHandler(ss, (c) async {
      final a = (c.arguments as Map?)?.cast<String, dynamic>() ?? {};
      final k = a['key'] as String?;
      switch (c.method) {
        case 'write': _secure[k!] = a['value'] as String; return null;
        case 'read': return _secure[k];
        case 'delete': _secure.remove(k); return null;
        case 'deleteAll': _secure.clear(); return null;
        case 'readAll': return Map<String, String>.from(_secure);
        case 'containsKey': return _secure.containsKey(k);
        default: return null;
      }
    });

    const ka = MethodChannel('com.sanctum.vault/keyauth');
    messenger.setMockMethodCallHandler(ka, (c) async {
      _keyauthCalls.add(c.method);
      final a = (c.arguments as Map?)?.cast<String, Object?>() ?? {};
      switch (c.method) {
        case 'capability':
          return <String, Object?>{
            'available': true, 'strongBox': false,
            'insideSecureHardware': true, 'reason': null,
          };
        case 'enroll':
          _hw[_hex(a['vaultId']! as Uint8List)] =
              List<int>.from(a['dek']! as Uint8List);
          return Uint8List.fromList(List<int>.filled(60, 0xAB));
        case 'unlock':
          if (_simulateInvalidated) {
            throw PlatformException(code: 'key-invalidated');
          }
          final dek = _hw[_hex(a['vaultId']! as Uint8List)];
          if (dek == null) throw PlatformException(code: 'no-key');
          return Uint8List.fromList(dek);
        case 'disable':
          _hw.remove(_hex(a['vaultId']! as Uint8List));
          return true;
        default:
          return null;
      }
    });

    await vaultService.init();
  });

  setUp(() async {
    _secure.clear();
    _hw.clear();
    _keyauthCalls.clear();
    _simulateInvalidated = false;
    LocalAuthPlatform.instance = _FakeLocalAuth();
    vaultService.lock();
    if (Hive.isBoxOpen('sanctum_meta')) {
      await Hive.box<VaultMeta>('sanctum_meta').clear();
    }
    if (Hive.isBoxOpen('sanctum_passwords')) {
      await Hive.box<PasswordEntry>('sanctum_passwords').clear();
    }
    if (Hive.isBoxOpen('sanctum_diary')) {
      await Hive.box<DiaryEntry>('sanctum_diary').clear();
    }
    if (Hive.isBoxOpen('sanctum_finance')) {
      await Hive.box<FinanceRecord>('sanctum_finance').clear();
    }
    if (Hive.isBoxOpen('sanctum_images')) {
      await Hive.box<String>('sanctum_images').clear();
    }
    if (Hive.isBoxOpen('sanctum_image_index')) {
      await Hive.box('sanctum_image_index').clear();
    }
    await (await Hive.openBox('sanctum_vault_v3')).clear();
    for (final n in const ['sanctum_passwords__v3', 'sanctum_diary__v3',
        'sanctum_finance__v3', 'sanctum_images__v3', 'sanctum_image_index__v3']) {
      await (await Hive.openBox(n)).clear();
    }
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 300));
  }

  // item 2 — the whole UI→service→native chain, driven from the button.
  testWidgets('v3 enrolled: button shows, tap → native path → unlocked',
      (tester) async {
    await tester.runAsync(() async {
      await vaultService.createVault('master-123456');
      await vaultService.enableV3Biometric('master-123456');
    });
    expect(await vaultService.hasV3Biometric, isTrue);
    vaultService.lock();

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(const LockScreen(), container));
    await settle(tester);

    // Button is offered.
    expect(find.byIcon(Icons.fingerprint), findsOneWidget);

    _keyauthCalls.clear();
    final fake = LocalAuthPlatform.instance as _FakeLocalAuth;

    // Tap it and let the real async unlock run.
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.fingerprint));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(vaultService.isUnlocked, isTrue, reason: 'unlocked via biometric');
    expect(container.read(authProvider), AuthState.unlocked);
    expect(_keyauthCalls, contains('unlock')); // native path taken
    expect(fake.authCalls, 0); // NOT the legacy local_auth path
  });

  // item 2 — no button before enable.
  testWidgets('v3 not enrolled: biometric button is NOT shown', (tester) async {
    await tester.runAsync(() => vaultService.createVault('master-123456'));
    expect(await vaultService.hasV3Biometric, isFalse);
    vaultService.lock();

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(const LockScreen(), container));
    await settle(tester);

    expect(find.byIcon(Icons.fingerprint), findsNothing);
  });

  // item 3 — enrollment-invalidation: fail-closed + guidance, no bounce.
  testWidgets('v3 native fail (key-invalidated): stays locked, guides to password',
      (tester) async {
    await tester.runAsync(() async {
      await vaultService.createVault('master-123456');
      await vaultService.enableV3Biometric('master-123456');
    });
    vaultService.lock();
    _simulateInvalidated = true; // new fingerprint enrolled → hw key dead

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(const LockScreen(), container));
    await settle(tester);
    expect(find.byIcon(Icons.fingerprint), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.fingerprint));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    // Fail-closed …
    expect(vaultService.isUnlocked, isFalse);
    expect(container.read(authProvider), AuthState.locked);
    // … and the UI guides the user to the master password (default lang zh).
    expect(find.text(S.get('bioError')), findsOneWidget);
  });

  // item 3 — no biometric hardware: button not shown (fail-closed).
  testWidgets('no hardware: biometric button is NOT shown even if enrolled',
      (tester) async {
    await tester.runAsync(() async {
      await vaultService.createVault('master-123456');
      await vaultService.enableV3Biometric('master-123456');
    });
    vaultService.lock();
    LocalAuthPlatform.instance = _FakeLocalAuth(available: false);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(const LockScreen(), container));
    await settle(tester);

    expect(find.byIcon(Icons.fingerprint), findsNothing);
  });
}
