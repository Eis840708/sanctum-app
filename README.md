# sanctum_new

A new Flutter project.

## Continuous Integration

`.github/workflows/ci.yml` runs on every push / PR to `feat/vault-v3` and `main`
(GitHub Actions, `ubuntu-latest`, Flutter 3.44.3 pinned):

1. `flutter pub get`
2. **Analyze gate** — `flutter analyze` parsed against the project baseline
   `errors=0 / warnings<=2 / infos<=162` (vendored source excluded via
   `analysis_options.yaml`); enforced by `tool/ci_check_analyze.sh`.
3. **Test** — `flutter test` (host + widget suite).

Device-only `integration_test/` (Argon2id benchmark, biometric enrollment
invalidation) is **not** run in CI — it requires a physical device and is driven
with `flutter drive`. Release signing is out of scope for this workflow.

Run the same gate locally:

```bash
flutter analyze 2>&1 | tee analyze.txt || true
bash tool/ci_check_analyze.sh analyze.txt
flutter test
```

> Status badge / Actions link pending a GitHub remote (this repo is currently
> local-only). Once a remote is configured, add:
> `![CI](https://github.com/<owner>/<repo>/actions/workflows/ci.yml/badge.svg)`

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
