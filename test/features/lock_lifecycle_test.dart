// BUG-ALPHA-LOCK-LIFECYCLE-02 regression — _submit()'s setState must not run
// after the LockScreen is disposed. On a successful createVault/unlock the auth
// state flips to unlocked, _Root swaps LockScreen out (disposed), and the await
// in _submit returns into a dead State; the trailing setState threw
// "Null check operator used on a null value" (State.setState).
//
// The host below reproduces that exact lifecycle: it shows LockScreen while
// locked and a HOME placeholder once unlocked (so unlock disposes LockScreen).
// Plain dark theme (SanctumTheme pulls google_fonts, blocked under flutter test).
// Synthetic data only.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';

import 'package:sanctum/core/i18n/strings.dart';
import 'package:sanctum/core/models/models.dart';
import 'package:sanctum/core/storage/providers.dart';
import 'package:sanctum/core/storage/vault_service.dart';
import 'package:sanctum/features/auth/screens/lock_screen.dart';
import 'package:sanctum/shared/theme/app_theme.dart';

final Map<String, String> _secure = {};

class _Host extends ConsumerWidget {
  const _Host();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    // Mirrors _Root: LockScreen is torn down the moment the vault unlocks.
    return auth == AuthState.unlocked
        ? const Scaffold(body: Center(child: Text('HOME')))
        : const LockScreen();
  }
}

Widget _app(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
            extensions: const <ThemeExtension<dynamic>>[SanctumColors.dark]),
        home: const _Host(),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final tmp = await Directory.systemTemp.createTemp('lock_life_');
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
    await vaultService.init();
  });

  setUp(() async {
    _secure.clear();
    vaultService.lock();
    if (Hive.isBoxOpen('sanctum_meta')) {
      await Hive.box<VaultMeta>('sanctum_meta').clear();
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

  // Runs a real Argon2/Hive operation the tap kicks off (createVault/unlock),
  // which cannot complete under the widget test's fake-async clock otherwise.
  Future<void> tapAndAwait(WidgetTester tester, Finder button) async {
    await tester.ensureVisible(button); // setup form scrolls; bring button on-screen
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(button);
      await tester.pump();
      await Future<void>.delayed(const Duration(seconds: 4));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('createVault success switches to HOME with zero exceptions',
      (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(c)); // no vault → onboarding, then setup mode
    await settle(tester);

    // Fresh vault shows onboarding first (_showOnboarding = _isSetup). Skip it
    // to reach the setup form.
    await tester.tap(find.text(S.get('onbSkip')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byType(EditableText).first, 'master-123456');
    await tester.pump();
    await tapAndAwait(tester, find.text(S.get('createVaultBtn')));

    expect(tester.takeException(), isNull); // no disposed-State setState crash
    expect(find.text('HOME'), findsOneWidget);
    expect(vaultService.isUnlocked, isTrue);
  });

  testWidgets('correct-password unlock switches to HOME with zero exceptions',
      (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.runAsync(
        () => c.read(authProvider.notifier).createVault('master-123456'));
    c.read(authProvider.notifier).lock();

    await tester.pumpWidget(_app(c)); // vault exists, locked → unlock mode
    await settle(tester);

    await tester.enterText(find.byType(EditableText).first, 'master-123456');
    await tester.pump();
    await tapAndAwait(tester, find.text(S.unlockBtn));

    expect(tester.takeException(), isNull);
    expect(find.text('HOME'), findsOneWidget);
    expect(vaultService.isUnlocked, isTrue);
  });

  testWidgets('wrong password stays on lock screen and shows an error',
      (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.runAsync(
        () => c.read(authProvider.notifier).createVault('master-123456'));
    c.read(authProvider.notifier).lock();

    await tester.pumpWidget(_app(c));
    await settle(tester);

    await tester.enterText(find.byType(EditableText).first, 'wrong-password');
    await tester.pump();
    await tapAndAwait(tester, find.text(S.unlockBtn));

    expect(tester.takeException(), isNull);
    expect(find.text('HOME'), findsNothing);
    expect(vaultService.isUnlocked, isFalse);
    expect(find.text(S.wrongPassword), findsOneWidget);
  });
}
