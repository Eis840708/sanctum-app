// Transactional backup-restore and device-transfer engine (findings V-01, V-02).
// DEV-P0-03 B2-3. Design freeze: migration-plan.md §3, backup-schema-v3.md §3/§5,
// proposals/restore-transaction-boundary.md (Option 1 — staged database + atomic
// commit + journalled resume).
//
// This module is PURE: it imports no Hive, Flutter, secure-storage or crypto code.
// It defines
//   * structural validators that fully vet a candidate BEFORE any live mutation;
//   * a staging -> atomic-commit -> rollback -> resume transaction expressed over
//     the abstract [RestoreTarget] / [RestoreJournalStore] ports.
// The real Hive/secure-storage ports live in `vault_v3_restore_hive.dart`; tests
// drive the engine with in-memory fakes and fault injection (no real vault).
//
// Core V-01/V-02 invariant: a malformed candidate can NEVER erase or partially
// overwrite the existing vault, because the live namespace is untouched until the
// candidate has passed every check and been fully staged and verified. Password
// confirmation (does the master password derive a key that authenticates the
// backup?) is performed by the caller before [TransactionalRestore.commit], so it
// too precedes any destructive step.

import '../../models/models.dart';

/// Resource bounds enforced during the read-only preflight (V-01/V-02 resource
/// bounds; proposal "Migration And Rollout"). Values are conservative guards, not
/// product limits — the product maximum is an open question in the proposal.
class RestoreLimits {
  const RestoreLimits({
    this.maxRecordsPerType = 100000,
    this.maxImages = 100000,
    this.maxFieldChars = 5 * 1024 * 1024, // ~5 MiB per encrypted string field
    this.maxImageChars = 64 * 1024 * 1024, // ~64 MiB per base64 image blob
    this.maxTotalRecords = 300000,
  });

  final int maxRecordsPerType;
  final int maxImages;
  final int maxFieldChars;
  final int maxImageChars;
  final int maxTotalRecords;

  static const RestoreLimits defaults = RestoreLimits();
}

/// Machine-readable reason a candidate was rejected before any mutation.
enum RestoreRejectCode {
  unknownVersion,
  malformedStructure,
  duplicateId,
  indexMismatch,
  orphanImage,
  tooManyRecords,
  fieldTooLarge,
  missingCredentials,
  passwordMismatch,
}

/// Thrown when a candidate fails a pre-commit check. When this is thrown the live
/// vault has NOT been touched.
class RestoreValidationException implements Exception {
  const RestoreValidationException(this.code, this.message);

  final RestoreRejectCode code;
  final String message;

  @override
  String toString() => 'RestoreValidationException(${code.name}): $message';
}

/// Non-Hive side effects that must be applied atomically with the box swap
/// (secure storage + session). Persisted in the journal so a crash mid-commit can
/// re-apply them idempotently on resume.
class RestoreSideEffects {
  const RestoreSideEffects({
    this.salt,
    this.installEncV2Done = false,
    this.deleteBiometricKey = false,
    this.clearSession = false,
    this.needsReunlock = false,
  });

  /// Salt to persist to secure storage on commit (null = leave untouched).
  final String? salt;

  /// Whether to write the legacy "already v2" migration flag on commit.
  final bool installEncV2Done;

  /// Whether to destroy the biometric wrapper on commit (device transfer).
  final bool deleteBiometricKey;

  /// Whether the caller must drop the in-memory session key after commit.
  final bool clearSession;

  /// Return value surfaced to the UI: the user must re-unlock afterwards.
  final bool needsReunlock;

  Map<String, dynamic> toJson() => {
        'salt': salt,
        'encV2': installEncV2Done,
        'delBio': deleteBiometricKey,
        'clrSes': clearSession,
        'reunlock': needsReunlock,
      };

  static RestoreSideEffects fromJson(Map<String, dynamic> json) =>
      RestoreSideEffects(
        salt: json['salt'] as String?,
        installEncV2Done: json['encV2'] as bool? ?? false,
        deleteBiometricKey: json['delBio'] as bool? ?? false,
        clearSession: json['clrSes'] as bool? ?? false,
        needsReunlock: json['reunlock'] as bool? ?? false,
      );
}

