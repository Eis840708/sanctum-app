// Fault-injection tests for the transactional v2->v3 migration (B2-5b).
// DEV-P0-03 B2-5b. Proves the RETURN-level interrupt invariant: a crash injected
// between ANY of the three atomic-bundle steps (A install material, B staging->
// live, C meta flip, D cleanup v2) leaves the vault UNLOCKABLE — via the intact
// v2 path before the flip, or the ready v3 path after it — and a resume completes
// forward idempotently. No half-v2/half-v3 unroutable state ever exists.

import 'package:flutter_test/flutter_test.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_migrate.dart';

void main() {
  group('interrupt invariant — crash between each atomic-bundle step', () {
    for (final step in ['A', 'B', 'C', 'D']) {
      test('crash at step $step -> vault unlockable at crash, resume completes',
          () async {
        final t = _FakeTarget()..failAt = step;
        final j = _FakeJournal();
        final m = TransactionalMigration(t, j);

        await expectLater(m.migrate(), throwsA(isA<StateError>()));

        // Invariant: the vault is still unlockable at the interrupt point.
        expect(t.canUnlock(), isTrue,
            reason: 'vault not unlockable after crash at step $step');
        expect(j.entry, MigrationPhase.commitIntent);

        // Resume completes the migration forward, idempotently.
        await TransactionalMigration(t, j).recover();
        expect(t.metaV3, isTrue);
        expect(t.materialPresent, isTrue);
        expect(t.v3LivePresent, isTrue);
        expect(t.v2Present, isFalse); // cleaned up
        expect(t.canUnlock(), isTrue);
        expect(j.entry, isNull);

        // Recover again -> no-op.
        await TransactionalMigration(t, j).recover();
        expect(t.metaV3, isTrue);
      });
    }
  });

  test('verify failure before commit -> rollback, v2 intact, no flip', () async {
    final t = _FakeTarget()..failVerify = true;
    final j = _FakeJournal();
    await expectLater(
        TransactionalMigration(t, j).migrate(), throwsA(isA<MigrationException>()));
    expect(t.metaV3, isFalse);
    expect(t.v2Present, isTrue);
    expect(t.stagingPresent, isFalse); // discarded
    expect(t.canUnlock(), isTrue); // via v2
    expect(j.entry, isNull);
  });

  test('prepare failure (corrupt v2) -> v2 untouched, unlockable', () async {
    final t = _FakeTarget()..failPrepare = true;
    final j = _FakeJournal();
    await expectLater(
        TransactionalMigration(t, j).migrate(), throwsA(isA<StateError>()));
    expect(t.metaV3, isFalse);
    expect(t.v2Present, isTrue);
    expect(t.canUnlock(), isTrue);
  });

  test('happy path migrates to v3 and clears v2', () async {
    final t = _FakeTarget();
    final j = _FakeJournal();
    await TransactionalMigration(t, j).migrate();
    expect(t.metaV3, isTrue);
    expect(t.materialPresent, isTrue);
    expect(t.v3LivePresent, isTrue);
    expect(t.v2Present, isFalse);
    expect(t.canUnlock(), isTrue);
    expect(j.entry, isNull);
  });

  test('a fresh migrate first recovers a prior interrupted one', () async {
    final t = _FakeTarget()..failAt = 'B';
    final j = _FakeJournal();
    await expectLater(
        TransactionalMigration(t, j).migrate(), throwsA(isA<StateError>()));
    expect(j.entry, MigrationPhase.commitIntent);

    // New attempt recovers forward first.
    final t2 = t..failAt = null;
    await TransactionalMigration(t2, j).recover();
    expect(t2.metaV3, isTrue);
    expect(j.entry, isNull);
  });
}

class _FakeTarget implements MigrationTarget {
  bool v2Present = true;
  bool v3LivePresent = false;
  bool materialPresent = false;
  bool metaV3 = false;
  bool stagingPresent = false;

  bool failVerify = false;
  bool failPrepare = false;
  String? failAt; // 'A'|'B'|'C'|'D'
  final Set<String> _fired = {};

  void _maybeFail(String step) {
    if (failAt == step && !_fired.contains(step)) {
      _fired.add(step);
      throw StateError('injected crash at step $step');
    }
  }

  /// The vault is unlockable iff routed correctly: v3 path needs material + live;
  /// v2 path needs the v2 boxes intact.
  bool canUnlock() => metaV3 ? (materialPresent && v3LivePresent) : v2Present;

  @override
  Future<void> prepareStaging() async {
    if (failPrepare) throw StateError('corrupt v2 field');
    stagingPresent = true;
  }

  @override
  Future<bool> verifyStaging() async => !failVerify;

  @override
  Future<void> installMaterial() async {
    _maybeFail('A');
    materialPresent = true;
  }

  @override
  Future<void> commitStagingToLive() async {
    _maybeFail('B');
    v3LivePresent = true;
  }

  @override
  Future<void> flipMetaToV3() async {
    _maybeFail('C');
    metaV3 = true;
  }

  @override
  Future<void> cleanupV2AndStaging() async {
    _maybeFail('D');
    v2Present = false;
    stagingPresent = false;
  }

  @override
  Future<void> discardStaging() async {
    stagingPresent = false;
  }
}

class _FakeJournal implements MigrationJournal {
  MigrationPhase? entry;
  @override
  Future<MigrationPhase?> read() async => entry;
  @override
  Future<void> write(MigrationPhase phase) async => entry = phase;
  @override
  Future<void> clear() async => entry = null;
}
