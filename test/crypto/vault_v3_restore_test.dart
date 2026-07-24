// Tests for the transactional restore/transfer engine (findings V-01, V-02).
// DEV-P0-03 B2-3. Synthetic data only — no real vault, no real Hive.
//
// The engine is driven through in-memory fakes of its RestoreTarget /
// RestoreJournalStore ports so that failure can be injected at any phase and the
// central invariant asserted directly: a malformed candidate, a verify failure,
// or a crash mid-commit never leaves the "live" namespace in a lost/half state.

import 'package:flutter_test/flutter_test.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_restore.dart';

void main() {
  group('backup structural validation rejects malformed input (V-01)', () {
    test('duplicate id -> duplicateId, no candidate produced', () {
      final json = {
        'version': '2.0',
        'passwords': [
          {'id': 'dup', 'site': 'a', 'username': 'b', 'encryptedPassword': 'c'},
          {'id': 'dup', 'site': 'd', 'username': 'e', 'encryptedPassword': 'f'},
        ],
      };
      expect(
        () => parseAndValidateBackup(json),
        throwsRejectCode(RestoreRejectCode.duplicateId),
      );
    });

    test('imageIndex referencing a missing image -> indexMismatch', () {
      final json = {
        'version': '2.0',
        'images': <String, dynamic>{},
        'imageIndex': {
          'synthetic-diary-1': ['missing-image'],
        },
      };
      expect(
        () => parseAndValidateBackup(json),
        throwsRejectCode(RestoreRejectCode.indexMismatch),
      );
    });

    test('image not referenced by any index entry -> orphanImage', () {
      final json = {
        'version': '2.0',
        'images': {'orphan-image': 'synthetic-ciphertext'},
        'imageIndex': <String, dynamic>{},
      };
      expect(
        () => parseAndValidateBackup(json),
        throwsRejectCode(RestoreRejectCode.orphanImage),
      );
    });

    test('foreign container magic -> unknownVersion', () {
      final json = {'magic': 'SANCTBK', 'version': 65535};
      expect(
        () => parseAndValidateBackup(json),
        throwsRejectCode(RestoreRejectCode.unknownVersion),
      );
    });

    test('integer / future version -> unknownVersion', () {
      expect(
        () => parseAndValidateBackup({'version': 65535}),
        throwsRejectCode(RestoreRejectCode.unknownVersion),
      );
      expect(
        () => parseAndValidateBackup({'version': '3.0'}),
        throwsRejectCode(RestoreRejectCode.unknownVersion),
      );
    });

    test('non-list records -> malformedStructure', () {
      expect(
        () => parseAndValidateBackup({'version': '2.0', 'passwords': 'nope'}),
        throwsRejectCode(RestoreRejectCode.malformedStructure),
      );
    });

    test('record missing id -> malformedStructure', () {
      final json = {
        'version': '2.0',
        'passwords': [
          {'site': 'a', 'username': 'b'},
        ],
      };
      expect(
        () => parseAndValidateBackup(json),
        throwsRejectCode(RestoreRejectCode.malformedStructure),
      );
    });

    test('too many records -> tooManyRecords', () {
      final json = {
        'version': '2.0',
        'passwords': List.generate(6, (i) => {'id': 'p$i'}),
      };
      expect(
        () => parseAndValidateBackup(json,
            limits: const RestoreLimits(maxRecordsPerType: 5)),
        throwsRejectCode(RestoreRejectCode.tooManyRecords),
      );
    });
  });

  group('legacy backups are accepted without loss', () {
    test('legacy v1 without timestamps parses with defaulted dates', () {
      final json = {
        'meta': {'version': 'v1'},
        'passwords': [
          {
            'id': 'synthetic-pw-1',
            'site': 'example.invalid',
            'username': 'demo',
            'encryptedPassword': 'not-a-real-secret',
            'notes': 'legacy plaintext',
          },
        ],
      };
      final staged = parseAndValidateBackup(json);
      expect(staged.passwords, hasLength(1));
      expect(staged.passwords.first.id, 'synthetic-pw-1');
      expect(staged.meta, isNull); // no top-level creds -> same-device restore
      expect(staged.sideEffects.needsReunlock, isFalse);
    });

    test('legacy v2 minimal shape (id + site only) parses', () {
      final json = {
        'meta': {'version': 'v2'},
        'passwords': [
          {'id': 'synthetic-pw-1', 'site': 'AAECAw=='},
        ],
      };
      final staged = parseAndValidateBackup(json);
      expect(staged.passwords.single.username, '');
      expect(staged.passwords.single.encryptedPassword, '');
    });
  });

  group('transactional commit — happy path', () {
    test('valid backup with creds replaces live and installs meta', () async {
      final t = _freshTarget();
      final j = _FakeJournal();
      final staged = parseAndValidateBackup(_validBackup());

      await TransactionalRestore(t, j).commit(staged);

      expect(t.livePwIds, ['p1']);
      expect(t.liveImages.keys, ['img1']);
      expect(t.liveMetaSalt, _backupSalt);
      expect(t.secureSalt, _backupSalt);
      expect(t.encV2Flag, isTrue);
      expect(staged.sideEffects.needsReunlock, isTrue);
      expect(staged.sideEffects.clearSession, isTrue);
      // Journal reached committed then was cleared.
      expect(j.history, contains(RestorePhase.committed));
      expect(j.entry, isNull);
      expect(t.stage, isNull); // staging cleaned up
    });

    test('same-device backup (no creds) leaves meta untouched', () async {
      final t = _freshTarget();
      final j = _FakeJournal();
      final json = _validBackup()
        ..remove('salt')
        ..remove('verifyHash');
      final staged = parseAndValidateBackup(json);

      await TransactionalRestore(t, j).commit(staged);

      expect(staged.meta, isNull);
      expect(t.liveMetaSalt, _originalSalt); // unchanged
      expect(staged.sideEffects.needsReunlock, isFalse);
      expect(staged.sideEffects.clearSession, isFalse);
    });
  });

  group('rollback — nothing destructive before validation passes', () {
    test('staging verify failure leaves live vault untouched', () async {
      final t = _freshTarget()..failVerify = true;
      final j = _FakeJournal();
      final staged = parseAndValidateBackup(_validBackup());

      await expectLater(
        TransactionalRestore(t, j).commit(staged),
        throwsA(isA<RestoreValidationException>()),
      );

      // Sentinel survived; commit-intent was never journalled.
      expect(t.livePwIds, _sentinelPwIds);
      expect(t.liveMetaSalt, _originalSalt);
      expect(t.commitCalls, 0);
      expect(j.history, isNot(contains(RestorePhase.commitIntent)));
      expect(j.entry, isNull);
      expect(t.stage, isNull);
    });
  });

  group('interrupt safety — crash mid-commit resumes forward', () {
    test('crash after live cleared, then resume, yields complete new vault',
        () async {
      final t = _freshTarget()
        ..failCommitTimes = 1
        ..crashAfterClear = true;
      final j = _FakeJournal();
      final staged = parseAndValidateBackup(_validBackup());

      // First attempt crashes during the swap (live cleared, not yet copied).
      await expectLater(
        TransactionalRestore(t, j).commit(staged),
        throwsA(isA<StateError>()),
      );
      expect(t.livePwIds, isEmpty); // dangerous half state on disk
      expect(j.entry!.phase, RestorePhase.commitIntent); // durable intent
      expect(t.stage, isNotNull); // staging preserved for resume

      // Resume (e.g. next launch) finishes the swap idempotently.
      await TransactionalRestore(t, j).recover();
      expect(t.livePwIds, ['p1']);
      expect(t.liveMetaSalt, _backupSalt);
      expect(t.encV2Flag, isTrue);
      expect(j.entry, isNull);
      expect(t.stage, isNull);

      // Recover again -> no-op (idempotent).
      await TransactionalRestore(t, j).recover();
      expect(t.livePwIds, ['p1']);
    });

    test('a fresh commit first recovers a prior interrupted transaction',
        () async {
      final t = _freshTarget()
        ..failCommitTimes = 1
        ..crashAfterClear = true;
      final j = _FakeJournal();
      final first = parseAndValidateBackup(_validBackup());

      await expectLater(
        TransactionalRestore(t, j).commit(first),
        throwsA(isA<StateError>()),
      );
      expect(j.entry!.phase, RestorePhase.commitIntent);

      // A brand-new restore begins by recovering the interrupted one, then
      // commits its own candidate cleanly.
      t.crashAfterClear = false;
      t.failCommitTimes = 0;
      final second = parseAndValidateBackup(_validBackup(pwId: 'p2'));
      await TransactionalRestore(t, j).commit(second);
      expect(t.livePwIds, ['p2']);
      expect(j.entry, isNull);
    });
  });

  group('transfer validation and transactional import (V-02)', () {
    test('valid transfer replaces vault and destroys biometric wrapper',
        () async {
      final t = _freshTarget();
      final j = _FakeJournal();
      final staged = parseAndValidateTransfer(_validTransfer());

      await TransactionalRestore(t, j).commit(staged);

      expect(t.livePwIds, ['p1']);
      expect(t.liveMetaSalt, _transferSalt);
      expect(t.biometricPresent, isFalse); // biometric wrapper destroyed
      expect(staged.sideEffects.deleteBiometricKey, isTrue);
      expect(staged.sideEffects.needsReunlock, isTrue);
    });

    test('missing credentials -> missingCredentials, vault + biometric survive',
        () {
      final payload = _validTransfer()..remove('sl');
      expect(
        () => parseAndValidateTransfer(payload),
        throwsRejectCode(RestoreRejectCode.missingCredentials),
      );
    });

    test('duplicate id in transfer payload -> duplicateId', () {
      final payload = _validTransfer();
      (payload['pw'] as List).add({'id': 'p1', 'si': 'x'});
      expect(
        () => parseAndValidateTransfer(payload),
        throwsRejectCode(RestoreRejectCode.duplicateId),
      );
    });

    test('malformed transfer never mutates live when run through the pipeline',
        () async {
      final t = _freshTarget();
      final j = _FakeJournal();
      final payload = _validTransfer()..remove('sl');

      await expectLater(
        _runTransfer(payload, t, j),
        throwsRejectCode(RestoreRejectCode.missingCredentials),
      );
      expect(t.livePwIds, _sentinelPwIds);
      expect(t.biometricPresent, isTrue);
      expect(t.liveMetaSalt, _originalSalt);
    });
  });
}

