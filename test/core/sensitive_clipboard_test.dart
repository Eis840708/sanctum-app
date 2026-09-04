// Red-team RT-C-01/02/03: the sensitive-clipboard auto-clear. These drive the
// SensitiveClipboard helper directly with the platform clipboard channel mocked
// to an in-memory string, proving:
//   • a copied secret is auto-cleared after the timeout,
//   • clearNow() wipes immediately (the hook used on lock / background / a
//     widget's dispose — the timer lives in the singleton, not the widget, so
//     leaving the screen still clears),
//   • the clear is CONDITIONAL: a value the user copied afterwards is preserved,
//   • the copy uses the native sensitive channel when present, else falls back.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctum/core/security/sensitive_clipboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // In-memory clipboard behind SystemChannels.platform.
  String board = '';
  // Records native sensitive-copy calls (com.sanctum.vault/clipboard).
  final List<String> nativeCopies = [];
  bool nativeChannelPresent = false;

  setUp(() {
    board = '';
    nativeCopies.clear();
    nativeChannelPresent = false;

    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          board = ((call.arguments as Map)['text'] as String?) ?? '';
          return null;
        case 'Clipboard.getData':
          return <String, dynamic>{'text': board};
        default:
          return null;
      }
    });

    messenger.setMockMethodCallHandler(SensitiveClipboard.channel, (call) async {
      if (!nativeChannelPresent) {
        throw MissingPluginException('no clipboard channel');
      }
      if (call.method == 'copySensitive') {
        final t = (call.arguments as Map)['text'] as String;
        nativeCopies.add(t);
        board = t; // native path also puts it on the board
        return true;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(SensitiveClipboard.channel, null);
  });

  test('auto-clears after the timeout (survives the copying widget)', () async {
    await SensitiveClipboard.instance
        .copy('s3cr3t', timeout: const Duration(milliseconds: 60));
    expect(board, 's3cr3t');
    // The widget that copied could be disposed here — the timer is in the
    // singleton, so the clear still happens.
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(board, '', reason: 'auto-cleared after timeout');
  });

  test('clearNow() wipes immediately (lock / background hook)', () async {
    await SensitiveClipboard.instance
        .copy('top-secret', timeout: const Duration(seconds: 60));
    expect(board, 'top-secret');
    await SensitiveClipboard.instance.clearNow();
    expect(board, '');
  });

  test('conditional: does not wipe a value copied afterwards', () async {
    await SensitiveClipboard.instance
        .copy('vault-key', timeout: const Duration(milliseconds: 60));
    // User copies something else before the timer fires.
    board = 'user-copied-this';
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(board, 'user-copied-this', reason: 'user value preserved');
  });

  test('clearNow() is a no-op when nothing is pending', () async {
    board = 'unrelated';
    await SensitiveClipboard.instance.clearNow();
    expect(board, 'unrelated');
  });

  test('uses the native sensitive channel when present', () async {
    nativeChannelPresent = true;
    await SensitiveClipboard.instance
        .copy('sensitive', timeout: const Duration(seconds: 60));
    expect(nativeCopies, contains('sensitive'));
    expect(board, 'sensitive');
  });

  test('falls back to a plain copy when the native channel is absent', () async {
    nativeChannelPresent = false; // throws MissingPluginException
    await SensitiveClipboard.instance
        .copy('fallback', timeout: const Duration(seconds: 60));
    expect(nativeCopies, isEmpty);
    expect(board, 'fallback'); // still copied via Clipboard.setData
    await SensitiveClipboard.instance.clearNow();
  });
}
