# agentd3 — runtime distribution

Prebuilt binaries and a one-command installer for the **agentd3 stack**:

- **agentd3** — a Go agent daemon + web UI that drives the exact-lock
  [Pi SDK](https://www.npmjs.com/package/@earendil-works/pi-coding-agent).
  Conversations, scheduling, immutable per-turn routing, and an event-sourced
  Postgres store — one daemon, one UI binary, no containers.
- **Mnemos** (`mnemnosd`) — long-term memory (Postgres + pgvector). Bundled
  when the publisher has a native or prebuilt binary for that platform;
  otherwise the tarball includes `NATIVE_BUILD.md` instead of omitting it.
- **agentd-gauge** — subscription-burn UI. Installed and auto-started with the
  daemon when bundled (`launch_gauges_on_start = true`), including Linux.

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
   (macOS) or apt (Linux). Missing Postgres fails closed (no SQLite).
3. Lays out `~/agentd3`: binaries, Pi SDK, OMP broker, bun, and writes
   `~/.config/daz-secrets/provider.toml` pointing at the bundled private
   provider. Empty store is provisioned only if absent.
4. Registers front (`127.0.0.1:8620`) + blue/green + gauge (launchd/systemd)
   and waits until `/healthz` attests the release `build_sha`.
5. Installs **one** updater: `bin/agentd3-update` (daily 04:30). Zero-downtime:
   idle color, healthz attest, front flip. Never stop-the-world restart.

The installer explicitly creates the `agentd3` and `mnemnos` databases before
first boot. The agentd3 daemon migrates only the configured existing database:
it requires the configured PostgreSQL system identifier and canonical data
directory to match before migration, and fails closed without creating or
selecting another store. On updates, the installer attests that same identity
before changing binaries and refuses to create either database. Mnemos migrates
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

agentd3 talks to AI providers through Pi; at least one provider login is needed
before turns can run. Use the provider controls in the UI. Credentials use the
configured `daz-secrets` provider and never enter runtime files or environment
variables.

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
runtime/pi/          exact-lock Pi SDK and ESM boundary
bin/mnemnosd         Mnemos memory daemon        (when bundled)
bin/mnemnosctl       Mnemos CLI                  (when bundled)
bin/mnemnos-ui       Mnemos web UI               (when bundled)
bin/agentd-gauge     usage gauge                 (when bundled)
bin/daz-secrets-provider-private  private provider (every platform)
bin/agentd3-update   zero-downtime GitHub updater (only entrypoint)
runtime/bun/         pinned bun for OMP
runtime/omp/         OMP package pin
lib.sh               installer/updater helpers
NATIVE_BUILD.md      how to add Mnemos/gauge when not cross-compiled
install.sh           this installer
MANIFEST             source shas + pinned engine/runtime versions
README.md            this file
```

Release assets also include a standalone `install.sh` (the bootstrap entry
point) and `VERSION` (the updater's cheap change probe).

Platforms: `darwin-arm64`, `darwin-amd64`, `linux-arm64`, `linux-amd64`.
The primary, continuously-exercised platform is macOS on Apple Silicon; the Go
binaries are cross-compiled from one source revision and each platform archive
includes the same exact-lock Pi ESM runtime.

## Source

The sources live in private repositories; this distribution repo is
republished from them daily by an automated job.
