// Vendored from https://github.com/yshrsmz/unorm-dart (package: unorm_dart 0.3.2).
// pub archive sha256: 0c69186b03ca6addab0774bcc0f4f17b88d4ce78d9d4d8f0619e30a99ead58e7
// upstream tag: v0.3.2 — Unicode 17.0 normalization (NFC/NFD/NFKC/NFKD); Dart port of JS unorm.
// License: MIT — see LICENSE in this directory (Copyright (c) 2018 Yasuhiro Shimizu).
// Vendored under DEV-P0-03-B2-2 per director ruling DEV-P0-03-B2-2-NFC-and-guard-rulings-v1 §三.
// Local modifications: import paths rewritten `package:unorm_dart/src/*` -> relative `./*` (ONLY).
// FROZEN at this version. Any upgrade is a KDF-compatibility change (may alter derived KEK for a
// few characters) and requires director approval + existing-vault impact assessment (ruling §3.3).
//
import './uchar.dart';

typedef CurrFunc = UChar Function(NextFunc?, int, bool);

Function reduceRight(List<CurrFunc> list,
    NextFunc Function(NextFunc? prev, CurrFunc curr, int index, List list) fn,
    [Function? initialValue]) {
  var length = list.length;
  var index = length - 1;
  var value;
  var isValueSet = false;
  if (1 < list.length) {
    value = initialValue;
    isValueSet = true;
  }
  for (; -1 < index; --index) {
    if (isValueSet) {
      value = fn(value, list[index], index, list);
    } else {
      value = list[index];
      isValueSet = true;
    }
  }
  if (!isValueSet) {
    throw new TypeError(); //'Reduce of empty array with no initial value'
  }
  return value;
}

List<T> splice<T>(List<T> list, int index, [num howMany = 0, T? element]) {
  var endIndex = index + howMany.truncate();
  list.removeRange(index, endIndex >= list.length ? list.length : endIndex);
  if (element != null) {
    list.insertAll(index, [element]);
  }
  return list;
}