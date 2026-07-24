// Real-adapter regression tests for transactional restore/transfer (V-01, V-02).
// DEV-P0-03 B2-3. Adopted from the QA acceptance harness per the convergence
// ruling (DEV-P0-03-B2-3-convergence-ruling-v1 §3.3): the engine's own unit tests
// drive the PURE engine with in-memory fakes, which never exercise the real
// HiveRestoreTarget adapter where the actual destructive Hive ops
// (livePasswords.clear(), etc.) live. This suite stands up REAL Hive boxes in a
// temp dir, seeds a SENTINEL vault, wires the real openHiveRestore() adapter over
// a mocked secure-storage channel, and drives the same entry path VaultService
// uses (parseAndValidate* -> TransactionalRestore.commit / recover).
//
// Synthetic data only — no real vault. Closes the "fakes-only" coverage gap
// permanently: malformed input through the real path must leave the existing
// vault intact; the happy path proves the real destructive swap actually works;
// the resume path proves an interrupted commit finishes forward.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:sanctum/core/crypto/v3/vault_v3_restore.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_restore_hive.dart';
import 'package:sanctum/core/models/models.dart';

// Live box names mirror VaultService.
const _pwBox = 'sanctum_passwords';
const _diBox = 'sanctum_diary';
const _fiBox = 'sanctum_finance';
const _imBox = 'sanctum_images';
const _iiBox = 'sanctum_image_index';
const _mtBox = 'sanctum_meta';

const _saltKey = 'vault_salt';
const _bioKey = 'vault_biometric_key';
const _encV2Key = 'vault_enc_v2';

const _sentinelPwId = 'SENTINEL-PW';
const _originalSalt = 'ORIGINAL-SALT-B64';
const _originalVh = 'ORIGINAL-VH';
const _bioWrapper = 'ORIGINAL-BIOMETRIC-WRAPPER';

