// Vendored from https://github.com/yshrsmz/unorm-dart (package: unorm_dart 0.3.2).
// pub archive sha256: 0c69186b03ca6addab0774bcc0f4f17b88d4ce78d9d4d8f0619e30a99ead58e7
// upstream tag: v0.3.2 — Unicode 17.0 normalization (NFC/NFD/NFKC/NFKD); Dart port of JS unorm.
// License: MIT — see LICENSE in this directory (Copyright (c) 2018 Yasuhiro Shimizu).
// Vendored under DEV-P0-03-B2-2 per director ruling DEV-P0-03-B2-2-NFC-and-guard-rulings-v1 §三.
// Local modifications: import paths rewritten `package:unorm_dart/src/*` -> relative `./*` (ONLY).
// FROZEN at this version. Any upgrade is a KDF-compatibility change (may alter derived KEK for a
// few characters) and requires director approval + existing-vault impact assessment (ruling §3.3).
//
import './composite_iterator.dart';
import './decomposite_iterator.dart';
import './iterator.dart';
import './recursive_decomposite_iterator.dart';
import './uchar.dart';
import './uchar_iterator.dart';

enum _NormalizeMode { NFD, NFKD, NFC, NFKC }

UnormIterator _createIterator(_NormalizeMode mode, String str) {
  switch (mode) {
    case _NormalizeMode.NFD:
      return DecompositeIterator(
          RecursiveDecompositeIterator(UCharIterator(str), true));
    case _NormalizeMode.NFKD:
      return DecompositeIterator(
          RecursiveDecompositeIterator(UCharIterator(str), false));
    case _NormalizeMode.NFC:
      return CompositeIterator(DecompositeIterator(
          RecursiveDecompositeIterator(UCharIterator(str), true)));
    case _NormalizeMode.NFKC:
      return CompositeIterator(DecompositeIterator(
          RecursiveDecompositeIterator(UCharIterator(str), false)));
  }
}

String _normalize(_NormalizeMode mode, String str) {
  initUCharCache();
  UnormIterator iterator = _createIterator(mode, str);
  StringBuffer ret = StringBuffer();
  UChar? uchar;
  while ((uchar = iterator.next()) != null) {
    ret.writeCharCode(uchar!.codepoint);
  }
  return ret.toString();
}

/// Normalizes provided [str] with Canonical Decomposition.
String nfd(String str) => _normalize(_NormalizeMode.NFD, str);

/// Normalizes provided [str] with Compatibility Decomposition.
String nfkd(String str) => _normalize(_NormalizeMode.NFKD, str);

/// Normalizes provided [str] with Canonical Decomposition, followed by Canonical Composition.
String nfc(String str) => _normalize(_NormalizeMode.NFC, str);

/// Normalizes provided [str] with Compatibility Decomposition, followed by Canonical Composition.
String nfkc(String str) => _normalize(_NormalizeMode.NFKC, str);