/// A fully-parsed, fully-validated restore candidate. Building one never mutates
/// the live vault; it is materialised entirely in memory (and then a durable
/// staging copy) before any destructive step.
class StagedVault {
  StagedVault({
    required this.passwords,
    required this.diary,
    required this.finance,
    required this.images,
    required this.imageIndex,
    required this.meta,
    required this.sideEffects,
  });

  final List<PasswordEntry> passwords;
  final List<DiaryEntry> diary;
  final List<FinanceRecord> finance;
  final Map<String, String> images;
  final Map<String, List<String>> imageIndex;

  /// New meta to install, or null to leave the live meta untouched (same-device
  /// backup restore keeps the current session and credentials).
  final VaultMeta? meta;

  final RestoreSideEffects sideEffects;

  int get totalRecords => passwords.length + diary.length + finance.length;
}

/// Durable journal phases. Only phases at/after [commitIntent] permit a resume to
/// finish the box swap; earlier phases can only be rolled back (stage discarded,
/// live untouched).
enum RestorePhase { staged, verified, commitIntent, committed }

/// A single durable journal entry.
class RestoreJournalEntry {
  const RestoreJournalEntry(this.phase, this.sideEffects);

  final RestorePhase phase;
  final RestoreSideEffects sideEffects;

  Map<String, dynamic> toJson() => {
        'phase': phase.name,
        'side': sideEffects.toJson(),
      };

  static RestoreJournalEntry fromJson(Map<String, dynamic> json) =>
      RestoreJournalEntry(
        RestorePhase.values.firstWhere((p) => p.name == json['phase']),
        RestoreSideEffects.fromJson(
            (json['side'] as Map).cast<String, dynamic>()),
      );
}

/// Port over the staging + live namespaces. Implementations MUST make
/// [commitStagingToLive] and [applyCommitSideEffects] idempotent so a resume can
/// re-run them safely.
abstract class RestoreTarget {
  /// Write the validated candidate into the staging namespace only. MUST NOT
  /// touch the live namespace.
  Future<void> writeStaging(StagedVault data);

  /// Read the staging namespace back and confirm it holds the expected content.
  Future<bool> verifyStaging(StagedVault data);

  /// Idempotently replace the live namespace with the staging namespace. Safe to
  /// call more than once (crash resume).
  Future<void> commitStagingToLive();

  /// Idempotently apply the non-Hive side effects (secure storage, biometric).
  /// Called only after [commitStagingToLive].
  Future<void> applyCommitSideEffects(RestoreSideEffects effects);

  /// Remove the staging namespace (post-commit cleanup or rollback discard).
  Future<void> discardStaging();
}

/// Port over the durable journal (single latest entry).
abstract class RestoreJournalStore {
  Future<RestoreJournalEntry?> read();
  Future<void> write(RestoreJournalEntry entry);
  Future<void> clear();
}

/// Orchestrates the staged, journalled, atomic, resumable restore transaction.
class TransactionalRestore {
  TransactionalRestore(this._target, this._journal);

  final RestoreTarget _target;
  final RestoreJournalStore _journal;

  /// Commits an already-validated candidate.
  ///
  /// Precondition: [data] passed every structural check and (when it carries
  /// credentials) password confirmation — NO live mutation has happened yet.
  ///
  /// Order: recover any prior interrupted transaction, then
  /// stage -> verify -> journal commit-intent -> swap -> side effects -> cleanup.
  /// A failure anywhere before commit-intent leaves the live vault untouched.
  Future<void> commit(StagedVault data) async {
    // Finish or roll back any interrupted prior transaction first.
    await recover();

    // Fresh staging namespace, then stage the candidate (live untouched).
    await _target.discardStaging();
    await _target.writeStaging(data);
    await _journal.write(RestoreJournalEntry(RestorePhase.staged, data.sideEffects));

    // Verify the durable stage read-back before any destructive step.
    final ok = await _target.verifyStaging(data);
    if (!ok) {
      await _target.discardStaging();
      await _journal.clear();
      throw const RestoreValidationException(
          RestoreRejectCode.malformedStructure, 'staging verification failed');
    }
    await _journal.write(
        RestoreJournalEntry(RestorePhase.verified, data.sideEffects));

    // Point of no return: the stage is complete and verified. From here a crash
    // resumes FORWARD (finish the swap) — the live vault is never cleared as a
    // recovery step.
    await _journal.write(
        RestoreJournalEntry(RestorePhase.commitIntent, data.sideEffects));
    await _target.commitStagingToLive();
    await _target.applyCommitSideEffects(data.sideEffects);
    await _journal.write(
        RestoreJournalEntry(RestorePhase.committed, data.sideEffects));

    // Cleanup.
    await _target.discardStaging();
    await _journal.clear();
  }

