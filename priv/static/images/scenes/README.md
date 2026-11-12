# Bundled MONOLITH scenery

These seven JPEGs are owner-supplied project artwork from MONOLITH's local scenery
storage. The owner authorized copying them into the repository for default-install
use. Three are active installation defaults; four are retained for later use.
They are not third-party stock assets; no separate third-party artwork license was
supplied. This record does not assert provider provenance verification or confer
rights beyond the owner's authorization and applicable Gemini terms.

The original JPEG bytes and embedded metadata are preserved, without transcoding.
No private database, credentials, mail, or integration data is included. The private
originals remain untouched. All assets are public, locally served files; copying
them requires no provider call, remote image, or Keychain access.

## SHA-256 pins

Each filename is its full SHA-256 digest. Current installation defaults:

- `403a724ce7707014e384d7f07d0820df1c4b499e34c807076bcd3c87dd0ea133.jpg`
- `cfd5e70f02db61442b938654f3a95a001280d7a773f20bd56f8950fa9376ba03.jpg`
- `edf9e32a1aefae7fb0f7edf13634b7692e7f2c5558f5a2af8c9d4e9ef92d6fb9.jpg`

Additional owner-supplied backgrounds, reserved for later default-install use:

- `25d6d2c2a040958e98c6cf25063d6fc2c04cfb88a5bf479f7660eebea04fe6b4.jpg`
- `c537d46dab9c8a1fb03a8d7c518ce749b06a9a714be36082b23d5376a79674e3.jpg`
- `d6ba581dff3dda5e59ce6852837d3bd7a0ef86c78d259d80377056d4c392aaa4.jpg`
- `f1d3a75d7be66052c477ea78337c987d74643cbc127fb10bd5626093f4ce9e62.jpg`

`Monolith.StageDesigner.BundledScenes` still allowlists only the three current
defaults. Adding these four assets does not change selection or app behavior.
The local Ash default-scene singleton chooses one current default when encrypted
persistence first starts after owner unlock and preserves it across restarts.
Locked owner pages use the first allowlisted image; unlocked views use the saved
choice beneath generated scenery, including when a generated image is unavailable
or fails to load.
The bundled images are not generated-scene catalog entries and cannot be evicted by
stage storage cleanup. Existing tests verify hashes and decode the three active defaults
as bounded JPEGs; the four reserved assets are not part of the runtime allowlist.