// ── Pipeline helper mirroring vault_service ──────────────────────────────────

Future<void> _runTransfer(
    Map<String, dynamic> d, _FakeTarget t, _FakeJournal j) async {
  final staged = parseAndValidateTransfer(d);
  await TransactionalRestore(t, j).commit(staged);
}

// ── Fixtures (synthetic) ─────────────────────────────────────────────────────

const String _backupSalt = 'QkFDS1VQLVNBTFQ='; // base64("BACKUP-SALT")
const String _transferSalt = 'VFJBTlNGRVI='; // base64("TRANSFER")
const String _originalSalt = 'ORIGINAL-SALT';
const List<String> _sentinelPwIds = ['SENTINEL-PW'];

Map<String, dynamic> _validBackup({String pwId = 'p1'}) => {
      'version': '2.0',
      'salt': _backupSalt,
      'verifyHash': 'vh-xyz',
      'passwords': [
        {
          'id': pwId,
          'site': 's',
          'username': 'u',
          'encryptedPassword': 'e',
          'notes': '',
          'createdAt': '2026-01-01T00:00:00Z',
          'updatedAt': '2026-01-01T00:00:00Z',
        },
      ],
      'diary': <dynamic>[],
      'finance': <dynamic>[],
      'images': {'img1': 'cipher'},
      'imageIndex': {
        'd1': ['img1'],
      },
    };

