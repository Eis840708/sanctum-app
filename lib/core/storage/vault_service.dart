import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import '../crypto/crypto_service.dart';
import '../crypto/v3/vault_v3_restore.dart';
import '../crypto/v3/vault_v3_restore_hive.dart';
import '../models/models.dart';

class VaultService {
  static const String _metaBoxName      = 'sanctum_meta';
  static const String _passwordsBoxName = 'sanctum_passwords';
  static const String _diaryBoxName     = 'sanctum_diary';
  static const String _financeBoxName   = 'sanctum_finance';
  static const String _saltKey          = 'vault_salt';
  static const String _biometricKey = 'vault_biometric_key';
  static const String _encV2Key    = 'vault_enc_v2';

  final _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  final _uuid = const Uuid();

  SecretKey? _sessionKey;
  bool get isUnlocked => _sessionKey != null;

  late Box<PasswordEntry> _passwords;
  late Box<DiaryEntry>    _diary;
  late Box<FinanceRecord> _finance;
  late Box<String> _images;
  late Box         _imageIndex;
  late Box<VaultMeta>     _meta;

  Future<void> init() async {
    await Hive.initFlutter();
    Hive.registerAdapter(PasswordEntryAdapter());
    Hive.registerAdapter(DiaryEntryAdapter());
    Hive.registerAdapter(FinanceRecordAdapter());
    Hive.registerAdapter(VaultMetaAdapter());
    _meta      = await Hive.openBox<VaultMeta>(_metaBoxName);
    _passwords = await Hive.openBox<PasswordEntry>(_passwordsBoxName);
    _diary     = await Hive.openBox<DiaryEntry>(_diaryBoxName);
    _finance   = await Hive.openBox<FinanceRecord>(_financeBoxName);
    _images     = await Hive.openBox<String>('sanctum_images');
    _imageIndex = await Hive.openBox('sanctum_image_index');
  }

  bool get hasVault => _meta.isNotEmpty;

  Future<void> createVault(String masterPassword) async {
    // Clear any leftover data from a previous vault to prevent double-encryption
    await _passwords.clear();
    await _diary.clear();
    await _finance.clear();
    await _images.clear();
    await _imageIndex.clear();

    final salt = cryptoService.generateSalt();
    final saltB64 = base64.encode(salt);
    await _secureStorage.write(key: _saltKey, value: saltB64);
    final key = await cryptoService.deriveKey(masterPassword, salt);
    final verifyHash = await cryptoService.makeVerifyHash(key);
    final meta = VaultMeta(
      salt: saltB64, verifyHash: verifyHash,
      createdAt: DateTime.now(), lastUnlocked: DateTime.now(),
      version: 'v2', // Mark migration as already done for new vaults
    );
    await _meta.put('meta', meta);
    _sessionKey = key;
    // V-05: biometric is opt-in only — never auto-enabled on vault creation.
  }

  Future<bool> unlock(String masterPassword) async {
    // V-01 interrupt safety (B2-3 seam 2): complete or roll back any
    // restore/transfer that was interrupted mid-commit (e.g. power loss) before
    // reading vault state, so a swap that had reached commit-intent finishes and
    // meta reflects the recovered vault. Minimal hook only; idempotent no-op when
    // nothing is pending.
    await recoverPendingRestore();
    final meta = _meta.get('meta');
    if (meta == null) return false;
    // Fallback to meta.salt if secure storage was wiped (e.g. device reset)
    String? saltStr = await _secureStorage.read(key: _saltKey);
    saltStr ??= meta.salt;
    if (saltStr.isEmpty) return false;
    // Restore to secure storage if missing
    if (await _secureStorage.read(key: _saltKey) == null) {
      await _secureStorage.write(key: _saltKey, value: saltStr);
    }
    final salt = Uint8List.fromList(base64.decode(saltStr));
    final key  = await cryptoService.deriveKey(masterPassword, salt);
    final ok   = await cryptoService.verifyKey(key, meta.verifyHash);
    if (ok) {
      _sessionKey = key;
      meta.lastUnlocked = DateTime.now();
      meta.unlockCount++;
      await meta.save();
      // V-05: opt-in only — never auto-enable. Refresh the stored wrapper only
      // when the user has already opted into biometric unlock.
      try { if (await hasBiometricEnabled()) await enableBiometric(); } catch (_) {}
      await _migrateV2();
    }
    return ok;
  }

