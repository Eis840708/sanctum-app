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
import './uchar.dart';
import './uchar_iterator.dart';

class RecursiveDecompositeIterator implements UnormIterator {
  final UCharIterator _iterator;
  final bool _canonical;
  List<UChar> _resultBuffer;

  RecursiveDecompositeIterator(this._iterator, this._canonical)
      : this._resultBuffer = [];

  List<UChar> _recursiveDecompose(bool canonical, UChar uchar) {
    final decomp = uchar.getDecomp();
    if (decomp != null && !(canonical && uchar.isCompatibility())) {
      final ret = <UChar>[];
      for (int i = 0; i < decomp.length; ++i) {
        final a = _recursiveDecompose(
            canonical, UChar.fromCharCode(decomp[i], false)!);
        ret.addAll(a);
      }
      return ret;
    } else {
      return [uchar];
    }
  }

  @override
  UChar? next() {
    if (_resultBuffer.isEmpty) {
      final uchar = _iterator.next();
      if (uchar == null) {
        return null;
      }
      _resultBuffer = _recursiveDecompose(_canonical, uchar);
    }
    return _resultBuffer.removeAt(0);
  }
}