Map<String, dynamic> _validTransfer() => {
      't': 'sct',
      'sl': _transferSalt,
      'vh': 'vh',
      'pw': <dynamic>[
        {
          'id': 'p1',
          'si': 's',
          'un': 'u',
          'ep': 'e',
          'no': '',
          'ca': 1700000000000,
          'ua': 1700000000000,
        },
      ],
      'di': <dynamic>[],
      'fi': <dynamic>[],
      'im': <String, dynamic>{},
      'ii': <String, dynamic>{},
    };

// ── Matchers ─────────────────────────────────────────────────────────────────

Matcher throwsRejectCode(RestoreRejectCode code) => throwsA(
      isA<RestoreValidationException>().having((e) => e.code, 'code', code),
    );

// ── Fakes ────────────────────────────────────────────────────────────────────

_FakeTarget _freshTarget() => _FakeTarget(
      livePwIds: List.of(_sentinelPwIds),
      liveMetaSalt: _originalSalt,
      secureSalt: _originalSalt,
      encV2Flag: true,
      biometricPresent: true,
    );

class _FakeTarget implements RestoreTarget {
  _FakeTarget({
    required this.livePwIds,
    required this.liveMetaSalt,
    required this.secureSalt,
    required this.encV2Flag,
    required this.biometricPresent,
  });

  // Live namespace (content signatures).
  List<String> livePwIds;
  Map<String, String> liveImages = {};
  Map<String, List<String>> liveImageIndex = {};
  String? liveMetaSalt;

  // Secure-storage mirror.
  String? secureSalt;
  bool encV2Flag;
  bool biometricPresent;

  // Staging + fault injection.
  StagedVault? stage;
  bool failVerify = false;
  int failCommitTimes = 0;
  bool crashAfterClear = false;
  int commitCalls = 0;

  @override
  Future<void> writeStaging(StagedVault data) async {
    stage = data;
  }

  @override
  Future<bool> verifyStaging(StagedVault data) async => !failVerify;

  @override
  Future<void> commitStagingToLive() async {
    commitCalls++;
    if (commitCalls <= failCommitTimes) {
      if (crashAfterClear) _clearLive();
      throw StateError('injected commit crash #$commitCalls');
    }
    _clearLive();
    final s = stage!;
    livePwIds = s.passwords.map((e) => e.id).toList();
    liveImages = Map.of(s.images);
    liveImageIndex = {
      for (final e in s.imageIndex.entries) e.key: List.of(e.value),
    };
    if (s.meta != null) liveMetaSalt = s.meta!.salt;
  }

  void _clearLive() {
    livePwIds = [];
    liveImages = {};
    liveImageIndex = {};
  }

  @override
  Future<void> applyCommitSideEffects(RestoreSideEffects effects) async {
    if (effects.salt != null) secureSalt = effects.salt;
    if (effects.installEncV2Done) encV2Flag = true;
    if (effects.deleteBiometricKey) biometricPresent = false;
  }

  @override
  Future<void> discardStaging() async {
    stage = null;
  }
}

class _FakeJournal implements RestoreJournalStore {
  RestoreJournalEntry? entry;
  final List<RestorePhase> history = [];

  @override
  Future<RestoreJournalEntry?> read() async => entry;

  @override
  Future<void> write(RestoreJournalEntry e) async {
    entry = e;
    history.add(e.phase);
  }

  @override
  Future<void> clear() async {
    entry = null;
  }
}
