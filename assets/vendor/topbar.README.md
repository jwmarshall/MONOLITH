# Vendored Topbar 3.0.0

MONOLITH bundles `assets/vendor/topbar.js` through the existing relative import in
`assets/js/app.js` for LiveView navigation/form progress. No npm installation,
CDN, runtime download, provider call, or application configuration change is needed.

## Verified provenance

Development-only public HTTPS retrieval established all of the following:

- Upstream repository: https://github.com/buunguyen/topbar
- Exact registry metadata: https://registry.npmjs.org/topbar/3.0.0
- Exact tarball: https://registry.npmjs.org/topbar/-/topbar-3.0.0.tgz
- Registry SHA-512 integrity, verified against the downloaded archive **before**
  accepting its files:
  `sha512-mhczD7KfYi1anfoMPKRdl0wPSWiYc0YOK4KyycYs3EaNT15pVVNDG5CtfgZcEBWIPJEdfR7r8K4hTXDD2ECBVQ==`
- Registry `gitHead`: `0f262ab7864ef6601b51102d068281982c8cfc8d`.
  The archive's `package/topbar.js` also matched
  https://raw.githubusercontent.com/buunguyen/topbar/0f262ab7864ef6601b51102d068281982c8cfc8d/topbar.js
  byte-for-byte: **4,391 bytes**, SHA-256
  `5683ab34a4fa482d9bc1227a539c445fd5dc934530a05b68f03d00cd97cae2a0`.
- The existing MONOLITH source matched those same upstream bytes exactly before
  adding the full legal comment described below. No executable code was changed.
  Use this commit, not an assumed `3.0.0` Git tag (none was present).

This is registry-integrity plus independent repository-content comparison, not a
claim of a verified publisher signature or an independent upstream security audit.

## License and distribution

Topbar is **MIT**, unlike GSAP's custom license. The verified archive's
`package/package.json` declares `"license": "MIT"`; its source header says
`@license MIT` and `Copyright (c) 2024 Buu Nguyen`. The archive's README says
`MIT license. Copyright 2021 Buu Nguyen.` Both copyright notices are retained.
The archive and corresponding Git tree contain **no separate full LICENSE file**.

`topbar.LICENSE.txt` supplies the complete standard MIT permission, condition and
warranty/liability notice, with those upstream copyright notices. It is not
represented as an upstream LICENSE-file snapshot. The standard text was checked
against [SPDX license-list-data v3.27.0 MIT.txt](https://raw.githubusercontent.com/spdx/license-list-data/v3.27.0/text/MIT.txt)
(reflowed, with upstream attribution substituted for its placeholder).

The sole addition to `topbar.js` is a trailing `/*! @license ... */` comment
containing the full license sidecar verbatim. Esbuild recognizes this as a legal
comment and retains it in bundled/minified JavaScript under the current default
legal-comment policy. Distribute that notice with the code; do not strip legal
comments or drop any emitted `.LEGAL.txt` sidecars if the build policy changes.
Source distributions must also retain these provenance/license/metadata records.
No separate runtime request for a license or script is introduced.

## Approved local SHA-256 pins

| Local file | Origin/change | SHA-256 |
| --- | --- | --- |
| `topbar.js` | `package/topbar.js` plus full MIT legal comment only | `5b865680f8fc3f1326859a824f31478ba7f0154d3926ffb1b3cf7f1c50f2fb2e` |
| `topbar.upstream-package.json` | Unmodified `package/package.json` (no final newline) | `30d5483d3e1d2c5021b3b5bcefee2dde0e5e176cf3a0fc57eb899c88198ec768` |
| `topbar.LICENSE.txt` | Complete MIT text and retained upstream notices | `c4ad21361d61199361282d25950da9ad9b60a2f8476d4524c4f95524b5278990` |

`test/monolith_web/vendor_assets_test.exs` intentionally pins all three files,
checks metadata/license/import agreement, checks that the full notice is in the
legal comment, and separately pins the unchanged upstream bytes without that
comment. Unexpected bytes must fail rather than silently becoming approved.

## Intentional update procedure

1. Select an explicit version. Retrieve its registry metadata and exact archive
   using public development-only HTTPS, never a runtime download or provider call.
   Verify the archive's SHA-512 against the versioned registry integrity **before**
   extracting/accepting source or calculating replacement approval pins.
2. Compare the required unminified artifact with the registry-linked immutable
   upstream commit, review code changes/advisories and the applicable license and
   copyright notices. Stop on discrepancies; do not merely hash existing bytes.
   Registry/archive integrity is not publisher-signature verification.
3. Retain exact package metadata and the complete applicable license. Preserve
   upstream code unchanged except for the documented full legal comment; do not
   prettify it. Update version/commit/URLs, integrity and local SHA-256 values here
   and in the test only after review. Review GSAP/fonts independently; do not
   relabel their licenses or replace their pins during a Topbar update.
4. Run the focused vendor and font/shell tests with generation disabled and a
   disposable test database, then the full quality gate. For this remediation:
   `MONOLITH_TEST_DATABASE=/tmp/monolith-remediation-tests/topbar.db MONOLITH_STAGE_ENABLED=false mix test test/monolith_web/vendor_assets_test.exs test/monolith_web/live/home_live_test.exs`.
   Ensure the parent directory exists; never use the user's private database.
5. Build minified assets into disposable output and check that the **complete**
   notice survives in the shipped JavaScript (or shipped legal sidecar if changed).
   Check navigation-start/show and navigation-stop/hide in a browser under the
   existing production CSP when changing executable code or bundling behavior.
   No server restart is needed just to verify these records. `mix audit` covers
   Hex, not Topbar; review vendored-JavaScript advisories separately.
