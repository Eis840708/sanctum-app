// Vendored from https://github.com/yshrsmz/unorm-dart (package: unorm_dart 0.3.2).
// pub archive sha256: 0c69186b03ca6addab0774bcc0f4f17b88d4ce78d9d4d8f0619e30a99ead58e7
// upstream tag: v0.3.2 — Unicode 17.0 normalization (NFC/NFD/NFKC/NFKD); Dart port of JS unorm.
// License: MIT — see LICENSE in this directory (Copyright (c) 2018 Yasuhiro Shimizu).
// Vendored under DEV-P0-03-B2-2 per director ruling DEV-P0-03-B2-2-NFC-and-guard-rulings-v1 §三.
// Local modifications: import paths rewritten `package:unorm_dart/src/*` -> relative `./*` (ONLY).
// FROZEN at this version. Any upgrade is a KDF-compatibility change (may alter derived KEK for a
// few characters) and requires director approval + existing-vault impact assessment (ruling §3.3).
//
import './iterator.dart';
import './recursive_decomposite_iterator.dart';
import './uchar.dart';
import './utils.dart';

class DecompositeIterator implements UnormIterator {
  final RecursiveDecompositeIterator _iterator;
  List<UChar> _resultBuffer;

  DecompositeIterator(this._iterator) : this._resultBuffer = [];

  @override
  UChar? next() {
    int cc;
    if (_resultBuffer.isEmpty) {
      do {
        UChar? uchar = _iterator.next();
        if (uchar == null) {
          break;
        }

        cc = uchar.getCanonicalClass();
        int inspt = _resultBuffer.length;
        if (cc != 0) {
          for (; inspt > 0; --inspt) {
            UChar uchar2 = _resultBuffer[inspt - 1];
            int cc2 = uchar2.getCanonicalClass();
            if (cc2 <= cc) {
              break;
            }
          }
        }
        splice<UChar>(_resultBuffer, inspt, 0, uchar);
      } while (cc != 0);
    }
    return _resultBuffer.isEmpty ? null : _resultBuffer.removeAt(0);
  }
}