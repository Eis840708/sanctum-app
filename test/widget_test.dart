import 'package:flutter_test/flutter_test.dart';

import 'package:sanctum/core/crypto/crypto_service.dart';

void main() {
  test('encrypts and decrypts with a derived key', () async {
    final salt = cryptoService.generateSalt();
    final key = await cryptoService.deriveKey('correct horse battery staple', salt);

    final encrypted = await cryptoService.encrypt('private note', key);
    final decrypted = await cryptoService.decrypt(encrypted, key);

    expect(encrypted, isNot('private note'));
    expect(decrypted, 'private note');
  });

  test('rejects a wrong derived key', () async {
    final salt = cryptoService.generateSalt();
    final key = await cryptoService.deriveKey('correct password', salt);
    final wrongKey = await cryptoService.deriveKey('wrong password', salt);
    final verifyHash = await cryptoService.makeVerifyHash(key);

    expect(await cryptoService.verifyKey(wrongKey, verifyHash), isFalse);
  });
}
