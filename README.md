# LOVELACE

A quiet place to orient your day.

LOVELACE is a personal homepage that runs locally on your Mac. Read Gmail,
optionally see today's Google Calendar agendas, and follow open GitHub pull requests.
Workspaces group separate accounts and GitHub personal/organization installations by area of life.

- Read-only: no sending mail, changing mailbox state, editing calendar events, or modifying GitHub repositories.
- One local owner; its password unlocks a dedicated macOS keychain and SQLCipher-encrypted SQLite database.
- Local-only: keep it on loopback, not a public server or tunnel.
- Startup is locked. Explicit Lock stops protected background work; visual idle/Escape does not.
- No password recovery. Existing plaintext data requires an explicit, stopped migration.

A glass interface keeps your work in front of the scenery.
[Optional generated scenery](docs/STAGE_DESIGNER.md) is opt-in and may incur API costs.

## Try it locally

Start with the [local setup guide](docs/DEVELOPMENT.md#local-setup).
Connecting an account requires your own [Google setup](docs/GMAIL.md#2-google-cloud-setup)
and a manual connection; Calendar requires separate consent.
You can open LOVELACE without Google credentials, but mail and agendas need a connection.
GitHub uses App sign-in and selected personal/organization installations; see
[GitHub setup](docs/DEVELOPMENT.md#github).

## Development

Built with Elixir, Phoenix LiveView, Ash, and SQLite.

```sh
bin/lovelace-sqlcipher mix check      # format, compile, lint/security, tests, and assets
bin/lovelace-sqlcipher mix audit      # online dependency audit
bin/lovelace-sqlcipher mix test.ui    # browser checks; requires Chrome/Chromium
```

[Development guide](docs/DEVELOPMENT.md) · [Gmail](docs/GMAIL.md) ·
[Calendar](docs/CALENDAR.md) · [UI and accessibility](docs/UI_CONTRACT.md)