  /// Resumes or rolls back an interrupted transaction based on the journal. Safe
  /// to call at any time (idempotent). Never clears the live vault as a recovery
  /// step — only completes forward from a durable, verified stage.
  Future<void> recover() async {
    final entry = await _journal.read();
    if (entry == null) return;
    switch (entry.phase) {
      case RestorePhase.staged:
      case RestorePhase.verified:
        // Never reached commit intent -> live vault untouched -> discard stage.
        await _target.discardStaging();
        await _journal.clear();
        break;
      case RestorePhase.commitIntent:
      case RestorePhase.committed:
        // Stage is complete and verified -> finish the swap idempotently.
        await _target.commitStagingToLive();
        await _target.applyCommitSideEffects(entry.sideEffects);
        await _target.discardStaging();
        await _journal.clear();
        break;
    }
  }
}

// ── Validators ───────────────────────────────────────────────────────────────
//
// Structural preflight for a v2-format JSON backup produced by exportVaultJson.
// Every anomaly throws [RestoreValidationException] BEFORE a StagedVault exists,
// so the caller cannot reach the transaction with a bad candidate.

/// Parses and validates a decoded backup map. Never touches the live vault.
StagedVault parseAndValidateBackup(
  Map<String, dynamic> json, {
  RestoreLimits limits = RestoreLimits.defaults,
}) {
  _rejectUnknownContainer(json);

  final passwords = _parsePasswords(json['passwords'], limits);
  final diary = _parseDiary(json['diary'], limits);
  final finance = _parseFinance(json['finance'], limits);
  final images = _parseImages(json['images'], limits);
  final imageIndex = _parseImageIndex(json['imageIndex'], limits);
  _checkImageConsistency(images, imageIndex);
  _checkTotal(passwords.length, diary.length, finance.length, limits);

  final salt = (json['salt'] as String?) ?? '';
  if (salt.isNotEmpty) {
    final vh = (json['verifyHash'] as String?) ?? '';
    return StagedVault(
      passwords: passwords,
      diary: diary,
      finance: finance,
      images: images,
      imageIndex: imageIndex,
      meta: _newMeta(salt, vh),
      sideEffects: RestoreSideEffects(
        salt: salt,
        installEncV2Done: true,
        clearSession: true,
        needsReunlock: true,
      ),
    );
  }
  // No credentials: same-device restore keeps the current session and meta.
  return StagedVault(
    passwords: passwords,
    diary: diary,
    finance: finance,
    images: images,
    imageIndex: imageIndex,
    meta: null,
    sideEffects: const RestoreSideEffects(),
  );
}

/// Parses and validates a decoded device-transfer payload. Never touches the live
/// vault. Transfer always replaces the vault, so credentials are mandatory.
StagedVault parseAndValidateTransfer(
  Map<String, dynamic> d, {
  RestoreLimits limits = RestoreLimits.defaults,
}) {
  final salt = d['sl'];
  final vh = d['vh'];
  if (salt is! String || salt.isEmpty || vh is! String || vh.isEmpty) {
    throw const RestoreValidationException(
        RestoreRejectCode.missingCredentials,
        'transfer payload missing salt/verifyHash');
  }

  final passwords = _parseTransferPasswords(d['pw'], limits);
  final diary = _parseTransferDiary(d['di'], limits);
  final finance = _parseTransferFinance(d['fi'], limits);
  final images = _parseImages(d['im'], limits);
  final imageIndex = _parseImageIndex(d['ii'], limits);
  _checkImageConsistency(images, imageIndex);
  _checkTotal(passwords.length, diary.length, finance.length, limits);

  return StagedVault(
    passwords: passwords,
    diary: diary,
    finance: finance,
    images: images,
    imageIndex: imageIndex,
    meta: _newMeta(salt, vh),
    sideEffects: RestoreSideEffects(
      salt: salt,
      installEncV2Done: true,
      deleteBiometricKey: true,
      clearSession: true,
      needsReunlock: true,
    ),
  );
}

