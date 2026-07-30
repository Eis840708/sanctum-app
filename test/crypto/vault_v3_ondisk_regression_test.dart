// Adopted from QA's independent B2-5b harness per the approval ruling
// (DEV-P0-03-B2-5b-批核決定-及-release-sequencing-裁定-v1 §1). Committed regression.
//
// Goes beyond the producer suite:
//  1. V-06 per-field AAD including the cross-VAULT swap (different vaultId must
//     fail), plus cross-slot / cross-record.
//  2. No-plaintext proof at the strongest level: scan the raw ON-DISK .hive files
//     (not just the JSON the producer chose) for known secrets after a real
//     migration, and confirm the v2 box files were cleared.
//  3. finance amount precision round-trip edge cases (director concern B).
// Synthetic data only.

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:sanctum/core/crypto/crypto_service.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_envelope.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_record.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_store.dart';
import 'package:sanctum/core/models/models.dart';
import 'package:sanctum/core/storage/vault_service.dart';

final Map<String, String> _secure = {};
late Directory _tmp;
const _pw = 'legacy-master-password';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('b2_5b_ondisk_');
    const pp = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pp, (c) async => _tmp.path);
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

  setUp(_wipe);

  // ── 1. V-06 per-field AAD: cross-VAULT swap (uncovered case) + others ────────
  group('V-06 per-field AAD binding (real codec)', () {
    final codec = VaultV3RecordCodec();
    final vaultA = Uint8List.fromList(List.generate(16, (i) => i));
    final vaultB = Uint8List.fromList(List.generate(16, (i) => 200 - i));
    final key = SecretKey(List.generate(32, (i) => (i * 3) & 0xFF));

    test('ciphertext decoded under a DIFFERENT vaultId fails (vault AAD)',
        () async {
      final stored = await codec.encode(
        recordType: RecordType.password,
        id: 'rec-1',
        fields: {V3FieldId.pwPassword: 'top-secret'},
        dataKey: key,
        vaultId: vaultA,
      );
      await expectLater(
        codec.decode(
            recordType: RecordType.password,
            id: 'rec-1',
            stored: stored,
            dataKey: key,
            vaultId: vaultB), // wrong vault
        throwsA(anything),
        reason: 'cross-vault ciphertext reuse must fail the AAD tag',
      );
      final ok = await codec.decode(
          recordType: RecordType.password,
          id: 'rec-1',
          stored: stored,
          dataKey: key,
          vaultId: vaultA);
      expect(ok[V3FieldId.pwPassword], 'top-secret');
    });

    test('cross-slot swap within a record fails (fieldId AAD)', () async {
      final stored = await codec.encode(
        recordType: RecordType.password,
        id: 'r',
        fields: {V3FieldId.pwSite: 'S', V3FieldId.pwUsername: 'U'},
        dataKey: key,
        vaultId: vaultA,
      );
      final map = jsonDecode(stored) as Map;
      final f = (map['f'] as Map).cast<String, Object?>();
      final t = f['1']; f['1'] = f['2']; f['2'] = t; // swap slots
      await expectLater(
        codec.decode(
            recordType: RecordType.password,
            id: 'r',
            stored: jsonEncode({'sv': map['sv'], 'f': f}),
            dataKey: key,
            vaultId: vaultA),
        throwsA(anything),
      );
    });

    test('cross-record swap fails (recordId AAD)', () async {
      final stored = await codec.encode(
        recordType: RecordType.diary,
        id: 'diary-A',
        fields: {V3FieldId.diaryTitle: 'T'},
        dataKey: key,
        vaultId: vaultA,
      );
      await expectLater(
        codec.decode(
            recordType: RecordType.diary,
            id: 'diary-B',
            stored: stored,
            dataKey: key,
            vaultId: vaultA),
        throwsA(anything),
      );
    });
  });

  // ── 2. No sensitive plaintext in the raw ON-DISK .hive files after migration ─
  test('raw on-disk v3 files hold no sensitive plaintext; v2 files cleared',
      () async {
    await _seedV2Vault();
    final ok = await vaultService.unlock(_pw); // triggers auto-migration
    expect(ok, isTrue);
    expect(Hive.box<VaultMeta>('sanctum_meta').get('meta')!.version, 'v3');

    await Hive.box<PasswordEntry>('sanctum_passwords').flush();
    await Hive.box<DiaryEntry>('sanctum_diary').flush();
    await Hive.box<FinanceRecord>('sanctum_finance').flush();
    for (final n in const [
      'sanctum_passwords__v3', 'sanctum_diary__v3', 'sanctum_finance__v3',
    ]) {
      if (Hive.isBoxOpen(n)) await Hive.box(n).flush();
    }
    final onDisk = StringBuffer();
    final v2Files = <String>[];
    for (final f in _tmp.listSync(recursive: true).whereType<File>()) {
      final name = f.path.toLowerCase();
      if (!name.endsWith('.hive')) continue;
      final text = String.fromCharCodes(f.readAsBytesSync());
      onDisk.write(text);
      onDisk.write('\n');
      if (name.endsWith('sanctum_passwords.hive') ||
          name.endsWith('sanctum_diary.hive') ||
          name.endsWith('sanctum_finance.hive')) {
        v2Files.add(text);
      }
    }
    final all = onDisk.toString();
    for (final secret in const [
      'bank.invalid', 'jsmith', 'hunter2', 'my day', 'dear diary',
      'calm', 'groceries', 'weekly shop', '4321.99',
    ]) {
      expect(all.contains(secret), isFalse,
          reason: 'plaintext "$secret" found in a raw .hive file');
    }
    for (final v2 in v2Files) {
      for (final secret in const ['bank.invalid', 'hunter2', 'dear diary']) {
        expect(v2.contains(secret), isFalse,
            reason: 'v2 box still holds plaintext after migration');
      }
    }
  });

  // ── 3. amount precision round-trip edge cases (concern B) ────────────────────
  test('finance amount survives precision edge cases through the v3 store',
      () async {
    final store = VaultV3Store(
      dataKey: SecretKey(List.filled(32, 7)),
      vaultId: Uint8List(16),
    );
    final box = await Hive.openBox('qa_amount_probe__v3');
    for (final amount in const [
      0.0, 4321.99, 1234567890.12, 0.01, -9999.99, 999999999999.99, 0.1 + 0.2,
    ]) {
      await store.put(
        box: box,
        recordType: RecordType.finance,
        id: 'a',
        fields: financeToFields(FinanceRecord(
          id: 'a', type: 't', amount: amount, category: 'c',
          description: 'd', date: DateTime(2026, 1, 1),
          createdAt: DateTime(2026, 1, 1), currency: 'HKD',
        )),
      );
      final fields = await store.get(
          box: box, recordType: RecordType.finance, id: 'a');
      final r = financeFromFields('a', fields!);
      expect(r.amount, amount, reason: 'amount $amount did not round-trip');
    }
    await box.clear();
  });
}