  void lock() => _sessionKey = null;

  // ── Raw access for device transfer (fields stay AES-encrypted with master key) ──
  List<PasswordEntry> get rawPasswords => _passwords.values.toList();
  List<DiaryEntry>    get rawDiary     => _diary.values.toList();
  List<FinanceRecord> get rawFinance   => _finance.values.toList();
  Map<String, String> get rawImages => _images.toMap().map(
      (key, value) => MapEntry(key.toString(), value));
  Map<String, List<String>> get rawImageIndex => _imageIndex.toMap().map(
      (key, value) => MapEntry(key.toString(), List<String>.from(value as List)));
  VaultMeta?          get rawMeta      => _meta.get('meta');

  /// Imports a device-transfer payload transactionally (finding V-02).
  ///
  /// The former clear-all + `deleteAll` (which destroyed the existing vault,
  /// metadata, secure storage and session BEFORE parsing) is gone: the payload is
  /// fully parsed and structurally validated first, then staged, then atomically
  /// committed. A malformed payload is rejected before any destructive step, so
  /// the existing vault, biometric wrapper and metadata all survive intact. The
  /// biometric-wrapper + meta destruction now happens only inside the atomic
  /// commit (see [RestoreSideEffects.deleteBiometricKey]).
  Future<void> importTransfer(Map<String, dynamic> d) async {
    final staged = parseAndValidateTransfer(d);
    final tx = await _openRestoreTx();
    await tx.commit(staged);
    if (staged.sideEffects.clearSession) _sessionKey = null;
  }

  Future<void> clearVault() async {
    await _passwords.clear();
    await _diary.clear();
    await _finance.clear();
    await _images.clear();
    await _imageIndex.clear();
    await _meta.clear();
    await _secureStorage.deleteAll();
    _sessionKey = null;
  }

  Future<String> _safeDecrypt(String value) async {
    if (value.isEmpty) return value;
    try { return await cryptoService.decrypt(value, _sessionKey!); }
    catch (_) { return value; }
  }

  Future<void> _migrateV2() async {
    final meta = _meta.get('meta');
    // Use meta.version in Hive as migration flag (survives app reinstalls)
    if (meta != null && meta.version == 'v2') return;
    // Also check legacy secure storage flag
    final legacyDone = await _secureStorage.read(key: _encV2Key);
    if (legacyDone == 'done') {
      // Upgrade legacy flag to Hive
      meta?.version = 'v2';
      await meta?.save();
      return;
    }
    for (final e in _passwords.values.toList()) {
      bool c = false;
      try { await cryptoService.decrypt(e.site, _sessionKey!); }
      catch (_) { e.site = await cryptoService.encrypt(e.site, _sessionKey!); c = true; }
      try { await cryptoService.decrypt(e.username, _sessionKey!); }
      catch (_) { e.username = await cryptoService.encrypt(e.username, _sessionKey!); c = true; }
      final n = e.notes;
      if (n.isNotEmpty) {
        try { await cryptoService.decrypt(n, _sessionKey!); }
        catch (_) { e.notes = await cryptoService.encrypt(n, _sessionKey!); c = true; }
      }
      if (c) await e.save();
    }
    for (final e in _diary.values.toList()) {
      bool c = false;
      try { await cryptoService.decrypt(e.title, _sessionKey!); }
      catch (_) { e.title = await cryptoService.encrypt(e.title, _sessionKey!); c = true; }
      try { await cryptoService.decrypt(e.mood, _sessionKey!); }
      catch (_) { e.mood = await cryptoService.encrypt(e.mood, _sessionKey!); c = true; }
      if (c) await e.save();
    }
    for (final e in _finance.values.toList()) {
      bool c = false;
      try { await cryptoService.decrypt(e.category, _sessionKey!); }
      catch (_) { e.category = await cryptoService.encrypt(e.category, _sessionKey!); c = true; }
      try { await cryptoService.decrypt(e.description, _sessionKey!); }
      catch (_) { e.description = await cryptoService.encrypt(e.description, _sessionKey!); c = true; }
      if (c) await e.save();
    }
    // Store flag in Hive (not secure storage) so it survives reinstalls
    if (meta != null) { meta.version = 'v2'; await meta.save(); }
    await _secureStorage.write(key: _encV2Key, value: 'done');
  }


