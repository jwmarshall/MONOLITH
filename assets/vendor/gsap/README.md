# Vendored GSAP 3.15.0

MONOLITH bundles GSAP locally with its existing Mix/esbuild pipeline. No npm install,
CDN, runtime download, or additional plugin is required.

## Provenance and integrity

- Package/version: `gsap@3.15.0`
- Upstream: https://github.com/greensock/GSAP/tree/3.15.0
- Registry metadata: https://registry.npmjs.org/gsap/3.15.0
- Tarball: https://registry.npmjs.org/gsap/-/gsap-3.15.0.tgz
- Registry SHA-512 integrity (verified before extraction):
  `sha512-dMW4CWBTUK1AEEDeZc1g4xpPGIrSf9fJF960qbTZmN/QwZIWY5wgliS6JWl9/25fpTGJrMRtSjGtOmPnfjZB+A==`

Vendored files:

| Local file | Upstream file | SHA-256 |
| --- | --- | --- |
| `gsap.js` | `package/dist/gsap.js` | `01effe0e121c22ba0f885a3f091f3dc6d1f0d445c4fba37dcb298e314eca5cfb` |
| `upstream-package.json` | `package/package.json` | `85cc13e31f7a3cd124b587a40f545f265f47d0dfb9a556bb122d70fc0fca3459` |

Both files are unmodified. The UMD distribution includes core GSAP and CSSPlugin;
esbuild imports it through a relative path. SVG tracing uses native path measurement
and dash properties, not DrawSVG. Letter spans are authored in HEEx, not SplitText.

## License

GSAP uses its custom **Standard "No Charge" License**, not MIT. Preserve all upstream
copyright and license notices. `LICENSE.txt` is a plain-text snapshot of the official
license page (including its FAQ), with whitespace normalized; that page states an
effective date of April 30, 2025 and a last-modified date of May 30, 2025.

- Authoritative license: https://gsap.com/standard-license/
- Incorporated Webflow terms: https://webflow.com/legal/terms

Review the license before changing product/distribution scope, especially before
building a visual animation-authoring tool.

## Updating

Download an explicitly versioned registry tarball, verify its SHA-512 against that
version's registry metadata, and extract only the required distribution and package
metadata. Review upstream changes and licensing, refresh the checksums here and in
`test/monolith_web/vendor_assets_test.exs`, then run `mix check` and browser animation
checks under the production CSP. Never edit `gsap.js` locally or replace it with a
runtime CDN import. `mix audit` covers Hex dependencies, not this vendored JavaScript;
review GSAP advisories separately when updating.
