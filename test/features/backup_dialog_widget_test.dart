// W-1 dialog-fix widget test (backup_screen master-password prompt).
//
// Proves the authorized dispose fix: the v3-restore master-password dialog now
// owns its TextEditingController in a StatefulWidget State and disposes it with
// the State (after the route is removed), so dismissing the dialog no longer
// triggers a use-after-dispose during the dismiss animation.
//
// Scope note: this drives ONLY up to the password dialog and cancels — it does
// NOT complete importV3Backup (that real-async runs in a post-dialog FakeAsync
// continuation that neither runAsync nor pump can advance; B3-a/B4 are covered by
// layered review per the director ruling). Harness rules: plain theme (no
// google_fonts HTTP), pump(Duration) not pumpAndSettle.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
// ignore: depend_on_referenced_packages  — MockPlatformInterfaceMixin for the mock
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:sanctum/core/models/models.dart';
import 'package:sanctum/core/storage/vault_service.dart';
import 'package:sanctum/features/settings/screens/backup_screen.dart';
import 'package:sanctum/shared/theme/app_theme.dart';

final Map<String, String> _secure = {};

/// Mock file picker returning a minimal SNCB3-magic blob (enough for the flow to
/// detect a v3 backup and open the password dialog; never parsed since we cancel).
class _MockFilePicker extends FilePicker with MockPlatformInterfaceMixin {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    // "SNCB3" (0x53 0x4E 0x43 0x42 0x33) + container_version 0x03 + header_len.
    final bytes = Uint8List.fromList(
        [0x53, 0x4E, 0x43, 0x42, 0x33, 0x03, 0x00, 0x10]);
    return FilePickerResult(
        [PlatformFile(name: 'backup.vault', size: bytes.length, bytes: bytes)]);
  }
}

Widget _host() => ProviderScope(
      child: MaterialApp(
        theme: ThemeData.dark()
            .copyWith(extensions: const <ThemeExtension<dynamic>>[SanctumColors.dark]),
        home: const BackupScreen(),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final tmp = await Directory.systemTemp.createTemp('backup_dlg_');
    const pp = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pp, (c) async => tmp.path);
    const ss = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ss, (c) async => null);
    FilePicker.platform = _MockFilePicker();
    await vaultService.init();
  });

  setUp(() async {
    await Hive.box<VaultMeta>('sanctum_meta').clear();
    _secure.clear();
  });

  testWidgets('master-password dialog dismisses cleanly (no use-after-dispose)',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 300));

    // Open the restore flow -> confirm -> (mocked v3 file) -> password dialog.
    final row = find.text('從 .vault 檔案還原');
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.widgetWithText(TextButton, '確定還原'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // The v3 master-password dialog is up.
    expect(find.text('輸入主密碼'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    // Cancel -> dialog dismisses. With the fix, the State disposes the controller
    // AFTER the route is removed, so no use-after-dispose fires during dismiss.
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // dismiss animation

    expect(find.text('輸入主密碼'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
