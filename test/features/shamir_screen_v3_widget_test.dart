// W-1 widget test (shamir C-a / C-c / branch).
//
// Two rules make widget tests work on this project:
//   1. Real-async work (Argon2id KDF + Hive I/O in vaultService) MUST run inside
//      tester.runAsync() — testWidgets' default FakeAsync zone never advances real
//      timers, so an un-wrapped createVault() hangs the isolate at 0 CPU (this was
//      the "deadlock" mis-diagnosed in the first W-2 note).
//   2. Use pump(Duration), NOT pumpAndSettle — these screens hold perpetual
//      animations (text-field cursor / Material) that never settle.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';

import 'package:sanctum/core/models/models.dart';
import 'package:sanctum/core/storage/vault_service.dart';
import 'package:sanctum/features/settings/screens/shamir_screen.dart';
import 'package:sanctum/shared/theme/app_theme.dart';

final Map<String, String> _secure = {};

// Use a plain dark theme carrying only the SanctumColors extension (context.sc).
// The real SanctumTheme.dark builds its textTheme via google_fonts, which tries a
// runtime HTTP font fetch under `flutter test` (blocked) — irrelevant to these
// text/branch assertions, so we skip it.
Widget _host() => ProviderScope(
      child: MaterialApp(
        theme: ThemeData.dark()
            .copyWith(extensions: const <ThemeExtension<dynamic>>[SanctumColors.dark]),
        home: const ShamirScreen(),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // The app theme uses google_fonts; block runtime HTTP font fetching so the
    // widget test doesn't try (and fail) to reach fonts.gstatic.com.
    GoogleFonts.config.allowRuntimeFetching = false;
    final tmp = await Directory.systemTemp.createTemp('shamir_wt_');
    const pp = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pp, (c) async => tmp.path);
    const ss = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ss, (c) async {
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

  setUp(() async => _wipe());

  testWidgets('C-a: v3 Generate tab states recovery will NOT reveal the password',
      (tester) async {
    await tester.runAsync(() => vaultService.createVault('v3-master-123456'));
    expect(vaultService.isV3Vault, isTrue);
    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('不會顯示你的主密碼'), findsOneWidget);
    expect(find.textContaining('碎片備份將主密碼分成'), findsNothing);
  });

  testWidgets('C-c: v3 Recover tab asks for NEW password, no master-password reveal',
      (tester) async {
    await tester.runAsync(() => vaultService.createVault('v3-master-123456'));
    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('還原密碼'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('確認新主密碼'), findsOneWidget);
    expect(find.text('還原並設定新主密碼'), findsOneWidget);
    expect(find.textContaining('已成功還原主密碼'), findsNothing);
  });

  testWidgets('C-b: v3 Generate results — per-share only, no aggregate action',
      (tester) async {
    await tester.runAsync(() => vaultService.createVault('v3-master-123456'));
    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).first, 'v3-master-123456');
    // Target the button (the tab bar also has a '生成碎片' label).
    final genBtn = find.widgetWithText(ElevatedButton, '生成碎片');
    await tester.ensureVisible(genBtn);
    await tester.runAsync(() async {
      await tester.tap(genBtn);
      await Future<void>.delayed(const Duration(milliseconds: 1200)); // Argon2id + split
    });
    await tester.pump(const Duration(milliseconds: 400));
    // Reached the results page…
    expect(find.textContaining('已生成'), findsOneWidget);
    // …with NO aggregate distribution control (V-07: one share, one destination).
    for (final agg in const ['全部分享', '全部複製', '匯出全部', '分享全部', '複製全部']) {
      expect(find.text(agg), findsNothing);
    }
  });

  testWidgets('C-f: v3 recover success re-locks the vault (lock() called)',
      (tester) async {
    late final List<String> codes;
    await tester.runAsync(() async {
      await vaultService.createVault('old-pw-123456');
      final shares = await vaultService.enableV3Recovery('old-pw-123456', n: 3, k: 2);
      codes = shares.map(base64Encode).toList();
    });
    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('還原密碼'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // Fields order: 3 share inputs, then new-password + confirm.
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), codes[0]);
    await tester.enterText(fields.at(1), codes[1]);
    await tester.enterText(fields.at(2), codes[2]);
    await tester.enterText(fields.at(3), 'brand-new-pw-123456');
    await tester.enterText(fields.at(4), 'brand-new-pw-123456');
    await tester.pump(const Duration(milliseconds: 100));

    final recBtn = find.widgetWithText(ElevatedButton, '還原並設定新主密碼');
    await tester.ensureVisible(recBtn);
    await tester.runAsync(() async {
      await tester.tap(recBtn);
      await Future<void>.delayed(const Duration(milliseconds: 1200)); // recoverV3 rekey
    });
    await tester.pump(const Duration(milliseconds: 400));

    // Success dialog → 確定 triggers authProvider.lock().
    expect(find.text('還原完成'), findsOneWidget);
    expect(vaultService.isUnlocked, isTrue); // recovered session, before re-lock
    await tester.tap(find.text('確定'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(vaultService.isUnlocked, isFalse); // C-f: forced re-lock happened
  });

  testWidgets('v2 vault: legacy Shamir UI unchanged (splits the master password)',
      (tester) async {
    await tester.runAsync(() async {
      await Hive.box<VaultMeta>('sanctum_meta').put(
        'meta',
        VaultMeta(
          salt: 'x', verifyHash: 'y',
          createdAt: DateTime(2026, 1, 1), lastUnlocked: DateTime(2026, 1, 1),
          version: 'v2',
        ),
      );
    });
    expect(vaultService.isV3Vault, isFalse);
    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('碎片備份將主密碼分成'), findsOneWidget);
    expect(find.textContaining('不會顯示你的主密碼'), findsNothing);
  });
}

Future<void> _wipe() async {
  vaultService.lock();
  await Hive.box<PasswordEntry>('sanctum_passwords').clear();
  await Hive.box<DiaryEntry>('sanctum_diary').clear();
  await Hive.box<FinanceRecord>('sanctum_finance').clear();
  await Hive.box<String>('sanctum_images').clear();
  await Hive.box('sanctum_image_index').clear();
  await Hive.box<VaultMeta>('sanctum_meta').clear();
  await (await Hive.openBox('sanctum_vault_v3')).clear();
  for (final n in const [
    'sanctum_passwords__v3', 'sanctum_diary__v3', 'sanctum_finance__v3',
    'sanctum_images__v3', 'sanctum_image_index__v3',
  ]) {
    await (await Hive.openBox(n)).clear();
    await (await Hive.openBox('${n}__staging')).clear();
  }
  await (await Hive.openBox('sanctum_migration_journal')).clear();
  await (await Hive.openBox('sanctum_backup_restore_journal')).clear();
  _secure.clear();
}
