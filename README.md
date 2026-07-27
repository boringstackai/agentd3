# agentd3 — runtime distribution

Prebuilt binaries and a one-command installer for the **agentd3 stack**:

- **agentd3** — a pure-Go agent daemon + web UI that drives the
  [oh-my-pi](https://www.npmjs.com/package/@oh-my-pi/pi-coding-agent) coding
  engine. Conversations, scheduling, provider failover, and an event-sourced
  Postgres store — one daemon, one UI binary, no containers.
- **Mnemos** (`mnemnosd`) — the deterministic, source-grounded long-term memory
  system agentd3's brain features use (Rust, Postgres + pgvector). Bundled on
  macOS/arm64; on other platforms agentd3 runs standalone with brain features
  degraded.
- **agentd-gauge** — a native macOS dock app (Gio) showing live subscription
  burn for every provider, fed by agentd3's usage endpoint. Bundled on
  macOS/arm64.

This repository is refreshed **daily** from the private source repos: every
release carries the binaries plus everything needed to bring up a completely
fresh machine, and installed machines **self-update daily**.

## Install (fresh machine)

```sh
curl -fsSL https://github.com/boringstackai/agentd3/releases/latest/download/install.sh | bash
```

That single command:

1. Downloads the latest release tarball for your platform.
2. Installs missing dependencies — Postgres (+pgvector) and Node via Homebrew
   (macOS) or apt (Linux). macOS requires Homebrew to be present.
3. Lays out the runtime under `~/agentd3` (override: `--prefix DIR`):
   binaries, config, a pinned [bun](https://bun.sh) runtime, and the pinned
   `@oh-my-pi/pi-coding-agent` engine version the binaries were tested against.
4. Registers always-on services (launchd agents on macOS, systemd user units
   on Linux) and waits for the daemons to report healthy.
5. Installs an **auto-updater** (`bin/agentd3-update`, daily at 04:30) that
   compares the installed versions against the latest release and reinstalls
   in place when anything changed — binaries, engine pin, and Mnemos alike.

The agentd3 daemon creates and migrates its own Postgres database (`agentd3`)
on first boot; the installer creates the `mnemnos` database and Mnemos migrates
its own schema.

After install:

| What | Where |
|---|---|
| Web UI | http://127.0.0.1:8621 |
| API | http://127.0.0.1:8620 (`/healthz` for status) |
| Mnemos API / UI | http://127.0.0.1:8432 / http://127.0.0.1:8433 |
| Config | `~/agentd3/local/config.toml` |
| Logs | `~/agentd3/local/state/*.log` |

## Provider authentication

agentd3 talks to AI providers through the oh-my-pi engine; at least one
provider login is needed before turns can run:

```sh
cd ~/agentd3
./bin/agentd3 omp auth login <provider>     # OAuth (claude, openai, grok, ...)
```

API-key providers can instead store keys in the OS keychain (e.g.
`keyring set glm api_key`); the daemon bridges them to the engine automatically.

## Upgrading

Automatic: the daily updater reinstalls when the published versions change.
Manual any time: run `~/agentd3/bin/agentd3-update`, or re-run the install
one-liner. `local/*.toml` config, the databases, and all state are preserved.

## Release contents

Each `agentd3-<os>-<arch>.tar.gz` contains:

```
bin/agentd3          the daemon (API, scheduler, engine supervisor)
bin/agentd3-ui       the web UI (static assets embedded)
bin/agentd3-front    optional zero-downtime blue/green front proxy
bin/agentd3-swap     optional blue/green swap driver
bin/mnemnosd         Mnemos memory daemon        (darwin-arm64 tarball)
bin/mnemnosctl       Mnemos CLI                  (darwin-arm64 tarball)
bin/mnemnos-ui       Mnemos web UI               (darwin-arm64 tarball)
bin/agentd-gauge     macOS dock usage gauge      (darwin-arm64 tarball)
install.sh           this installer
MANIFEST             source shas + pinned engine/runtime versions
README.md            this file
```

Release assets also include a standalone `install.sh` (the bootstrap entry
point) and `VERSION` (the updater's cheap change probe).

Platforms: `darwin-arm64`, `darwin-amd64`, `linux-arm64`, `linux-amd64`.
The primary, continuously-exercised platform is macOS on Apple Silicon; Linux
builds are cross-compiled from the same pure-Go source (agentd3 only).

## Source

The sources live in private repositories; this distribution repo is
republished from them daily by an automated job.
