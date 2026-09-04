import 'dart:async';

import 'package:flutter/services.dart';

/// Auto-clearing clipboard for sensitive values — record passwords, generated
/// vault credentials, recovered master passwords, and recovery shares.
///
/// Red-team RT-C-01/02/03: a copied secret must not sit on the clipboard
/// indefinitely. The clear timer and the lifecycle hooks are owned HERE, not by
/// any widget: leaving the screen (widget dispose), locking the vault, or the
/// app going to the background all still clear. The clear is *conditional* — it
/// only wipes the clipboard if it still holds the exact value we put there, so a
/// value the user copied afterwards is never destroyed. On Android the copy is
/// also marked sensitive (EXTRA_IS_SENSITIVE) so it is kept out of clipboard
/// history / on-screen previews; other platforms get a plain copy.
class SensitiveClipboard {
  SensitiveClipboard._();
  static final SensitiveClipboard instance = SensitiveClipboard._();

  /// Native channel that sets the Android sensitive-clipboard flag. Absent under
  /// `flutter test` and on non-Android platforms — [copy] falls back to a plain
  /// clipboard write there.
  static const MethodChannel channel =
      MethodChannel('com.sanctum.vault/clipboard');

  static const Duration defaultTimeout = Duration(seconds: 30);

  Timer? _timer;
  String? _pending; // the sensitive value currently believed to be on the board

  /// True while a sensitive value is on the clipboard awaiting auto-clear.
  bool get hasPending => _pending != null;

  /// Seconds configured for the auto-clear (for UI copy).
  static int get clearSeconds => defaultTimeout.inSeconds;

  /// Copy [text] to the clipboard and schedule an auto-clear after [timeout].
  Future<void> copy(String text, {Duration timeout = defaultTimeout}) async {
    _timer?.cancel();
    await _write(text);
    _pending = text;
    _timer = Timer(timeout, clearNow);
  }

  /// Clear the clipboard now if it still holds our pending value. Safe to call
  /// from anywhere and any number of times (lock, background, dispose).
  Future<void> clearNow() async {
    _timer?.cancel();
    _timer = null;
    final pending = _pending;
    _pending = null;
    if (pending == null) return;
    try {
      final cur = await Clipboard.getData(Clipboard.kTextPlain);
      if (cur?.text == pending) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    } catch (_) {
      // If we cannot read it back, err on the safe side and clear.
      await Clipboard.setData(const ClipboardData(text: ''));
    }
  }

  Future<void> _write(String text) async {
    try {
      final ok = await channel.invokeMethod<bool>(
          'copySensitive', <String, Object?>{'text': text});
      if (ok == true) return;
    } on MissingPluginException {
      // No native channel (test / non-Android) — fall through to a plain copy.
    } catch (_) {
      // Native failure — fall through to a plain copy so the copy still works.
    }
    await Clipboard.setData(ClipboardData(text: text));
  }
}