  // ── Passwords ─────────────────────────────────────────
  Future<List<PasswordEntry>> getPasswords() async {
    _requireUnlocked();
    final raw = _passwords.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final result = <PasswordEntry>[];
    for (final e in raw) {
      result.add(PasswordEntry(
        id: e.id,
        site: await _safeDecrypt(e.site),
        username: await _safeDecrypt(e.username),
        encryptedPassword: e.encryptedPassword,
        notes: await _safeDecrypt(e.notes),
        createdAt: e.createdAt,
        updatedAt: e.updatedAt,
        iconEmoji: e.iconEmoji,
      ));
    }
    return result;
  }

  Future<void> addPassword({
    required String site, required String username,
    required String password, String notes = '', String? iconEmoji,
  }) async {
    _requireUnlocked();
    final encSite  = await cryptoService.encrypt(site, _sessionKey!);
    final encUser  = await cryptoService.encrypt(username, _sessionKey!);
    final encPass  = await cryptoService.encrypt(password, _sessionKey!);
    final encNotes = notes.isNotEmpty ? await cryptoService.encrypt(notes, _sessionKey!) : '';
    final entry = PasswordEntry(
      id: _uuid.v4(), site: encSite, username: encUser,
      encryptedPassword: encPass, notes: encNotes,
      createdAt: DateTime.now(), updatedAt: DateTime.now(), iconEmoji: iconEmoji,
    );
    await _passwords.put(entry.id, entry);
  }

  Future<String> decryptPassword(PasswordEntry entry) async {
    _requireUnlocked();
    return cryptoService.decrypt(entry.encryptedPassword, _sessionKey!);
  }

  Future<void> deletePassword(String id) async {
    _requireUnlocked();
    await _passwords.delete(id);
  }

  /// Returns the raw encrypted entry before it is deleted — for undo support.
  PasswordEntry? getRawPasswordEntry(String id) => _passwords.get(id);

  /// Re-inserts a previously deleted (raw/encrypted) entry directly into Hive.
  Future<void> restoreRawPasswordEntry(PasswordEntry entry) async {
    _requireUnlocked();
    await _passwords.put(entry.id, entry);
  }

  Future<void> updatePassword(PasswordEntry entry, {String? newPassword, String? site, String? username, String? notes}) async {
    _requireUnlocked();
    final stored = _passwords.get(entry.id);
    if (stored == null) return;
    if (newPassword != null) stored.encryptedPassword = await cryptoService.encrypt(newPassword, _sessionKey!);
    if (site != null)     stored.site     = await cryptoService.encrypt(site, _sessionKey!);
    if (username != null) stored.username = await cryptoService.encrypt(username, _sessionKey!);
    if (notes != null)    stored.notes    = notes.isNotEmpty ? await cryptoService.encrypt(notes, _sessionKey!) : '';
    stored.updatedAt = DateTime.now();
    await stored.save();
  }

  // ── Diary ──────────────────────────────────────────────
  Future<List<DiaryEntry>> getDiaryEntries() async {
    _requireUnlocked();
    final raw = _diary.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final result = <DiaryEntry>[];
    for (final e in raw) {
      result.add(DiaryEntry(
        id: e.id,
        title: await _safeDecrypt(e.title),
        encryptedContent: e.encryptedContent,
        mood: await _safeDecrypt(e.mood),
        createdAt: e.createdAt,
        updatedAt: e.updatedAt,
        tags: e.tags,
      ));
    }
    return result;
  }

