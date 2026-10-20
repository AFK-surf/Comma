# Comma Android agent rules

These rules apply to every change in `clients/apps/android`. The repository
root `AGENTS.md` also applies.

## Scrolling

- Every scrolling surface in the app must use the `:scroll` module (`surf.comma.android.scroll`).
  This includes lists, whole pages, bottom sheets, and horizontal strips.
- Do not use `android.widget.ScrollView`, `android.widget.HorizontalScrollView`,
  `androidx.core.widget.NestedScrollView`, or `androidx.recyclerview.widget.RecyclerView`
  in app code or layouts. Use the `:scroll` equivalents instead.
- If the `:scroll` module does not provide what you need, add it to the module.
  Do not work around the rule in app code.
- The only exception is text scrolling inside an `EditText`.
- `:app:checkScrollUsage` enforces this rule before every lint task. Do not
  weaken or bypass it.

## Design

- Use the shared design foundation for colours, type, motion and springs
  (see `docs/DESIGN.md`). Do not add colour or font resources outside it.
- Physical motion (offset, scale, rotation, size) uses springs; fades, colour
  changes and streaming text use durations and curves (`docs/DESIGN.md` §6.1).

## Source hygiene

- Do not name internal projects, private repositories, local paths or other
  apps' decompiled internals in code, comments, resources or README.
- Keep the upstream copyright headers in files derived from third-party code
  and list them in `NOTICE`.
- Licensed icons must be registered in `IconSources`.

## Versions and builds

- `version.properties` owns production versions and the base staging version name.
  Staging CI uses `1000000 + Client Checks run_number` as its independent versionCode.
  Do not reset this workflow's counter or use another workflow's counter for staging.
- Increase production `versionCode` before distribution. Each environment's codes must increase.
  A retry keeps the original commit and code. Never replace a published APK.
- Keep signing keys outside the Git repository. Tests, lint and development
  builds must work without signing settings or service credentials.
