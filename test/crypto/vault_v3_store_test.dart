// Tests for the v3 store + model<->fieldMap conversion (DEV-P0-03 B2-5b).
// Synthetic key/vault only. Covers the supplement §6 typed-field serialisation
// (incl. the director-required double amount extreme/precision round-trip) and a
// real-Hive store round-trip that leaks no plaintext.

import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:sanctum/core/crypto/v3/vault_v3_envelope.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_store.dart';
import 'package:sanctum/core/models/models.dart';

late Directory _tmp;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('b2_5b_store_');
    Hive.init(_tmp.path);
  });
  tearDownAll(() async {
    await Hive.close();
    try {
      await _tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('pure conversion round-trip (supplement §6)', () {
    test('password fields round-trip (incl. null iconEmoji)', () {
      final e = PasswordEntry(
        id: 'p1', site: 's', username: 'u', encryptedPassword: 'pw',
        notes: 'n', createdAt: DateTime(2026, 3, 2, 1, 4),
        updatedAt: DateTime(2026, 5, 6, 7, 8),
      );
      final r = passwordFromFields('p1', passwordToFields(e));
      expect(r.site, e.site);
      expect(r.username, e.username);
      expect(r.encryptedPassword, e.encryptedPassword);
      expect(r.notes, e.notes);
      expect(r.iconEmoji, isNull);
      expect(r.createdAt, e.createdAt);
      expect(r.updatedAt, e.updatedAt);

      final e2 = PasswordEntry(
        id: 'p2', site: 's', username: 'u', encryptedPassword: 'pw',
        createdAt: DateTime(2026), updatedAt: DateTime(2026), iconEmoji: '🔑',
      );
      expect(passwordFromFields('p2', passwordToFields(e2)).iconEmoji, '🔑');
    });

    test('diary fields round-trip (tags list preserved)', () {
      final e = DiaryEntry(
        id: 'd1', title: 't', encryptedContent: 'c', mood: 'm',
        tags: ['a', 'b', 'c'],
        createdAt: DateTime(2026), updatedAt: DateTime(2026, 2),
      );
      final r = diaryFromFields('d1', diaryToFields(e));
      expect(r.tags, ['a', 'b', 'c']);
      expect(r.title, 't');
      expect(r.createdAt, e.createdAt);
    });

    test('finance amount round-trips at extreme / precision boundaries', () {
      const amounts = <double>[
        0.0,
        0.1,
        0.1 + 0.2, // 0.30000000000000004
        1234567.89,
        -9876.54,
        1e-300,
        5e-324, // double.minPositive
        1.7976931348623157e308, // double.maxFinite
        -1.7976931348623157e308,
        9007199254740993.0, // > 2^53
        123456789012345.6,
      ];
      for (final a in amounts) {
        final e = FinanceRecord(
          id: 'f', type: 'expense', amount: a, category: 'c',
          description: 'd', date: DateTime(2026), createdAt: DateTime(2026),
          currency: 'HKD',
        );
        final r = financeFromFields('f', financeToFields(e));
        expect(r.amount, a, reason: 'amount $a did not round-trip exactly');
      }
    });

    test('finance lineItemsJson null vs present round-trips', () {
      final none = FinanceRecord(
        id: 'f', type: 't', amount: 1, category: 'c', description: 'd',
        date: DateTime(2026), createdAt: DateTime(2026),
      );
      expect(financeFromFields('f', financeToFields(none)).lineItemsJson, isNull);

      final some = FinanceRecord(
        id: 'f', type: 't', amount: 1, category: 'c', description: 'd',
        date: DateTime(2026), createdAt: DateTime(2026),
        lineItemsJson: '[{"n":"x","a":1.5}]',
      );
      expect(financeFromFields('f', financeToFields(some)).lineItemsJson,
          '[{"n":"x","a":1.5}]');
    });
  });

  group('store round-trip over real Hive (no plaintext leak)', () {
    test('put -> get -> getAll decrypts; stored form is all envelopes', () async {
      final store = VaultV3Store(
        dataKey: SecretKey(List<int>.generate(32, (i) => i)),
        vaultId: Uint8List.fromList(List<int>.generate(16, (i) => i + 9)),
      );
      final box = await Hive.openBox(kV3FinanceBox);
      await box.clear();

      final rec = FinanceRecord(
        id: 'fin-1', type: 'expense', amount: 4321.99, category: 'food',
        description: 'sushi dinner', date: DateTime(2026, 6, 1),
        createdAt: DateTime(2026, 6, 1), currency: 'JPY',
      );
      await store.put(
        box: box, recordType: RecordType.finance, id: rec.id,
        fields: financeToFields(rec),
      );

      // Stored form leaks no plaintext.
      final raw = box.get('fin-1') as String;
      expect(raw.contains('sushi'), isFalse);
      expect(raw.contains('4321'), isFalse);
      expect(raw.contains('food'), isFalse);

      final got = await store.get(
          box: box, recordType: RecordType.finance, id: 'fin-1');
      final back = financeFromFields('fin-1', got!);
      expect(back.description, 'sushi dinner');
      expect(back.amount, 4321.99);
      expect(back.currency, 'JPY');

      final all = await store.getAll(box: box, recordType: RecordType.finance);
      expect(all, hasLength(1));
      expect(financeFromFields(all.single.key, all.single.value).description,
          'sushi dinner');
    });
  });
}