  Future<String> addDiaryEntry({
    required String title, required String content,
    required String mood, List<String> tags = const [],
  }) async {
    _requireUnlocked();
    final encTitle   = await cryptoService.encrypt(title, _sessionKey!);
    final encContent = await cryptoService.encrypt(content, _sessionKey!);
    final encMood    = await cryptoService.encrypt(mood, _sessionKey!);
    final entry = DiaryEntry(
      id: _uuid.v4(), title: encTitle, encryptedContent: encContent,
      mood: encMood, createdAt: DateTime.now(), updatedAt: DateTime.now(), tags: tags,
    );
    await _diary.put(entry.id, entry);
    return entry.id;
  }

  Future<String> decryptDiaryContent(DiaryEntry entry) async {
    _requireUnlocked();
    return cryptoService.decrypt(entry.encryptedContent, _sessionKey!);
  }

  Future<void> deleteDiaryEntry(String id) async {
    _requireUnlocked();
    await _diary.delete(id);
  }

  Future<void> updateDiaryEntry(DiaryEntry entry, {String? title, String? content, String? mood}) async {
    _requireUnlocked();
    final stored = _diary.get(entry.id);
    if (stored == null) return;
    if (title != null)   stored.title            = await cryptoService.encrypt(title, _sessionKey!);
    if (mood != null)    stored.mood             = await cryptoService.encrypt(mood, _sessionKey!);
    if (content != null) stored.encryptedContent = await cryptoService.encrypt(content, _sessionKey!);
    stored.updatedAt = DateTime.now();
    await stored.save();
  }

  // ── Finance ────────────────────────────────────────────
  
  // Image Storage ──────────────────────────────────────────────────────────

  Future<String> addDiaryImage(Uint8List bytes) async {
    _requireUnlocked();
    final enc = await cryptoService.encrypt(base64.encode(bytes), _sessionKey!);
    final id  = _uuid.v4();
    await _images.put(id, enc);
    return id;
  }

  Future<Uint8List?> getDiaryImage(String imageId) async {
    _requireUnlocked();
    final enc = _images.get(imageId);
    if (enc == null) return null;
    return base64Decode(await cryptoService.decrypt(enc, _sessionKey!));
  }

  List<String> getDiaryImageIds(String entryId) {
    final raw = _imageIndex.get(entryId);
    return raw == null ? [] : List<String>.from(raw as List);
  }

  Future<void> setDiaryImageIds(String entryId, List<String> ids) async {
    if (ids.isEmpty) { await _imageIndex.delete(entryId); }
    else             { await _imageIndex.put(entryId, ids); }
  }

  Future<List<FinanceRecord>> getFinanceRecords() async {
    _requireUnlocked();
    final raw = _finance.values.toList()..sort((a, b) => b.date.compareTo(a.date));
    final result = <FinanceRecord>[];
    for (final e in raw) {
      result.add(FinanceRecord(
        id: e.id,
        type: await _safeDecrypt(e.type),
        amount: e.amount,
        category: await _safeDecrypt(e.category),
        description: await _safeDecrypt(e.description),
        date: e.date,
        createdAt: e.createdAt,
        currency: e.currency,
      ));
    }
    return result;
  }

  Future<void> addFinanceRecord({
    String? id,
    required String type, required double amount,
    required String category, required String description,
    required DateTime date, String currency = 'MOP',
    String? lineItemsJson,
  }) async {
    _requireUnlocked();
    final encType  = await cryptoService.encrypt(type, _sessionKey!);
    final encCat   = await cryptoService.encrypt(category, _sessionKey!);
    final encDesc  = await cryptoService.encrypt(description, _sessionKey!);
    final record = FinanceRecord(
      id: id ?? _uuid.v4(), type: encType, amount: amount, category: encCat,
      description: encDesc, date: date, createdAt: DateTime.now(),
      currency: currency, lineItemsJson: lineItemsJson,
    );
    await _finance.put(record.id, record);
  }