VaultMeta _newMeta(String salt, String verifyHash) {
  final now = DateTime.now();
  return VaultMeta(
    salt: salt,
    verifyHash: verifyHash,
    createdAt: now,
    lastUnlocked: now,
    version: 'v2',
  );
}

void _rejectUnknownContainer(Map<String, dynamic> json) {
  // A future/foreign container marker (e.g. a binary v3 backup mis-fed as JSON).
  if (json.containsKey('magic')) {
    throw const RestoreValidationException(
        RestoreRejectCode.unknownVersion, 'unknown backup container magic');
  }
  final v = json['version'];
  if (v == null) return; // legacy backups carried no top-level version field
  if (v is int) {
    throw RestoreValidationException(
        RestoreRejectCode.unknownVersion, 'unknown backup version $v');
  }
  if (v is String) {
    final major = int.tryParse(v.split('.').first);
    if (major == null || major > 2) {
      throw RestoreValidationException(
          RestoreRejectCode.unknownVersion, 'unsupported backup version "$v"');
    }
    return;
  }
  throw const RestoreValidationException(
      RestoreRejectCode.unknownVersion, 'malformed backup version');
}

// ── Backup record parsers (long keys) ────────────────────────────────────────

List<PasswordEntry> _parsePasswords(dynamic raw, RestoreLimits limits) {
  final list = _asList(raw, 'passwords');
  _checkCount(list.length, limits.maxRecordsPerType, 'passwords');
  final ids = <String>{};
  final out = <PasswordEntry>[];
  for (final item in list) {
    final m = _asMap(item, 'password record');
    final id = _requireId(m, 'password');
    if (!ids.add(id)) {
      throw RestoreValidationException(
          RestoreRejectCode.duplicateId, 'duplicate password id "$id"');
    }
    final site = _str(m['site']);
    final username = _str(m['username']);
    final encPw = _str(m['encryptedPassword']);
    final notes = _str(m['notes']);
    _checkFieldSizes(limits, [site, username, encPw, notes]);
    out.add(PasswordEntry(
      id: id,
      site: site,
      username: username,
      encryptedPassword: encPw,
      notes: notes,
      createdAt: _dateOr(m['createdAt']),
      updatedAt: _dateOr(m['updatedAt'], fallback: m['createdAt']),
      iconEmoji: m['iconEmoji'] as String?,
    ));
  }
  return out;
}

List<DiaryEntry> _parseDiary(dynamic raw, RestoreLimits limits) {
  final list = _asList(raw, 'diary');
  _checkCount(list.length, limits.maxRecordsPerType, 'diary');
  final ids = <String>{};
  final out = <DiaryEntry>[];
  for (final item in list) {
    final m = _asMap(item, 'diary record');
    final id = _requireId(m, 'diary');
    if (!ids.add(id)) {
      throw RestoreValidationException(
          RestoreRejectCode.duplicateId, 'duplicate diary id "$id"');
    }
    final title = _str(m['title']);
    final content = _str(m['encryptedContent']);
    final mood = _str(m['mood']);
    _checkFieldSizes(limits, [title, content, mood]);
    out.add(DiaryEntry(
      id: id,
      title: title,
      encryptedContent: content,
      mood: mood,
      tags: _stringList(m['tags']),
      createdAt: _dateOr(m['createdAt']),
      updatedAt: _dateOr(m['updatedAt'], fallback: m['createdAt']),
    ));
  }
  return out;
}

List<FinanceRecord> _parseFinance(dynamic raw, RestoreLimits limits) {
  final list = _asList(raw, 'finance');
  _checkCount(list.length, limits.maxRecordsPerType, 'finance');
  final ids = <String>{};
  final out = <FinanceRecord>[];
  for (final item in list) {
    final m = _asMap(item, 'finance record');
    final id = _requireId(m, 'finance');
    if (!ids.add(id)) {
      throw RestoreValidationException(
          RestoreRejectCode.duplicateId, 'duplicate finance id "$id"');
    }
    final type = _str(m['type']);
    final category = _str(m['category']);
    final description = _str(m['description']);
    _checkFieldSizes(limits, [type, category, description]);
    out.add(FinanceRecord(
      id: id,
      type: type,
      amount: _amount(m['amount']),
      category: category,
      description: description,
      date: _dateOr(m['date']),
      createdAt: _dateOr(m['createdAt']),
      currency: (m['currency'] as String?) ?? 'MOP',
      lineItemsJson: m['lineItemsJson'] as String?,
    ));
  }
  return out;
}