late Directory _tmp;
// In-memory secure storage backing the mocked plugin channel.
final Map<String, String> _secure = {};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('b2_3_real_');
    Hive.init(_tmp.path);
    Hive.registerAdapter(PasswordEntryAdapter());
    Hive.registerAdapter(DiaryEntryAdapter());
    Hive.registerAdapter(FinanceRecordAdapter());
    Hive.registerAdapter(VaultMetaAdapter());

    // Mock flutter_secure_storage's platform channel with an in-memory map.
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'write':
          _secure[key!] = args['value'] as String;
          return null;
        case 'read':
          return _secure[key];
        case 'delete':
          _secure.remove(key);
          return null;
        case 'deleteAll':
          _secure.clear();
          return null;
        case 'readAll':
          return Map<String, String>.from(_secure);
        case 'containsKey':
          return _secure.containsKey(key);
        default:
          return null;
      }
    });
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await _tmp.delete(recursive: true);
    } catch (_) {}
  });

  // Fresh live vault + secure storage before every case.
  setUp(() async {
    await _resetLiveVaultToSentinel();
  });

  // ── Core P0 proof: malformed backup through the REAL adapter path (V-01) ─────

  final malformedBackups = <String, Map<String, dynamic>>{
    'wrong-type records (passwords not a list)': {
      'version': '2.0',
      'salt': 'ATTACKER',
      'verifyHash': 'x',
      'passwords': 'not-a-list',
    },
    'missing id': {
      'version': '2.0',
      'salt': 'ATTACKER',
      'verifyHash': 'x',
      'passwords': [
        {'site': 'a', 'username': 'b', 'encryptedPassword': 'c'},
      ],
    },
    'duplicate id': {
      'version': '2.0',
      'salt': 'ATTACKER',
      'verifyHash': 'x',
      'passwords': [
        {'id': 'd', 'site': 'a', 'username': 'b', 'encryptedPassword': 'c'},
        {'id': 'd', 'site': 'e', 'username': 'f', 'encryptedPassword': 'g'},
      ],
    },
    'index references missing image (index-mismatch)': {
      'version': '2.0',
      'salt': 'ATTACKER',
      'verifyHash': 'x',
      'images': <String, dynamic>{},
      'imageIndex': {
        'k': ['ghost'],
      },
    },
    'orphan image': {
      'version': '2.0',
      'salt': 'ATTACKER',
      'verifyHash': 'x',
      'images': {'orphan': 'cipher'},
      'imageIndex': <String, dynamic>{},
    },
    'future version': {
      'version': '3.0',
      'salt': 'ATTACKER',
      'verifyHash': 'x',
    },
    'foreign container magic': {
      'magic': 'SANCTBK',
      'version': 65535,
    },
    'bad date string': {
      'version': '2.0',
      'salt': 'ATTACKER',
      'verifyHash': 'x',
      'passwords': [
        {
          'id': 'p',
          'site': 'a',
          'username': 'b',
          'encryptedPassword': 'c',
          'createdAt': 'NOT-A-DATE',
        },
      ],
    },
    'wrong-typed field mid-parse (truncated/corrupt)': {
      'passwords': [
        {'id': 'p', 'site': 42}, // site wrong type -> malformedStructure
      ],
    },
  };

  malformedBackups.forEach((name, json) {
    test('BACKUP malformed [$name] -> existing vault fully survives', () async {
      await expectLater(_restore(json), throwsA(isA<Exception>()));
      await _expectSentinelIntact();
    });
  });

  // ── Malformed transfer through the REAL adapter path (V-02) ─────────────────

  final malformedTransfers = <String, Map<String, dynamic>>{
    'missing salt (credentials)': {
      'vh': 'x',
      'pw': <dynamic>[],
    },
    'empty verifyHash': {
      'sl': 'ATTACKER',
      'vh': '',
      'pw': <dynamic>[],
    },
    'duplicate id': {
      'sl': 'ATTACKER',
      'vh': 'x',
      'pw': [
        {'id': 'p1', 'si': 'a'},
        {'id': 'p1', 'si': 'b'},
      ],
    },
    'pw not a list': {
      'sl': 'ATTACKER',
      'vh': 'x',
      'pw': 'nope',
    },
  };

  malformedTransfers.forEach((name, payload) {
    test('TRANSFER malformed [$name] -> vault + biometric + meta survive',
        () async {
      await expectLater(_transfer(payload), throwsA(isA<Exception>()));
      await _expectSentinelIntact();
      expect(_secure[_bioKey], _bioWrapper,
          reason: 'biometric wrapper wiped by a rejected transfer');
    });
  });

  // ── Happy paths through the REAL adapter (prove the destructive swap works) ──

  test('BACKUP valid with creds -> live replaced, meta+salt installed',
      () async {
    final ok = await _restore({
      'version': '2.0',
      'salt': 'NEW-SALT',
      'verifyHash': 'NEW-VH',
      'passwords': [
        {
          'id': 'NEW-PW',
          'site': 's',
          'username': 'u',
          'encryptedPassword': 'e',
          'createdAt': '2026-01-01T00:00:00Z',
          'updatedAt': '2026-01-01T00:00:00Z',
        },
      ],
    });
    expect(ok, isTrue); // needs re-unlock
    final pw = await Hive.openBox<PasswordEntry>(_pwBox);
    expect(pw.keys.toList(), ['NEW-PW']);
    expect(_secure[_saltKey], 'NEW-SALT');
    expect(_secure[_encV2Key], 'done');
    final meta = await Hive.openBox<VaultMeta>(_mtBox);
    expect(meta.get('meta')!.salt, 'NEW-SALT');
  });

  test('BACKUP no-creds (same-device) -> live replaced, meta left intact',
      () async {
    final ok = await _restore({
      'version': '2.0',
      'passwords': [
        {
          'id': 'SD-PW',
          'site': 's',
          'username': 'u',
          'encryptedPassword': 'e',
          'createdAt': '2026-01-01T00:00:00Z',
          'updatedAt': '2026-01-01T00:00:00Z',
        },
      ],
    });
    expect(ok, isFalse); // stays unlocked, no re-unlock
    final pw = await Hive.openBox<PasswordEntry>(_pwBox);
    expect(pw.keys.toList(), ['SD-PW']);
    final meta = await Hive.openBox<VaultMeta>(_mtBox);
    expect(meta.get('meta')!.salt, _originalSalt); // meta untouched
    expect(_secure[_saltKey], _originalSalt);
  });

  test('TRANSFER valid -> live replaced, biometric wrapper destroyed',
      () async {
    await _transfer({
      'sl': 'T-SALT',
      'vh': 'T-VH',
      'pw': [
        {
          'id': 'T-PW',
          'si': 's',
          'un': 'u',
          'ep': 'e',
          'ca': 1700000000000,
          'ua': 1700000000000,
        },
      ],
      'di': <dynamic>[],
      'fi': <dynamic>[],
    });
    final pw = await Hive.openBox<PasswordEntry>(_pwBox);
    expect(pw.keys.toList(), ['T-PW']);
    expect(_secure.containsKey(_bioKey), isFalse); // wrapper destroyed
    expect(_secure[_saltKey], 'T-SALT');
  });

  // ── Resume through the REAL adapter (B2-3 seam 2, interrupt safety) ──────────

  test('resume: no journal -> safe no-op (idempotent)', () async {
    final tx = await _openTx();
    await tx.recover();
    await tx.recover();
    await _expectSentinelIntact();
  });

  test('resume: commit interrupted at commit-intent finishes forward on recover',
      () async {
    final target = await _openTarget();
    final journal = await HiveRestoreJournalStore.open();
    final staged = parseAndValidateBackup({
      'version': '2.0',
      'salt': 'RESUME-SALT',
      'verifyHash': 'RVH',
      'passwords': [
        {
          'id': 'RESUME-PW',
          'site': 's',
          'username': 'u',
          'encryptedPassword': 'e',
          'createdAt': '2026-01-01T00:00:00Z',
          'updatedAt': '2026-01-01T00:00:00Z',
        },
      ],
    });

    // Simulate a power loss AFTER the durable stage was written and commit-intent
    // recorded, but BEFORE the live swap ran.
    await target.writeStaging(staged);
    await journal
        .write(RestoreJournalEntry(RestorePhase.commitIntent, staged.sideEffects));
    await _expectSentinelIntact(); // swap has not happened yet

    // Resume (mirrors unlock() -> recoverPendingRestore()).
    await TransactionalRestore(target, journal).recover();

    final pw = await Hive.openBox<PasswordEntry>(_pwBox);
    expect(pw.keys.toList(), ['RESUME-PW']);
    expect(_secure[_saltKey], 'RESUME-SALT');
    expect(_secure[_encV2Key], 'done');
    expect(await journal.read(), isNull); // journal cleared after resume

    // Recovering again is a no-op.
    await TransactionalRestore(target, journal).recover();
    final pw2 = await Hive.openBox<PasswordEntry>(_pwBox);
    expect(pw2.keys.toList(), ['RESUME-PW']);
  });

  test('resume: interrupted before commit-intent rolls back, vault intact',
      () async {
    final target = await _openTarget();
    final journal = await HiveRestoreJournalStore.open();
    final staged = parseAndValidateBackup({
      'version': '2.0',
      'salt': 'ROLLBACK-SALT',
      'verifyHash': 'RBVH',
      'passwords': [
        {
          'id': 'RB-PW',
          'site': 's',
          'username': 'u',
          'encryptedPassword': 'e',
          'createdAt': '2026-01-01T00:00:00Z',
          'updatedAt': '2026-01-01T00:00:00Z',
        },
      ],
    });

    // Crash after staging but only at the 'staged' phase (never reached intent).
    await target.writeStaging(staged);
    await journal
        .write(RestoreJournalEntry(RestorePhase.staged, staged.sideEffects));

    await TransactionalRestore(target, journal).recover();

    // Rolled back: staging discarded, live vault + secure storage untouched.
    await _expectSentinelIntact();
    expect(await journal.read(), isNull);
  });
}