  Future<void> deleteFinanceRecord(String id) async {
    _requireUnlocked();
    await _finance.delete(id);
  }

  Future<void> updateFinanceRecord(FinanceRecord record, {
    String? type, double? amount, String? category,
    String? description, DateTime? date, String? currency,
  }) async {
    _requireUnlocked();
    final stored = _finance.get(record.id);
    if (stored == null) return;
    if (type != null)        stored.type        = await cryptoService.encrypt(type, _sessionKey!);
    if (amount != null)      stored.amount      = amount;
    if (category != null)    stored.category    = await cryptoService.encrypt(category, _sessionKey!);
    if (description != null) stored.description = await cryptoService.encrypt(description, _sessionKey!);
    if (date != null)        stored.date        = date;
    if (currency != null)    stored.currency    = currency;
    await stored.save();
  }

  // ── Export ─────────────────────────────────────────────
  Future<Map<String, dynamic>> exportVaultJson() async {
    _requireUnlocked();
    final meta = _meta.get('meta');
    return {
      'version': '2.0',
      'exportedAt': DateTime.now().toIso8601String(),
      // Salt + verifyHash are required to restore on a NEW device.
      // Without them the same password would derive a DIFFERENT key on a fresh install.
      'salt': meta?.salt ?? '',
      'verifyHash': meta?.verifyHash ?? '',
      'passwords': _passwords.values.map((e) => {
        'id': e.id, 'site': e.site, 'username': e.username,
        'encryptedPassword': e.encryptedPassword,
        'notes': e.notes,
        'createdAt': e.createdAt.toIso8601String(),
        'updatedAt': e.updatedAt.toIso8601String(),
        if (e.iconEmoji != null) 'iconEmoji': e.iconEmoji,
      }).toList(),
      'diary': _diary.values.map((e) => {
        'id': e.id, 'title': e.title, 'encryptedContent': e.encryptedContent,
        'mood': e.mood, 'tags': e.tags,
        'createdAt': e.createdAt.toIso8601String(),
        'updatedAt': e.updatedAt.toIso8601String(),
      }).toList(),
      'finance': _finance.values.map((e) => {
        'id': e.id, 'type': e.type, 'amount': e.amount,
        'category': e.category, 'description': e.description,
        'date': e.date.toIso8601String(),
        'createdAt': e.createdAt.toIso8601String(),
        'currency': e.currency,
        if (e.lineItemsJson != null) 'lineItemsJson': e.lineItemsJson,
      }).toList(),
      'images': _images.toMap(),
      'imageIndex': _imageIndex.toMap().map((key, value) =>
          MapEntry(key.toString(), List<String>.from(value as List))),
    };
  }

  // ── Import / Restore ────────────────────────────────────
  /// Restores all data from a backup produced by [exportVaultJson], transactionally
  /// (finding V-01, P0).
  ///
  /// The former clear-before-validate order (which erased the live vault before
  /// parsing, so any malformed record caused irreversible loss) is gone. The
  /// backup is now: (1) structurally validated in full, (2) when it carries
  /// credentials and [masterPassword] is supplied, confirmed to authenticate
  /// against those credentials, then (3) staged and atomically committed with a
  /// journalled resume. Any failure before commit-intent leaves the existing
  /// vault completely intact.
  ///
  /// Returns true when the caller must re-unlock with the master password
  /// (backup carried credentials), false for a same-device restore.
  Future<bool> importFromBackup(Map<String, dynamic> json,
      {String? masterPassword}) async {
    // 1. Structural preflight + parse. Throws RestoreValidationException on any
    //    anomaly BEFORE the live vault is touched.
    final staged = parseAndValidateBackup(json);

    // 2. Password confirmation before any destructive step: does the master
    //    password derive a key that authenticates against the backup credentials?
    if (masterPassword != null && staged.meta != null) {
      final ok = await _confirmBackupPassword(masterPassword, staged.meta!);
      if (!ok) {
        throw const RestoreValidationException(
            RestoreRejectCode.passwordMismatch,
            'master password does not match backup credentials');
      }
    }

    // 3. Transactional commit: stage -> verify -> atomic swap -> cleanup.
    final tx = await _openRestoreTx();
    await tx.commit(staged);

    if (staged.sideEffects.clearSession) _sessionKey = null;
    return staged.sideEffects.needsReunlock;
  }

