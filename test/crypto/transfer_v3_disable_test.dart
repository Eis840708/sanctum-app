// v3 transfer disable regression (DEV-P0-03-UI 子項 D, 方案 A — Eis 定稿).
// Security-hard requirement: a v3 vault must NEVER reach the v2 transfer
// serialiser (which would ship an empty/broken payload = silent data loss).
// This drives the REAL TransferService + VaultService and proves:
//   * v3 vault -> startWifiSend throws TransferUnsupportedException BEFORE
//     _serialize() runs (so _serialize is unreachable for v3);
//   * v2 vault -> the guard does NOT block it (transfer stays unchanged);
//   * isV3Vault is reliable and consistent with the unlock version branch.
// Synthetic data only. Pure service test — imports no widget tree.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:sanctum/core/crypto/crypto_service.dart';
import 'package:sanctum/core/models/models.dart';
import 'package:sanctum/core/storage/vault_service.dart';
import 'package:sanctum/features/transfer/services/transfer_service.dart';

final Map<String, String> _secure = {};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('transfer_v3_');
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
  tearDown(() => transferService.stop());

  group('isV3Vault reliability (transfer branch selector)', () {
    test('false with no vault; true after v3 create; false for seeded v2', () async {
      expect(vaultService.isV3Vault, isFalse);
      await vaultService.createVault('correct horse battery staple');
      expect(vaultService.isV3Vault, isTrue);
      await _wipe();
      await _seedV2();
      expect(vaultService.isV3Vault, isFalse);
    });
  });

  group('v3 vault: transfer serialiser is UNREACHABLE (security-hard)', () {
    test('startWifiSend throws TransferUnsupportedException before _serialize',
        () async {
      await vaultService.createVault('v3-master-123456');
      expect(vaultService.isV3Vault, isTrue);
      await expectLater(
        transferService.startWifiSend(transferService.generateKey()),
        throwsA(isA<TransferUnsupportedException>()),
      );
      // Guard fires before any server bind — nothing left serving.
      expect(transferService.isServing, isFalse);
    });
  });

  group('v2 vault: guard does NOT block transfer (unchanged)', () {
    test('startWifiSend passes the v3 guard (reaches serialize/bind)', () async {
      await _seedV2();
      expect(vaultService.isV3Vault, isFalse);
      // May succeed (binds) or throw a network error ("No WiFi interface") in the
      // test host — either way it must NOT be the v3 TransferUnsupportedException,
      // proving a v2 vault still reaches the transfer path.
      try {
        await transferService.startWifiSend(transferService.generateKey());
      } catch (e) {
        expect(e, isNot(isA<TransferUnsupportedException>()));
      } finally {
        transferService.stop();
      }
    });
  });
}

Future<void> _seedV2() async {
  final salt = cryptoService.generateSalt();
  final key = await cryptoService.deriveKey('legacy-master', salt);
  final vh = await cryptoService.makeVerifyHash(key);
  await Hive.box<VaultMeta>('sanctum_meta').put(
    'meta',
    VaultMeta(
      salt: base64.encode(salt),
      verifyHash: vh,
      createdAt: DateTime(2026, 1, 1),
      lastUnlocked: DateTime(2026, 1, 1),
      version: 'v2',
    ),
  );
  _secure['vault_salt'] = base64.encode(salt);
  _secure['vault_enc_v2'] = 'done';
}

Future<void> _wipe() async {
  vaultService.lock();
  transferService.stop();
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