// ── Transfer record parsers (short keys) ─────────────────────────────────────

List<PasswordEntry> _parseTransferPasswords(dynamic raw, RestoreLimits limits) {
  final list = _asList(raw, 'transfer passwords');
  _checkCount(list.length, limits.maxRecordsPerType, 'transfer passwords');
  final ids = <String>{};
  final out = <PasswordEntry>[];
  for (final item in list) {
    final m = _asMap(item, 'transfer password');
    final id = _requireId(m, 'transfer password');
    if (!ids.add(id)) {
      throw RestoreValidationException(
          RestoreRejectCode.duplicateId, 'duplicate password id "$id"');
    }
    final site = _str(m['si']);
    final username = _str(m['un']);
    final encPw = _str(m['ep']);
    final notes = _str(m['no']);
    _checkFieldSizes(limits, [site, username, encPw, notes]);
    out.add(PasswordEntry(
      id: id,
      site: site,
      username: username,
      encryptedPassword: encPw,
      notes: notes,
      createdAt: _dateOr(m['ca']),
      updatedAt: _dateOr(m['ua'], fallback: m['ca']),
      iconEmoji: m['ie'] as String?,
    ));
  }
  return out;
}

List<DiaryEntry> _parseTransferDiary(dynamic raw, RestoreLimits limits) {
  final list = _asList(raw, 'transfer diary');
  _checkCount(list.length, limits.maxRecordsPerType, 'transfer diary');
  final ids = <String>{};
  final out = <DiaryEntry>[];
  for (final item in list) {
    final m = _asMap(item, 'transfer diary');
    final id = _requireId(m, 'transfer diary');
    if (!ids.add(id)) {
      throw RestoreValidationException(
          RestoreRejectCode.duplicateId, 'duplicate diary id "$id"');
    }
    final title = _str(m['ti']);
    final content = _str(m['ec']);
    final mood = _str(m['mo']);
    _checkFieldSizes(limits, [title, content, mood]);
    out.add(DiaryEntry(
      id: id,
      title: title,
      encryptedContent: content,
      mood: mood,
      tags: _stringList(m['tg']),
      createdAt: _dateOr(m['ca']),
      updatedAt: _dateOr(m['ua'], fallback: m['ca']),
    ));
  }
  return out;
}

List<FinanceRecord> _parseTransferFinance(dynamic raw, RestoreLimits limits) {
  final list = _asList(raw, 'transfer finance');
  _checkCount(list.length, limits.maxRecordsPerType, 'transfer finance');
  final ids = <String>{};
  final out = <FinanceRecord>[];
  for (final item in list) {
    final m = _asMap(item, 'transfer finance');
    final id = _requireId(m, 'transfer finance');
    if (!ids.add(id)) {
      throw RestoreValidationException(
          RestoreRejectCode.duplicateId, 'duplicate finance id "$id"');
    }
    final type = _str(m['ty']);
    final category = _str(m['ct']);
    final description = _str(m['de']);
    _checkFieldSizes(limits, [type, category, description]);
    out.add(FinanceRecord(
      id: id,
      type: type,
      amount: _amount(m['am']),
      category: category,
      description: description,
      date: _dateOr(m['dt']),
      createdAt: _dateOr(m['ca']),
      currency: (m['cu'] as String?) ?? 'USD',
      lineItemsJson: m['li'] as String?,
    ));
  }
  return out;
}

// ── Shared image parsers + consistency ───────────────────────────────────────

Map<String, String> _parseImages(dynamic raw, RestoreLimits limits) {
  if (raw == null) return {};
  final m = _asMap(raw, 'images');
  _checkCount(m.length, limits.maxImages, 'images');
  final out = <String, String>{};
  for (final e in m.entries) {
    final v = e.value;
    if (v is! String) {
      throw RestoreValidationException(RestoreRejectCode.malformedStructure,
          'image "${e.key}" is not a string');
    }
    if (v.length > limits.maxImageChars) {
      throw RestoreValidationException(
          RestoreRejectCode.fieldTooLarge, 'image "${e.key}" too large');
    }
    out[e.key.toString()] = v;
  }
  return out;
}

