// Real-adapter regression for V-08 recovery LIVE service wiring (B2-5a).
// DEV-P0-03 B2-5a. Synthetic passwords only.
//
// VaultService.enableV3Recovery/recoverV3 cannot run under `flutter test`
// (VaultService.init uses Hive.initFlutter -> platform). This suite reproduces
// their exact orchestration against a REAL Hive material box + the real crypto
// (VaultV3Live + VaultV3Recovery), mirroring the service methods line-for-line:
//
//   enableV3Recovery(pw):  unwrapDek(pw) -> recovery.enable -> withRecovery -> persist
//   recoverV3(shares,new): recovery.recoverDek -> live.rekey(new) -> persist -> session
//
// Proves the enable->split->recover round-trip closes V-08 end-to-end for v3
// vaults, and that reconstruction is fail-closed.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:sanctum/core/crypto/crypto_service.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_live.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_recovery.dart';
import 'package:sanctum/core/crypto/v3/vault_v3_shamir.dart';

late Directory _tmp;
late Box _box;
const _key = 'material';

final _live = VaultV3Live();
final _recovery = VaultV3Recovery();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('b2_5a_rec_');
    Hive.init(_tmp.path);
    _box = await Hive.openBox('sanctum_vault_v3');
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await _tmp.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async => _box.clear());

  test('enable -> split -> recover round-trip closes V-08 (v3, real Hive)',
      () async {
    // A fresh v3 vault, with a secret sealed under its data subkey.
    final created = await _live.create('old-password');
    await _box.put(_key, created.material.encode());
    final secret = await cryptoService.encrypt('MY-DIARY', created.dataKey);

    // enableV3Recovery('old-password')
    final shares = await _enable('old-password', n: 5, k: 3);
    expect(shares, hasLength(5));

    // recoverV3(shares, 'brand-new-password')
    final dataKey = await _recover([shares[0], shares[2], shares[4]], 'brand-new-password');

    // The DEK is unchanged, so the recovered data subkey still decrypts the secret.
    expect(await cryptoService.decrypt(secret, dataKey), 'MY-DIARY');

    // Password was reset: the new password unlocks, the old one no longer does.
    final after = VaultV3Material.decode(_box.get(_key) as String);
    final viaNew = await _live.unlock('brand-new-password', after);
    expect(await cryptoService.decrypt(secret, viaNew), 'MY-DIARY');
    await expectLater(
      _live.unlock('old-password', after),
      throwsA(anything),
    );
  });

  test('insufficient shares -> fail-closed (no recovery, no reset)', () async {
    final created = await _live.create('pw');
    await _box.put(_key, created.material.encode());
    final shares = await _enable('pw', n: 5, k: 3);

    await expectLater(
      _recover([shares[0], shares[1]], 'new'),
      throwsA(isA<ShamirVerifyException>()
          .having((e) => e.code, 'code', ShamirRejectCode.insufficientShares)),
    );
  });

  test('tampered share -> fail-closed (checksumFailed)', () async {
    final created = await _live.create('pw');
    await _box.put(_key, created.material.encode());
    final shares = await _enable('pw', n: 5, k: 3);
    final bad = Uint8List.fromList(shares[0]);
    bad[28] ^= 0xFF;

    await expectLater(
      _recover([bad, shares[1], shares[2]], 'new'),
      throwsA(isA<ShamirVerifyException>()
          .having((e) => e.code, 'code', ShamirRejectCode.checksumFailed)),
    );
  });

  test('wrong password at enable fails closed (cannot unwrap DEK)', () async {
    final created = await _live.create('right');
    await _box.put(_key, created.material.encode());
    await expectLater(_enable('wrong', n: 5, k: 3), throwsA(anything));
  });
}

// ── Mirrors of VaultService.enableV3Recovery / recoverV3 over the real box ────

Future<List<Uint8List>> _enable(String masterPassword,
    {required int n, required int k}) async {
  final material = VaultV3Material.decode(_box.get(_key) as String);
  final dek = await _live.unwrapDek(masterPassword, material);
  final result =
      await _recovery.enable(dek: dek, vaultId: material.vaultId, n: n, k: k);
  await _box.put(
    _key,
    material
        .withRecovery(
            recoveryWrappedDek: result.recoveryWrappedDek,
            recoveryCommit: result.commit)
        .encode(),
  );
  return result.shares;
}

Future<dynamic> _recover(List<Uint8List> shares, String newPassword) async {
  final material = VaultV3Material.decode(_box.get(_key) as String);
  final dek = await _recovery.recoverDek(
    shares: shares,
    commit: material.recoveryCommit!,
    recoveryWrappedDek: material.recoveryWrappedDek!,
    vaultId: material.vaultId,
  );
  final rekeyed =
      await _live.rekey(dek: dek, previous: material, newPassword: newPassword);
  await _box.put(_key, rekeyed.material.encode());
  return rekeyed.dataKey;
}