Future<void> _seedV2Vault() async {
  final salt = cryptoService.generateSalt();
  final key = await cryptoService.deriveKey(_pw, salt);
  final vh = await cryptoService.makeVerifyHash(key);
  await Hive.box<PasswordEntry>('sanctum_passwords').put(
    'pw-1',
    PasswordEntry(
      id: 'pw-1',
      site: await cryptoService.encrypt('bank.invalid', key),
      username: await cryptoService.encrypt('jsmith', key),
      encryptedPassword: await cryptoService.encrypt('hunter2', key),
      createdAt: DateTime(2026, 1, 1), updatedAt: DateTime(2026, 1, 2),
    ),
  );
  await Hive.box<DiaryEntry>('sanctum_diary').put(
    'd-1',
    DiaryEntry(
      id: 'd-1',
      title: await cryptoService.encrypt('my day', key),
      encryptedContent: await cryptoService.encrypt('dear diary', key),
      mood: await cryptoService.encrypt('calm', key),
      tags: const ['personal'],
      createdAt: DateTime(2026, 1, 1), updatedAt: DateTime(2026, 1, 1),
    ),
  );
  await Hive.box<FinanceRecord>('sanctum_finance').put(
    'f-1',
    FinanceRecord(
      id: 'f-1',
      type: await cryptoService.encrypt('expense', key),
      amount: 4321.99,
      category: await cryptoService.encrypt('groceries', key),
      description: await cryptoService.encrypt('weekly shop', key),
      date: DateTime(2026, 1, 3), createdAt: DateTime(2026, 1, 3),
      currency: 'HKD',
    ),
  );
  await Hive.box<VaultMeta>('sanctum_meta').put(
    'meta',
    VaultMeta(
      salt: base64.encode(salt), verifyHash: vh,
      createdAt: DateTime(2026, 1, 1), lastUnlocked: DateTime(2026, 1, 1),
      version: 'v2',
    ),
  );
  _secure['vault_salt'] = base64.encode(salt);
  _secure['vault_enc_v2'] = 'done';
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
  for (final name in const [
    'sanctum_passwords__v3', 'sanctum_diary__v3', 'sanctum_finance__v3',
    'sanctum_images__v3', 'sanctum_image_index__v3',
  ]) {
    await (await Hive.openBox(name)).clear();
    await (await Hive.openBox('${name}__staging')).clear();
  }
  await (await Hive.openBox('sanctum_migration_journal')).clear();
  _secure.clear();
}