Map<String, List<String>> _parseImageIndex(dynamic raw, RestoreLimits limits) {
  if (raw == null) return {};
  final m = _asMap(raw, 'imageIndex');
  final out = <String, List<String>>{};
  for (final e in m.entries) {
    out[e.key.toString()] = _stringList(e.value, what: 'imageIndex "${e.key}"');
  }
  return out;
}

void _checkImageConsistency(
    Map<String, String> images, Map<String, List<String>> imageIndex) {
  final referenced = <String>{};
  for (final ids in imageIndex.values) {
    for (final id in ids) {
      if (!images.containsKey(id)) {
        throw RestoreValidationException(RestoreRejectCode.indexMismatch,
            'imageIndex references missing image "$id"');
      }
      referenced.add(id);
    }
  }
  // Orphan policy (documented, strict): every stored image must be referenced by
  // some index entry. An unreferenced blob signals a corrupt/foreign backup, so
  // the whole restore is rejected before any mutation — the existing vault is
  // never partially replaced with inconsistent data.
  for (final id in images.keys) {
    if (!referenced.contains(id)) {
      throw RestoreValidationException(RestoreRejectCode.orphanImage,
          'image "$id" is not referenced by any index entry');
    }
  }
}

// ── Low-level field helpers ──────────────────────────────────────────────────

List _asList(dynamic v, String what) {
  if (v == null) return const [];
  if (v is List) return v;
  throw RestoreValidationException(
      RestoreRejectCode.malformedStructure, '$what must be a list');
}

Map<String, dynamic> _asMap(dynamic v, String what) {
  if (v is Map) return v.cast<String, dynamic>();
  throw RestoreValidationException(
      RestoreRejectCode.malformedStructure, '$what must be an object');
}

String _requireId(Map<String, dynamic> m, String what) {
  final id = m['id'];
  if (id is! String || id.isEmpty) {
    throw RestoreValidationException(
        RestoreRejectCode.malformedStructure, '$what record missing id');
  }
  return id;
}

String _str(dynamic v) {
  if (v == null) return '';
  if (v is String) return v;
  throw const RestoreValidationException(
      RestoreRejectCode.malformedStructure, 'expected a string field');
}

List<String> _stringList(dynamic v, {String what = 'list'}) {
  if (v == null) return <String>[];
  if (v is! List) {
    throw RestoreValidationException(
        RestoreRejectCode.malformedStructure, '$what must be a list');
  }
  return v.map((x) {
    if (x is! String) {
      throw RestoreValidationException(
          RestoreRejectCode.malformedStructure, '$what has a non-string entry');
    }
    return x;
  }).toList();
}

double _amount(dynamic v) {
  if (v is num) return v.toDouble();
  throw const RestoreValidationException(
      RestoreRejectCode.malformedStructure, 'amount must be a number');
}

DateTime _dateOr(dynamic v, {dynamic fallback}) {
  final source = v ?? fallback;
  if (source == null) return DateTime.now();
  if (source is int) return DateTime.fromMillisecondsSinceEpoch(source);
  if (source is String) {
    final parsed = DateTime.tryParse(source);
    if (parsed == null) {
      throw RestoreValidationException(
          RestoreRejectCode.malformedStructure, 'bad date "$source"');
    }
    return parsed;
  }
  throw const RestoreValidationException(
      RestoreRejectCode.malformedStructure, 'unsupported date type');
}

void _checkCount(int count, int max, String what) {
  if (count > max) {
    throw RestoreValidationException(
        RestoreRejectCode.tooManyRecords, '$what count $count exceeds $max');
  }
}

void _checkTotal(int a, int b, int c, RestoreLimits limits) {
  final total = a + b + c;
  if (total > limits.maxTotalRecords) {
    throw RestoreValidationException(RestoreRejectCode.tooManyRecords,
        'total records $total exceeds ${limits.maxTotalRecords}');
  }
}

void _checkFieldSizes(RestoreLimits limits, List<String> fields) {
  for (final f in fields) {
    if (f.length > limits.maxFieldChars) {
      throw RestoreValidationException(
          RestoreRejectCode.fieldTooLarge, 'field of ${f.length} chars too large');
    }
  }
}
