// Vendored from https://github.com/yshrsmz/unorm-dart (package: unorm_dart 0.3.2).
// pub archive sha256: 0c69186b03ca6addab0774bcc0f4f17b88d4ce78d9d4d8f0619e30a99ead58e7
// upstream tag: v0.3.2 — Unicode 17.0 normalization (NFC/NFD/NFKC/NFKD); Dart port of JS unorm.
// License: MIT — see LICENSE in this directory (Copyright (c) 2018 Yasuhiro Shimizu).
// Vendored under DEV-P0-03-B2-2 per director ruling DEV-P0-03-B2-2-NFC-and-guard-rulings-v1 §三.
// Local modifications: import paths rewritten `package:unorm_dart/src/*` -> relative `./*` (ONLY).
// FROZEN at this version. Any upgrade is a KDF-compatibility change (may alter derived KEK for a
// few characters) and requires director approval + existing-vault impact assessment (ruling §3.3).
//
import './decomposite_iterator.dart';
import './iterator.dart';
import './uchar.dart';

class CompositeIterator implements UnormIterator {
  final DecompositeIterator _iterator;
  List<UChar> _processBuffer;
  List<UChar> _resultBuffer;
  int _lastClass;

  CompositeIterator(this._iterator)
      : _processBuffer = [],
        _resultBuffer = [],
        _lastClass = -1;

  @override
  UChar? next() {
    while (_resultBuffer.isEmpty) {
      UChar? uchar = _iterator.next();
      if (uchar == null) {
        _resultBuffer = _processBuffer;
        _processBuffer = [];
        break;
      }
      if (_processBuffer.isEmpty) {
        _lastClass = uchar.getCanonicalClass();
        _processBuffer.add(uchar);
      } else {
        UChar starter = _processBuffer[0];
        UChar? composite = starter.getComposite(uchar);
        int cc = uchar.getCanonicalClass();

        if (composite != null && (_lastClass < cc || _lastClass == 0)) {
          _processBuffer[0] = composite;
        } else {
          if (cc == 0) {
            _resultBuffer = _processBuffer;
            _processBuffer = [];
          }
          _lastClass = cc;
          _processBuffer.add(uchar);
        }
      }
    }
    return _resultBuffer.isEmpty ? null : _resultBuffer.removeAt(0);
  }
}