// ── Drivers mirroring VaultService.importFromBackup / importTransfer ──────────

Future<bool> _restore(Map<String, dynamic> json) async {
  final staged = parseAndValidateBackup(json);
  final tx = await _openTx();
  await tx.commit(staged);
  return staged.sideEffects.needsReunlock;
}

Future<void> _transfer(Map<String, dynamic> d) async {
  final staged = parseAndValidateTransfer(d);
  final tx = await _openTx();
  await tx.commit(staged);
}

Future<TransactionalRestore> _openTx() async => openHiveRestore(
      livePasswords: await Hive.openBox<PasswordEntry>(_pwBox),
      liveDiary: await Hive.openBox<DiaryEntry>(_diBox),
      liveFinance: await Hive.openBox<FinanceRecord>(_fiBox),
      liveImages: await Hive.openBox<String>(_imBox),
      liveImageIndex: await Hive.openBox(_iiBox),
      liveMeta: await Hive.openBox<VaultMeta>(_mtBox),
      secureStorage: const FlutterSecureStorage(),
      saltKey: _saltKey,
      biometricKey: _bioKey,
      encV2Key: _encV2Key,
    );

Future<HiveRestoreTarget> _openTarget() async => HiveRestoreTarget.open(
      livePasswords: await Hive.openBox<PasswordEntry>(_pwBox),
      liveDiary: await Hive.openBox<DiaryEntry>(_diBox),
      liveFinance: await Hive.openBox<FinanceRecord>(_fiBox),
      liveImages: await Hive.openBox<String>(_imBox),
      liveImageIndex: await Hive.openBox(_iiBox),
      liveMeta: await Hive.openBox<VaultMeta>(_mtBox),
      secureStorage: const FlutterSecureStorage(),
      saltKey: _saltKey,
      biometricKey: _bioKey,
      encV2Key: _encV2Key,
    );