  /// Confirms [password] authenticates against a backup's credentials by deriving
  /// a key from the backup's own salt and checking it against its verifyHash.
  Future<bool> _confirmBackupPassword(String password, VaultMeta meta) async {
    try {
      final salt = Uint8List.fromList(base64.decode(meta.salt));
      final key = await cryptoService.deriveKey(password, salt);
      return await cryptoService.verifyKey(key, meta.verifyHash);
    } catch (_) {
      return false;
    }
  }

  /// Builds the transactional restore engine bound to this vault's live boxes and
  /// secure storage. Restore/transfer direct helper.
  Future<TransactionalRestore> _openRestoreTx() => openHiveRestore(
        livePasswords: _passwords,
        liveDiary: _diary,
        liveFinance: _finance,
        liveImages: _images,
        liveImageIndex: _imageIndex,
        liveMeta: _meta,
        secureStorage: _secureStorage,
        saltKey: _saltKey,
        biometricKey: _biometricKey,
        encV2Key: _encV2Key,
      );

  /// Completes or rolls back a restore/transfer transaction that was interrupted
  /// (e.g. power loss) mid-commit. Idempotent; safe to call repeatedly. Wired into
  /// [unlock] (B2-3 seam 2) so a pending transaction is resolved before vault
  /// state is read.
  Future<void> recoverPendingRestore() async {
    // Fast path: peek the journal only. When no transaction is pending (the
    // common case) this avoids opening the staging boxes on every unlock.
    final journal = await HiveRestoreJournalStore.open();
    if (await journal.read() == null) return;
    final tx = await _openRestoreTx();
    await tx.recover();
  }

  // ── Stats ──────────────────────────────────────────────
  Map<String, int> getCounts() => {
    'passwords': _passwords.length,
    'diary':     _diary.length,
    'finance':   _finance.length,
  };


  Future<bool> canUseBiometric() async {
    try {
      final auth = LocalAuthentication();
      return await auth.canCheckBiometrics || await auth.isDeviceSupported();
    } catch (_) { return false; }
  }

  Future<bool> hasBiometricEnabled() async {
    final val = await _secureStorage.read(key: _biometricKey);
    return val != null;
  }

  Future<void> enableBiometric() async {
    _requireUnlocked();
    final keyBytes = await _sessionKey!.extractBytes();
    await _secureStorage.write(key: _biometricKey, value: base64.encode(keyBytes));
  }

  Future<bool> unlockWithBiometric() async {
    final auth = LocalAuthentication();
    final ok = await auth.authenticate(
      localizedReason: '使用生物識別解鎖保險庫',
      options: const AuthenticationOptions(biometricOnly: false),
    );
    if (!ok) return false;
    final encoded = await _secureStorage.read(key: _biometricKey);
    if (encoded == null) throw Exception('biometric_key_missing');
    _sessionKey = SecretKeyData(base64.decode(encoded));
    final meta = _meta.get('meta');
    if (meta != null) { meta.lastUnlocked = DateTime.now(); meta.unlockCount++; await meta.save(); }
    return true;
  }

  Future<void> disableBiometric() async {
    await _secureStorage.delete(key: _biometricKey);
  }

  void _requireUnlocked() {
    if (_sessionKey == null) throw StateError('Vault is locked');
  }
}

final vaultService = VaultService();
