// Transactional v2 -> v3 vault migration (DEV-P0-03 B2-5b, option C).
// Design freeze: migration-plan §3-5, storage supplement v1.3-delta §9,
// B2-5b ruling (three-way atomic bundle + idempotent resume; commitIntent =
// point of no return).
//
// The migration re-encrypts every v2 record field into a v3 per-field envelope
// (in staging), then atomically bundles THREE changes:
//   A. install v3 material (wrapped DEK)          -> v3 material box
//   B. copy v3 staging -> v3 live boxes
//   C. flip meta.version -> 'v3'                  (THE FLIP: routes to v3)
//   D. clear v2 typed boxes + staging             (cleanup)
//
// Interrupt invariant (RETURN-level; QA injects a crash between each step):
//   * before commitIntent            -> nothing live-mutated, staging discarded,
//                                        v2 vault untouched and unlockable;
//   * at/after commitIntent           -> forward resume replays A..D idempotently;
//   * the FLIP (C) happens only AFTER A+B are durable, and v2 is cleared (D) only
//     AFTER the flip — so at every point the vault unlocks via EITHER the intact
//     v2 path (meta still v2) OR the ready v3 path (meta v3, material+live in
//     place). There is never a half-v2/half-v3 unroutable state.
//
// This module is pure: it orchestrates ordering + journalling over abstract
// ports. The real Hive/secure-storage adapter lives in the store/service layer;
// tests drive fault injection through in-memory fakes.

/// Durable journal phase. Only [commitIntent] permits a forward resume; earlier
/// phases roll back (staging discarded, v2 intact).
enum MigrationPhase { staged, verified, commitIntent }

/// Ports over the v2 (source) + v3 (staging/live) namespaces.
///
/// [installMaterial], [commitStagingToLive], [flipMetaToV3] and
/// [cleanupV2AndStaging] MUST be idempotent so a resume can replay them safely.
abstract class MigrationTarget {
  /// Read v2 records, re-encrypt each field into a v3 envelope, write to staging.
  /// MUST NOT mutate the v2 live namespace. May throw (e.g. a corrupt v2 field);
  /// a throw here leaves the v2 vault untouched.
  Future<void> prepareStaging();

  /// Read the staged v3 records back and confirm completeness before commit.
  Future<bool> verifyStaging();

  /// A: install the v3 key material (wrapped DEK). Idempotent.
  Future<void> installMaterial();

  /// B: replace v3 live boxes with staging. Idempotent.
  Future<void> commitStagingToLive();

  /// C: flip meta.version to 'v3' — routes unlock to the v3 path. Idempotent.
  Future<void> flipMetaToV3();

  /// D: clear the v2 typed boxes + staging. Idempotent.
  Future<void> cleanupV2AndStaging();

  /// Discard staging (rollback before the flip). Leaves v2 untouched.
  Future<void> discardStaging();
}

/// Durable single-entry journal.
abstract class MigrationJournal {
  Future<MigrationPhase?> read();
  Future<void> write(MigrationPhase phase);
  Future<void> clear();
}

/// Raised when staging verification fails (pre-commit; v2 untouched).
class MigrationException implements Exception {
  const MigrationException(this.message);
  final String message;
  @override
  String toString() => 'MigrationException: $message';
}

/// Orchestrates the staged, journalled, atomic, resumable migration.
class TransactionalMigration {
  TransactionalMigration(this._target, this._journal);

  final MigrationTarget _target;
  final MigrationJournal _journal;

  /// Runs a full migration. Recovers any prior interrupted run first.
  Future<void> migrate() async {
    await recover();

    await _target.discardStaging();
    await _target.prepareStaging(); // v2 read + re-encrypt -> staging (v2 untouched)
    await _journal.write(MigrationPhase.staged);

    if (!await _target.verifyStaging()) {
      await _target.discardStaging();
      await _journal.clear();
      throw const MigrationException('staging verification failed');
    }
    await _journal.write(MigrationPhase.verified);

    // Point of no return: staging is complete + verified and material is durable.
    await _journal.write(MigrationPhase.commitIntent);
    await _commitForward();
    await _journal.clear();
  }

  /// Resumes or rolls back an interrupted migration. Idempotent; safe at unlock.
  Future<void> recover() async {
    final phase = await _journal.read();
    if (phase == null) return;
    switch (phase) {
      case MigrationPhase.staged:
      case MigrationPhase.verified:
        // Never reached the flip -> v2 is intact -> discard staging (rollback).
        await _target.discardStaging();
        await _journal.clear();
        break;
      case MigrationPhase.commitIntent:
        // Committed to going forward -> replay A..D idempotently.
        await _commitForward();
        await _journal.clear();
        break;
    }
  }

  /// The ordered three-way bundle (+ cleanup). Ordering is load-bearing for the
  /// interrupt invariant: flip (C) only after material (A) + live (B); clear v2
  /// (D) only after the flip.
  Future<void> _commitForward() async {
    await _target.installMaterial(); // A
    await _target.commitStagingToLive(); // B
    await _target.flipMetaToV3(); // C — the flip
    await _target.cleanupV2AndStaging(); // D
  }
}
