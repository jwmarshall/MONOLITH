# Bundled LOVELACE scenery

These three JPEGs are owner-supplied project artwork, generated previously through
LOVELACE's server-side Google Gemini scenery connection. The owner explicitly
authorized copying and bundling all three with the project as installation defaults.
They are not third-party stock assets; no separate third-party artwork license was
supplied. This record does not assert provider provenance verification or confer
rights beyond the owner's authorization and applicable Gemini terms.

The original JPEG bytes and embedded metadata are preserved, without transcoding.
No private database, credentials, mail, or integration data is included. The private
originals remain untouched. Runtime rendering uses only local bundled files; no
provider call, remote image, or Keychain access is needed.

## SHA-256 pins

Each filename is its full SHA-256 digest:

- `403a724ce7707014e384d7f07d0820df1c4b499e34c807076bcd3c87dd0ea133.jpg`
- `cfd5e70f02db61442b938654f3a95a001280d7a773f20bd56f8950fa9376ba03.jpg`
- `edf9e32a1aefae7fb0f7edf13634b7692e7f2c5558f5a2af8c9d4e9ef92d6fb9.jpg`

`Lovelace.StageDesigner.BundledScenes` allowlists exactly these files. The local
Ash default-scene singleton chooses one on first application startup and preserves
it across restarts. Static owner pages and live views use the same choice beneath
generated scenery, including when a generated image is unavailable or fails to load.
The bundled images are not generated-scene catalog entries and cannot be evicted by
stage storage cleanup. Tests verify hashes and decode all three as bounded JPEGs.
