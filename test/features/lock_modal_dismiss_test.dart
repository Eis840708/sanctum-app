// BUG-ALPHA-LOCK-MODAL-01 regression — a sensitive bottom sheet left open when
// the vault auto-locks must be torn down, must not write to a locked vault, and
// must not throw "Cannot use ref after the widget was disposed".
//
// Drives the REAL PasswordsScreen and the REAL dismissModalsOnLock() that _Root
// calls on lock (main.dart). The host below mirrors _Root's lock wiring exactly;
// a plain dark theme is used because SanctumTheme pulls google_fonts (blocked
// under `flutter test`). Synthetic data only.
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
import 'package:sanctum/features/passwords/screens/passwords_screen.dart';
import 'package:sanctum/main.dart' show dismissModalsOnLock;
import 'package:sanctum/shared/theme/app_theme.dart';
import 'package:sanctum/shared/widgets/widgets.dart';

final Map<String, String> _secure = {};

/// Mirrors _Root: shows PasswordsScreen while unlocked, and on lock (optionally)
/// runs the SAME dismissModalsOnLock() the app runs.
class _Host extends ConsumerWidget {
  const _Host({required this.dismissOnLock});
  final bool dismissOnLock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    ref.listen<AuthState>(authProvider, (_, next) {
      if (next != AuthState.unlocked && dismissOnLock) {
        dismissModalsOnLock(context);
      }
    });
    return auth == AuthState.unlocked
        ? const Scaffold(body: PasswordsScreen())
        : const Scaffold(body: Center(child: Text('LOCKED-PLACEHOLDER')));
  }
}

Widget _app(Widget child, ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
            extensions: const <ThemeExtension<dynamic>>[SanctumColors.dark]),
        home: child,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final tmp = await Directory.systemTemp.createTemp('lock_modal_');
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
    if (Hive.isBoxOpen('sanctum_passwords')) {
      await Hive.box<PasswordEntry>('sanctum_passwords').clear();
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
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<ProviderContainer> unlockedContainer(WidgetTester tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.runAsync(
        () => c.read(authProvider.notifier).createVault('master-123456'));
    return c;
  }

  Future<void> openAddSheet(WidgetTester tester) async {
    await tester.tap(find.byType(GoldAddButton).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(S.save), findsOneWidget, reason: 'add sheet is open');
  }

  Future<void> fillSheet(WidgetTester tester) async {
    Finder fieldOf(String label) => find.descendant(
        of: find.widgetWithText(SanctumField, label),
        matching: find.byType(EditableText));
    await tester.enterText(fieldOf(S.site), 'example.com');
    await tester.enterText(fieldOf(S.username), 'me@example.com');
    await tester.tap(find.byIcon(Icons.refresh)); // generate password
    await tester.pump();
  }

  testWidgets('auto-lock dismisses the open add sheet; no write, no crash',
      (tester) async {
    final c = await unlockedContainer(tester);
    await tester.pumpWidget(_app(const _Host(dismissOnLock: true), c));
    await settle(tester);

    await openAddSheet(tester);

    // Auto-lock (InactivityNotifier calls the same authProvider.lock()).
    c.read(authProvider.notifier).lock();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Sheet is gone, lock UI is shown — no residual sensitive sheet.
    expect(find.text(S.save), findsNothing);
    expect(find.text('LOCKED-PLACEHOLDER'), findsOneWidget);

    // Nothing was written to the vault.
    await tester.runAsync(
        () => c.read(authProvider.notifier).unlock('master-123456'));
    final pws = await tester.runAsync(() => vaultService.getPasswords());
    expect(pws!, isEmpty);
  });

  testWidgets('a sheet orphaned by lock cannot add / does not throw disposed-ref',
      (tester) async {
    // dismissOnLock:false leaves the sheet on screen after the screen disposes —
    // the exact reported condition. The mounted guard must make Save a safe no-op.
    final c = await unlockedContainer(tester);
    await tester.pumpWidget(_app(const _Host(dismissOnLock: false), c));
    await settle(tester);

    await openAddSheet(tester);
    await fillSheet(tester);

    // Lock: PasswordsScreen (which owns `ref`) is disposed, but the sheet stays.
    c.read(authProvider.notifier).lock();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(S.save), findsOneWidget, reason: 'sheet deliberately orphaned');

    // Tapping Save must NOT throw "ref after dispose" and must NOT write.
    await tester.runAsync(() async {
      await tester.tap(find.text(S.save));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(vaultService.isUnlocked, isFalse);
    await tester.runAsync(
        () => c.read(authProvider.notifier).unlock('master-123456'));
    final pws = await tester.runAsync(() => vaultService.getPasswords());
    expect(pws!, isEmpty, reason: 'no add executed after lock');
  });

  testWidgets('normal add still works (unlocked)', (tester) async {
    final c = await unlockedContainer(tester);
    await tester.pumpWidget(_app(const _Host(dismissOnLock: true), c));
    await settle(tester);

    await openAddSheet(tester);
    await fillSheet(tester);

    await tester.runAsync(() async {
      await tester.tap(find.text(S.save));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // finish sheet dismiss anim

    final pws = await tester.runAsync(() => vaultService.getPasswords());
    expect(pws!.length, 1);
    expect(pws.single.site, 'example.com');
    expect(find.text(S.save), findsNothing, reason: 'sheet closed after save');
  });
}