// ── Live-vault fixture + survival assertion ──────────────────────────────────

Future<void> _resetLiveVaultToSentinel() async {
  // Wipe everything (incl. leftover staging/journal boxes) and rebuild sentinel.
  await Hive.deleteBoxFromDisk('${_pwBox}__staging');
  await Hive.deleteBoxFromDisk('${_diBox}__staging');
  await Hive.deleteBoxFromDisk('${_fiBox}__staging');
  await Hive.deleteBoxFromDisk('${_imBox}__staging');
  await Hive.deleteBoxFromDisk('${_iiBox}__staging');
  await Hive.deleteBoxFromDisk('${_mtBox}__staging');
  await Hive.deleteBoxFromDisk('sanctum_restore_journal');

  final pw = await Hive.openBox<PasswordEntry>(_pwBox);
  await pw.clear();
  await pw.put(
    _sentinelPwId,
    PasswordEntry(
      id: _sentinelPwId,
      site: 'sentinel.invalid',
      username: 'keep-me',
      encryptedPassword: 'do-not-lose',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    ),
  );
  final di = await Hive.openBox<DiaryEntry>(_diBox);
  await di.clear();
  await di.put(
    'SENTINEL-DIARY',
    DiaryEntry(
      id: 'SENTINEL-DIARY',
      title: 't',
      encryptedContent: 'c',
      mood: 'm',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    ),
  );
  final mt = await Hive.openBox<VaultMeta>(_mtBox);
  await mt.clear();
  await mt.put(
    'meta',
    VaultMeta(
      salt: _originalSalt,
      verifyHash: _originalVh,
      createdAt: DateTime(2026, 1, 1),
      lastUnlocked: DateTime(2026, 1, 1),
      version: 'v2',
    ),
  );
  final im = await Hive.openBox<String>(_imBox);
  await im.clear();
  final ii = await Hive.openBox(_iiBox);
  await ii.clear();

  _secure
    ..clear()
    ..[_saltKey] = _originalSalt
    ..[_bioKey] = _bioWrapper
    ..[_encV2Key] = 'done';
}

Future<void> _expectSentinelIntact() async {
  final pw = await Hive.openBox<PasswordEntry>(_pwBox);
  expect(pw.keys.toList(), [_sentinelPwId],
      reason: 'password vault altered by a rejected restore');
  expect(pw.get(_sentinelPwId)!.encryptedPassword, 'do-not-lose');

  final di = await Hive.openBox<DiaryEntry>(_diBox);
  expect(di.keys.toList(), ['SENTINEL-DIARY'], reason: 'diary altered');

  final mt = await Hive.openBox<VaultMeta>(_mtBox);
  expect(mt.get('meta')!.salt, _originalSalt, reason: 'meta salt overwritten');

  expect(_secure[_saltKey], _originalSalt,
      reason: 'secure-storage salt overwritten by a rejected restore');
}
