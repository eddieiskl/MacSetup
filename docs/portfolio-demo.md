# MacSetup walkthrough

This walkthrough demonstrates selection and script inspection without installing or removing applications.

1. Build with `./Scripts/build-app.sh --debug` and open `build/MacSetup.app`.
2. Browse a category and select a few applications.
3. Open **Preview Script**. Explain where downloads come from and what will execute.
4. Review the selection and signature-verification options. Do not start installation for this walkthrough.
5. Save a named profile and inspect its JSON export.
6. Explain how the same selection can support repeatable machine setup.

## Design decisions to discuss

- A native SwiftUI interface paired with inspectable shell automation.
- A data-driven catalogue rather than one hard-coded installer per application.
- Per-item results and explicit uncertainty in version reporting.
- Separation between ordinary user operations and steps needing administrator approval.
- The distinction between ad-hoc local builds and signed, notarized distribution.

## Validation

The repository provides `./Scripts/selftest.sh --offline` for offline checks and broader self-test modes that can perform sandboxed downloads/installations. Read the script before choosing a mode. A successful build alone does not validate every vendor URL or installation path.

A debug build is architecture-specific. The default release build attempts both Apple Silicon and Intel slices; inspect its output before claiming a universal artifact.

## Portfolio verification — 2026-09-23

The current Swift source compiled and the debug app packaged successfully on Apple Silicon after a one-line shell variable expansion fix in `build-app.sh`. The built-in `--render-ui` command produced eight component images. No app installations, removals, notarization, Intel build, or full vendor-source validation were performed for this documentation update.
