import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../storage/vault_service.dart';
import '../models/models.dart';

// ── Auth state ───────────────────────────────────────────────
enum AuthState { locked, unlocked, loading }

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier() : super(AuthState.locked);

  Future<bool> unlock(String password) async {
    state = AuthState.loading;
    final ok = await vaultService.unlock(password);
    state = ok ? AuthState.unlocked : AuthState.locked;
    return ok;
  }

  Future<void> createVault(String password) async {
    state = AuthState.loading;
    await vaultService.createVault(password);
    state = AuthState.unlocked;
  }

  void lock() {
    vaultService.lock();
    state = AuthState.locked;
  }

  Future<bool> unlockWithBiometric() async {
    state = AuthState.loading;
    try {
      final ok = await vaultService.unlockWithBiometric();
      state = ok ? AuthState.unlocked : AuthState.locked;
      return ok;
    } catch (_) {
      state = AuthState.locked;
      rethrow;
    }
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (_) => AuthNotifier(),
);
final inactivityTimeoutProvider = StateProvider<int>((_) => 60);
class InactivityNotifier extends StateNotifier<Timer?> {
  final Ref _ref;
  InactivityNotifier(this._ref) : super(null);
  void resetTimer() {
    state?.cancel();
    final secs = _ref.read(inactivityTimeoutProvider);
    if (secs == 0) return;
    state = Timer(Duration(seconds: secs), () { _ref.read(authProvider.notifier).lock(); });
  }
  void cancel() { state?.cancel(); state = null; }
  @override
  void dispose() { state?.cancel(); super.dispose(); }
}
final inactivityProvider = StateNotifierProvider<InactivityNotifier, Timer?>(
  (ref) => InactivityNotifier(ref),
);


// ── Passwords ────────────────────────────────────────────────
final passwordsProvider = FutureProvider<List<PasswordEntry>>((ref) async {
  ref.watch(authProvider);
  return vaultService.getPasswords();
});

class PasswordsNotifier extends StateNotifier<AsyncValue<List<PasswordEntry>>> {
  PasswordsNotifier() : super(const AsyncValue.loading());

  Future<void> load() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => vaultService.getPasswords());
  }

  Future<void> add({
    required String site,
    required String username,
    required String password,
    String notes = '',
  }) async {
    await vaultService.addPassword(
      site: site, username: username, password: password, notes: notes,
    );
    await load();
  }

  Future<void> update(PasswordEntry entry, {
    String? site, String? username, String? password, String? notes,
  }) async {
    await vaultService.updatePassword(entry,
        site: site, username: username, newPassword: password, notes: notes);
    await load();
  }

  Future<void> delete(String id) async {
    await vaultService.deletePassword(id);
    await load();
  }
}

final passwordsNotifierProvider =
    StateNotifierProvider<PasswordsNotifier, AsyncValue<List<PasswordEntry>>>(
  (_) => PasswordsNotifier(),
);

// ── Diary ────────────────────────────────────────────────────
class DiaryNotifier extends StateNotifier<AsyncValue<List<DiaryEntry>>> {
  DiaryNotifier() : super(const AsyncValue.loading());

  Future<void> load() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => vaultService.getDiaryEntries());
  }

  Future<String> add({
    required String title,
    required String content,
    required String mood,
  }) async {
    final id = await vaultService.addDiaryEntry(title: title, content: content, mood: mood);
    await load();
    return id;
  }

  Future<void> delete(String id) async {
    await vaultService.deleteDiaryEntry(id);
    await load();
  }
}

final diaryNotifierProvider =
    StateNotifierProvider<DiaryNotifier, AsyncValue<List<DiaryEntry>>>(
  (_) => DiaryNotifier(),
);

// ── Finance ──────────────────────────────────────────────────
class FinanceNotifier extends StateNotifier<AsyncValue<List<FinanceRecord>>> {
  FinanceNotifier() : super(const AsyncValue.loading());

  Future<void> load() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => vaultService.getFinanceRecords());
  }

  Future<void> add({
    required String type,
    required double amount,
    required String category,
    required String description,
    required DateTime date,
    String currency = 'MOP',
  }) async {
    await vaultService.addFinanceRecord(
      type: type, amount: amount, category: category,
      description: description, date: date, currency: currency,
    );
    await load();
  }

  Future<void> addFull({
    required String id,
    required String type,
    required double amount,
    required String category,
    required String description,
    required DateTime date,
    String currency = 'MOP',
    String? lineItemsJson,
  }) async {
    await vaultService.addFinanceRecord(
      id: id, type: type, amount: amount, category: category,
      description: description, date: date,
      currency: currency, lineItemsJson: lineItemsJson,
    );
    await load();
  }

  Future<void> delete(String id) async {
    await vaultService.deleteFinanceRecord(id);
    await load();
  }
}

final financeNotifierProvider =
    StateNotifierProvider<FinanceNotifier, AsyncValue<List<FinanceRecord>>>(
  (_) => FinanceNotifier(),
);

// ── Counts ───────────────────────────────────────────────────
final countsProvider = Provider<Map<String, int>>((_) => vaultService.getCounts());
