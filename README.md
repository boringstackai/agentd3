# agentd3 — runtime distribution

Prebuilt binaries and a one-command installer for **agentd3**, a pure-Go agent
daemon + web UI that drives the [oh-my-pi](https://www.npmjs.com/package/@oh-my-pi/pi-coding-agent)
coding engine. Conversations, scheduling, provider failover, and an event-sourced
Postgres store — one daemon, one UI binary, no containers.

This repository is refreshed **daily** from the private source repo: every
release carries the binaries plus everything needed to bring up a completely
fresh machine.

## Install (fresh machine)

```sh
curl -fsSL https://github.com/boringstackai/agentd3/releases/latest/download/install.sh | bash
```

That single command:

1. Downloads the latest release tarball for your platform.
2. Installs missing dependencies — Postgres and Node via Homebrew (macOS) or
   apt (Linux). macOS requires Homebrew to be present.
3. Lays out the runtime under `~/agentd3` (override: `--prefix DIR`):
   binaries, config, a pinned [bun](https://bun.sh) runtime, and the pinned
   `@oh-my-pi/pi-coding-agent` engine version the binaries were tested against.
4. Registers always-on services (launchd agents on macOS, systemd user units
   on Linux) and waits for the daemon to report healthy.

The daemon creates and migrates its own Postgres database (`agentd3`) on first
boot — no manual DB setup.

After install:

| What | Where |
|---|---|
| Web UI | http://127.0.0.1:8621 |
| API | http://127.0.0.1:8620 (`/healthz` for status) |
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

Re-run the install one-liner. Binaries and the pinned engine are refreshed;
`local/config.toml`, the database, and all state are preserved.

## Release contents

Each `agentd3-<os>-<arch>.tar.gz` contains:

```
bin/agentd3          the daemon (API, scheduler, engine supervisor)
bin/agentd3-ui       the web UI (static assets embedded)
bin/agentd3-front    optional zero-downtime blue/green front proxy
bin/agentd3-swap     optional blue/green swap driver
install.sh           this installer
MANIFEST             source sha + pinned engine/runtime versions
README.md            this file
```

Platforms: `darwin-arm64`, `darwin-amd64`, `linux-arm64`, `linux-amd64`.
The primary, continuously-exercised platform is macOS on Apple Silicon; Linux
builds are cross-compiled from the same pure-Go source.

## Source

The source lives in a private repository; this distribution repo is
republished from it daily by an automated job.
