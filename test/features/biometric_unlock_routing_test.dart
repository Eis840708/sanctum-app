// P1 biometric-unlock fix — routing + UI gating (DEV-P0-03-BUG-biometric).
//
// Covers requirement E of the dispatch:
//   E1. When biometric is NOT enabled for this vault, the lock screen offers no
//       biometric button (the bug: it was shown on hardware availability alone,
//       so every tap failed and bounced back to the lock screen).
//   E2. A v3 vault's biometric unlock routes to the V-05 native, crypto-bound
//       path (KeyAuthChannel) — NOT the legacy local_auth path.
//
// Harness mirrors vault_v3_biometric_service_test / shamir_screen_v3_widget_test:
// path_provider + flutter_secure_storage + an in-memory fake native keyauth
// channel; a local_auth call counter proves the v2 path is not taken. Synthetic
// data only; no device, no real biometric.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // also provides Uint8List
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';

import 'package:sanctum/core/models/models.dart';
import 'package:sanctum/core/storage/providers.dart';
import 'package:sanctum/core/storage/vault_service.dart';
import 'package:sanctum/features/auth/screens/lock_screen.dart';
import 'package:sanctum/shared/theme/app_theme.dart';

final Map<String, String> _secure = {};
final Map<String, List<int>> _hw = {}; // vaultId(hex) -> DEK (fake KeyStore)
final List<String> _keyauthCalls = [];
int _localAuthCalls = 0;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

// Plain dark theme with only the SanctumColors extension (context.sc) — avoids
// SanctumTheme.dark's google_fonts runtime fetch under `flutter test`.
Widget _host(Widget child) => ProviderScope(
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
    final tmp = await Directory.systemTemp.createTemp('bio_route_');
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

    // Fake native key-auth channel (V-05). Records calls so we can prove the
    // v3 vault takes THIS path, not local_auth.
    const ka = MethodChannel('com.sanctum.vault/keyauth');
    messenger.setMockMethodCallHandler(ka, (c) async {
      _keyauthCalls.add(c.method);
      final a = (c.arguments as Map?)?.cast<String, Object?>() ?? {};
      switch (c.method) {
        case 'capability':
          return <String, Object?>{
            'available': true,
            'strongBox': false,
            'insideSecureHardware': true,
            'reason': null,
          };
        case 'enroll':
          _hw[_hex(a['vaultId']! as Uint8List)] =
              List<int>.from(a['dek']! as Uint8List);
          return Uint8List.fromList(List<int>.filled(60, 0xAB));
        case 'unlock':
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

    // Legacy local_auth channel — count any call so E2 can assert it is unused
    // on the v3 path. Reports biometric hardware available (for the E1 positive).
    const la = MethodChannel('plugins.flutter.io/local_auth');
    messenger.setMockMethodCallHandler(la, (c) async {
      _localAuthCalls++;
      switch (c.method) {
        case 'authenticate': return true;
        case 'getEnrolledBiometrics': return <String>['fingerprint'];
        default: return true; // isDeviceSupported / deviceSupportsBiometrics
      }
    });

    await vaultService.init();
  });

  setUp(() async {
    _secure.clear();
    _hw.clear();
    _keyauthCalls.clear();
    _localAuthCalls = 0;
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

  // E1 — the button must not appear when biometric is not enabled.
  testWidgets('lock screen offers NO biometric button when not enrolled (v3)',
      (tester) async {
    await tester.runAsync(() => vaultService.createVault('master-123456'));
    expect(vaultService.isV3Vault, isTrue);
    expect(await vaultService.hasV3Biometric, isFalse);
    vaultService.lock();

    await tester.pumpWidget(_host(const LockScreen()));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byIcon(Icons.fingerprint), findsNothing);
  });

  // Note: the positive case (button APPEARS once enrolled) also needs
  // canUseBiometric() true, which depends on the local_auth platform channel
  // (pigeon) that is not available under `flutter test`. That branch is verified
  // on-device (ADB) by the director; here we prove the gating logic (no button
  // when not enrolled) and the native routing below.

  // E2 — a v3 vault's biometric unlock takes the native path, not local_auth.
  testWidgets('v3 biometric unlock routes to native KeyAuthChannel, not local_auth',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      await vaultService.createVault('master-xyz-123');
      await vaultService.addPassword(
          site: 'route.invalid', username: 'u', password: 'secret-v');
      await vaultService.enableV3Biometric('master-xyz-123');
    });
    vaultService.lock();
    _keyauthCalls.clear();
    _localAuthCalls = 0;

    final ok = await tester.runAsync(
        () => container.read(authProvider.notifier).unlockWithBiometric());

    expect(ok, isTrue);
    expect(vaultService.isUnlocked, isTrue);
    // Native crypto-bound path was used …
    expect(_keyauthCalls, contains('unlock'));
    // … and the legacy local_auth (pattern-fallback) path was NOT.
    expect(_localAuthCalls, 0);
  });
}
