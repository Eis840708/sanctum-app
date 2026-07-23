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

class UCharIterator implements UnormIterator {
  String? _str;
  int _cursor = 0;

  UCharIterator(this._str);

  @override
  UChar? next() {
    if (_str != null && this._cursor < this._str!.length) {
      int cp = _str!.codeUnitAt(_cursor++);
      int d;
      if (UChar.isHighSurrogate(cp) &&
          _cursor < _str!.length &&
          UChar.isLowSurrogate((d = _str!.codeUnitAt(_cursor)))) {
        cp = (cp - 0xD800) * 0x400 + (d - 0xDC00) + 0x10000;
        ++_cursor;
      }
      return UChar.fromCharCode(cp, false);
    } else {
      _str = null;
      return null;
    }
  }
}