#!/usr/bin/env bash
# agentd3 stack installer — bootstraps a COMPLETELY FRESH machine to a running
# agentd3 (+ Mnemos memory system when bundled for the platform).
#
# Two modes, auto-detected:
#   1. Bootstrap (curl | bash, or run outside a release tree): downloads the
#      latest release tarball for this platform from GitHub, extracts it, and
#      re-runs the bundled installer from inside it.
#   2. Local (run from inside an extracted release tarball, next to bin/ and
#      MANIFEST): installs binaries + runtime dependencies and starts services.
#
# What it sets up (idempotent — safe to re-run to upgrade):
#   <prefix>/bin/            agentd3, agentd3-ui, agentd3-front, agentd3-swap
#                            (+ mnemnosd, mnemnosctl, mnemnos-ui, agentd-gauge
#                             when bundled for the platform)
#   <prefix>/go.mod          stub marker so the daemon resolves <prefix> as root
#   <prefix>/local/config.toml   created once, never overwritten
#   <prefix>/runtime/pi/     exact-lock Pi SDK runtime used by the Go daemon
#   <prefix>/local/omp/      retained unchanged when upgrading an OMP install
#   <prefix>/local/mnemnos.toml + mnemnos-ui.toml   Mnemos config (created once)
#   <prefix>/bin/agentd3-update  ZERO-DOWNTIME GitHub updater (the only entrypoint)
#   ~/.config/daz-secrets/provider.toml  private provider (bundled binary)
#   <prefix>/local/omp/      OMP broker runtime (bootstrapped; kept on upgrade)
#   Postgres (+pgvector)     installed/started if absent; fail closed otherwise
#   Services                 front (127.0.0.1:8620) + blue/green + gauge
#
# Usage:
#   curl -fsSL https://github.com/OWNER/REPO/releases/latest/download/install.sh | bash
#   ./install.sh [--prefix DIR] [--repo owner/name] [--no-service] [--from-updater]
set -euo pipefail

DEFAULT_REPO="boringstackai/agentd3"   # rewritten by publish.sh
PREFIX="$HOME/agentd3"
REPO="$DEFAULT_REPO"
NO_SERVICE=0
FROM_UPDATER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --repo)   REPO="$2"; shift 2 ;;
    --no-service) NO_SERVICE=1; shift ;;
    --from-updater) FROM_UPDATER=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux)  os=linux ;;
    *) fail "unsupported OS: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=amd64 ;;
    *) fail "unsupported arch: $(uname -m)" ;;
  esac
  echo "$os-$arch"
}

# ---------------------------------------------------------------- bootstrap --
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || true)"
if [ -z "${script_dir:-}" ] || [ ! -x "$script_dir/bin/agentd3" ]; then
  plat="$(platform)"
  url="https://github.com/$REPO/releases/latest/download/agentd3-$plat.tar.gz"
  say "bootstrap: downloading $url"
  workdir="$(mktemp -d /tmp/agentd3-install.XXXXXX)"
  trap 'rm -rf "$workdir"' EXIT
  curl -fSL --retry 3 -o "$workdir/release.tar.gz" "$url" \
    || fail "download failed — check that $REPO has a published release for $plat"
  tar -xzf "$workdir/release.tar.gz" -C "$workdir"
  extra=""
  [ "$NO_SERVICE" = 1 ] && extra="$extra --no-service"
  [ "$FROM_UPDATER" = 1 ] && extra="$extra --from-updater"
  # exec replaces this shell, so the EXIT trap does not fire and the extracted
  # tree survives for the inner installer (small deliberate /tmp leak).
  exec bash "$workdir/install.sh" --prefix "$PREFIX" --repo "$REPO" $extra
fi

# -------------------------------------------------------------- local install --
[ -f "$script_dir/MANIFEST" ] || fail "MANIFEST missing next to install.sh"
[ -f "$script_dir/lib.sh" ] || fail "lib.sh missing next to install.sh"
# shellcheck disable=SC1091
. "$script_dir/lib.sh"

# Upgrades never stop-the-world. The single entrypoint stages the idle color
# and flips the front after healthz attests the new build_sha.
if [ "$FROM_UPDATER" = 1 ]; then
  [ -x "$script_dir/bin/agentd3-update" ] || [ -x "$script_dir/agentd3-update" ] \
    || fail "agentd3-update missing from release tree"
  updater="$script_dir/bin/agentd3-update"
  [ -x "$updater" ] || updater="$script_dir/agentd3-update"
  exec bash "$updater" --prefix "$PREFIX" --repo "$REPO" --from-tarball "$script_dir"
fi

mkdir -p "$PREFIX/local/state"
acquire_install_lock "$PREFIX"
trap 'release_install_lock "$PREFIX"' EXIT

if [ -f "$PREFIX/local/config.toml" ] && [ -x "$PREFIX/bin/agentd3-front" ]; then
  updater="$script_dir/bin/agentd3-update"
  [ -x "$updater" ] || updater="$script_dir/agentd3-update"
  [ -x "$updater" ] || fail "agentd3-update missing from release tree"
  release_install_lock "$PREFIX"
  exec bash "$updater" --prefix "$PREFIX" --repo "$REPO" --from-tarball "$script_dir"
fi

manifest_get() { grep -m1 "^$1=" "$script_dir/MANIFEST" | cut -d= -f2-; }
PI_VERSION="$(manifest_get PI_VERSION)"
SOURCE_SHA="$(manifest_get SOURCE_SHA)"
OMP_VERSION="$(manifest_get OMP_VERSION)"
[ -n "$PI_VERSION" ] && [ -n "$SOURCE_SHA" ] || fail "MANIFEST incomplete"
[ -n "$OMP_VERSION" ] || fail "MANIFEST missing OMP_VERSION"
HAVE_MNEMNOS=0
[ -x "$script_dir/bin/mnemnosd" ] && HAVE_MNEMNOS=1
HAVE_GAUGE=0
[ -x "$script_dir/bin/agentd-gauge" ] && HAVE_GAUGE=1
[ -x "$script_dir/bin/daz-secrets-provider-private" ] \
  || fail "release is missing daz-secrets-provider-private; refusing to install"

OS="$(uname -s)"
say "installing agentd3 (source $SOURCE_SHA, Pi $PI_VERSION) into $PREFIX"
if [ -f "$PREFIX/local/config.toml" ]; then
  fresh_store_install=0
else
  fresh_store_install=1
fi

# --- dependencies ------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# libpq tries GSSAPI before it tries the authentication the server actually
# asks for. On macOS every login gets a local-KDC ticket cache, and once those
# tickets expire EVERY psql/createdb call dies with "could not initiate GSSAPI
# security context … Ticket expired" — against a local trust-auth server that
# was never going to speak Kerberos. Live 2026-09-16: that killed a greenline
# release at the database-preparation step. Disable the negotiation outright:
# this installer only ever talks to 127.0.0.1.
export PGGSSENCMODE=disable

postgres_scalar() {
  psql -h 127.0.0.1 -p 5432 -d postgres -tAXc "$1"
}

ensure_postgres_database() {
  local database="$1" exists
  exists="$(postgres_scalar "SELECT 1 FROM pg_database WHERE datname='$database'")" \
    || fail "cannot inspect PostgreSQL database $database"
  if [ "$exists" != 1 ]; then
    say "creating PostgreSQL database $database"
    createdb -h 127.0.0.1 -p 5432 "$database" \
      || fail "failed to create PostgreSQL database $database"
  fi
  [ "$(postgres_scalar "SELECT 1 FROM pg_database WHERE datname='$database'")" = 1 ] \
    || fail "PostgreSQL database $database is still absent after setup"
}

configured_postgres_scalar() {
  psql "$configured_postgres_dsn" -tAXc "$1"
}

require_configured_postgres_database() {
  local database="$1" exists
  exists="$(configured_postgres_scalar "SELECT 1 FROM pg_database WHERE datname='$database'")" \
    || fail "cannot inspect PostgreSQL database $database on the configured authoritative cluster"
  [ "$exists" = 1 ] \
    || fail "PostgreSQL database $database is absent on the configured authoritative cluster; refusing to create it during an update"
}

config_store_value() {
  awk -v wanted="$1" '
    /^\[.*\]$/ { section=$0; next }
    section == "[store]" && $0 ~ "^[[:space:]]*" wanted "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, "")
      gsub(/^["\047]|["\047]$/, "")
      print
      exit
    }
  ' "$PREFIX/local/config.toml"
}

if [ "$OS" = Darwin ]; then
  if ! have brew; then
    fail "Homebrew is required on macOS. Install it first:
  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
then re-run this installer."
  fi
  if [ "$fresh_store_install" = 1 ] && ! pg_isready -h 127.0.0.1 -p 5432 -q 2>/dev/null; then
    say "Postgres not running — installing postgresql@17 via Homebrew"
    brew list postgresql@17 >/dev/null 2>&1 || brew install postgresql@17
    brew services start postgresql@17
    # postgresql@17 is keg-only; make its CLI tools reachable for this shell.
    PATH="$(brew --prefix postgresql@17)/bin:$PATH"
    for i in $(seq 1 30); do pg_isready -h 127.0.0.1 -p 5432 -q && break; sleep 1; done
    pg_isready -h 127.0.0.1 -p 5432 -q || fail "Postgres did not become ready"
  fi
  if [ "$fresh_store_install" = 0 ] && ! have psql; then
    for postgres_formula in postgresql@18 postgresql@17; do
      if brew list "$postgres_formula" >/dev/null 2>&1; then
        PATH="$(brew --prefix "$postgres_formula")/bin:$PATH"
        break
      fi
    done
  fi
  if [ "$fresh_store_install" = 0 ] && ! have psql; then
    fail "psql is required to attest the existing authoritative PostgreSQL store; refusing to install or start another server"
  fi
  if ! have npm; then
    say "npm missing — installing node via Homebrew"
    brew install node
  fi
  if [ "$HAVE_MNEMNOS" = 1 ] && ! brew list pgvector >/dev/null 2>&1; then
    say "installing pgvector (Mnemos vector index) via Homebrew"
    brew install pgvector
  fi
elif [ "$OS" = Linux ]; then
  if [ "$fresh_store_install" = 1 ] && ! pg_isready -h 127.0.0.1 -p 5432 -q 2>/dev/null; then
    say "Postgres not running — installing via apt (needs sudo)"
    sudo apt-get update -qq && sudo apt-get install -y -qq postgresql
    sudo systemctl enable --now postgresql
    for i in $(seq 1 30); do pg_isready -h 127.0.0.1 -p 5432 -q && break; sleep 1; done
    pg_isready -h 127.0.0.1 -p 5432 -q || fail "Postgres did not become ready"
  fi
  if [ "$fresh_store_install" = 0 ] && ! have psql; then
    fail "psql is required to attest the existing authoritative PostgreSQL store; refusing to install or start another server"
  fi
  if [ "$fresh_store_install" = 1 ]; then
    # The daemon connects as the current OS user. Role/database creation is
    # confined to explicit first-install bootstrap.
    sudo -u postgres createuser -s "$USER" 2>/dev/null || true
  fi
  if ! have npm; then
    say "npm missing — installing nodejs via apt (needs sudo)"
    sudo apt-get install -y -qq nodejs npm
  fi
  if [ "$HAVE_MNEMNOS" = 1 ]; then
    pg_major="$(psql -h 127.0.0.1 -p 5432 -d postgres -tAc 'show server_version' 2>/dev/null | cut -d. -f1 || true)"
    if [ -n "$pg_major" ]; then
      sudo apt-get install -y -qq "postgresql-$pg_major-pgvector" || \
        echo "WARNING: could not install postgresql-$pg_major-pgvector; Mnemos will fail its vector migration" >&2
    fi
  fi
else
  fail "unsupported OS: $OS"
fi
postgres_fail_closed_if_unready 127.0.0.1 5432

# --- layout + binaries ---------------------------------------------------------
mkdir -p "$PREFIX/bin" "$PREFIX/runtime" "$PREFIX/local/state" "$PREFIX/local/pi/runtime-backups"

# The daemon walks up from its cwd looking for go.mod to find its root.
[ -f "$PREFIX/go.mod" ] || printf 'module agentd3-runtime\n' > "$PREFIX/go.mod"

if [ ! -f "$PREFIX/local/config.toml" ]; then
  # Fresh-machine bootstrap is the only installer path allowed to create
  # databases. There is no prior authoritative identity to preserve yet.
  ensure_postgres_database agentd3
  postgres_identity="$(postgres_scalar "SELECT (pg_control_system()).system_identifier::text || '|' || current_setting('data_directory')")" \
    || fail "cannot read PostgreSQL authoritative-store identity"
  postgres_system_identifier="${postgres_identity%%|*}"
  postgres_data_directory="${postgres_identity#*|}"
  [ -n "$postgres_system_identifier" ] && [ -n "$postgres_data_directory" ] \
    || fail "PostgreSQL returned an incomplete authoritative-store identity"
  cat > "$PREFIX/local/config.toml" <<EOF
# agentd3 machine-local configuration. Never overwritten by the installer.

[store]
# This exact DSN and server identity are required. The daemon fails closed on
# any missing value or mismatch and never creates or selects another database.
postgres_dsn = "postgres://$USER@127.0.0.1:5432/agentd3?sslmode=disable"
postgres_system_identifier = "$postgres_system_identifier"
postgres_data_directory = "$postgres_data_directory"

[provider_auth]
# Google Cloud project ID used by the Gemini OAuth flow (optional).
# google_cloud_project = ""

[catalog]
# Optional local Ollama endpoint. When set, model discovery, auto-titling, and
# outcome summarization use it; when absent, those features stay silently
# degraded (they are never required for normal operation).
# ollama_host = "http://127.0.0.1:11434"

[ui]
# Default: start agentd-gauge with the daemon (one gauge per machine).
launch_gauges_on_start = true

# [relay] — device-pairing relay is OFF by default on this machine. Pairing
# endpoints stay disabled unless YOU opt in by adding your own relay here:
# [relay]
# base_url = <the origin of a relay you run yourself>
# No relay origin — not even an example one — is written by this installer.
EOF
else
  # Updates must attest the existing store before making any database change.
  # A different server at the same address is an outage, never a fresh install.
  configured_postgres_dsn="$(config_store_value postgres_dsn)"
  expected_postgres_system_identifier="$(config_store_value postgres_system_identifier)"
  expected_postgres_data_directory="$(config_store_value postgres_data_directory)"
  [ -n "$configured_postgres_dsn" ] \
    || fail "existing local/config.toml must explicitly set [store] postgres_dsn"
  [ -n "$expected_postgres_system_identifier" ] \
    || fail "existing local/config.toml must explicitly set [store] postgres_system_identifier"
  [ -n "$expected_postgres_data_directory" ] \
    || fail "existing local/config.toml must explicitly set [store] postgres_data_directory"
  actual_postgres_identity="$(configured_postgres_scalar "SELECT current_database() || '|' || (pg_control_system()).system_identifier::text || '|' || current_setting('data_directory')")" \
    || fail "cannot connect to the configured authoritative PostgreSQL store"
  actual_postgres_database="${actual_postgres_identity%%|*}"
  actual_postgres_remainder="${actual_postgres_identity#*|}"
  actual_postgres_system_identifier="${actual_postgres_remainder%%|*}"
  actual_postgres_data_directory="${actual_postgres_remainder#*|}"
  [ "$actual_postgres_database" = agentd3 ] \
    || fail "configured PostgreSQL database is $actual_postgres_database, expected agentd3"
  [ "$actual_postgres_system_identifier" = "$expected_postgres_system_identifier" ] \
    || fail "configured PostgreSQL system identifier does not match the authoritative store"
  [ "$actual_postgres_data_directory" = "$expected_postgres_data_directory" ] \
    || fail "configured PostgreSQL data directory does not match the authoritative store"
fi

# Stage-then-rename so a running daemon's binary is never truncated in place.
stack_bins="agentd3 agentd3-ui agentd3-front agentd3-swap"
[ "$HAVE_MNEMNOS" = 1 ] && stack_bins="$stack_bins mnemnosd mnemnosctl mnemnos-ui"
[ "$HAVE_GAUGE" = 1 ] && stack_bins="$stack_bins agentd-gauge"
for b in $stack_bins; do
  stage_then_mv "$script_dir/bin/$b" "$PREFIX/bin/$b"
done
stage_then_mv "$script_dir/bin/agentd3" "$PREFIX/bin/agentd3.blue"
stage_then_mv "$script_dir/bin/agentd3" "$PREFIX/bin/agentd3.green"
stage_then_mv "$script_dir/bin/agentd3-ui" "$PREFIX/bin/agentd3-ui.blue"
stage_then_mv "$script_dir/bin/agentd3-ui" "$PREFIX/bin/agentd3-ui.green"
if [ -x "$script_dir/bin/agentd3-update" ]; then
  stage_then_mv "$script_dir/bin/agentd3-update" "$PREFIX/bin/agentd3-update"
elif [ -x "$script_dir/agentd3-update" ]; then
  stage_then_mv "$script_dir/agentd3-update" "$PREFIX/bin/agentd3-update"
else
  fail "agentd3-update missing from release tree"
fi
cp "$script_dir/lib.sh" "$PREFIX/lib.sh"
chmod +x "$PREFIX/bin/agentd3-update"
# --- exact Pi SDK runtime ------------------------------------------------------
node -e 'if (Number(process.versions.node.split(".")[0]) < 22) process.exit(1)' \
  || fail "Pi SDK requires Node.js 22 or newer"
pi_stage="$(mktemp -d "$PREFIX/local/pi/runtime-stage.XXXXXXXX")"
cp -R "$script_dir/runtime/pi/." "$pi_stage/"
rm -rf "$pi_stage/node_modules" "$pi_stage/node_modules.next"
npm --prefix "$pi_stage" ci --ignore-scripts --no-audit --no-fund --loglevel=error \
  || fail "Pi SDK exact-lock installation failed"
installed_pi="$(node -e 'process.stdout.write(require(process.argv[1]).version)' \
  "$pi_stage/node_modules/@earendil-works/pi-coding-agent/package.json")"
[ "$installed_pi" = "$PI_VERSION" ] \
  || fail "installed Pi SDK $installed_pi does not match manifest $PI_VERSION"
if [ -d "$PREFIX/runtime/pi" ]; then
  backup="$(mktemp -d "$PREFIX/local/pi/runtime-backups/$(date -u +%Y%m%dT%H%M%SZ)-$SOURCE_SHA.XXXXXXXX")"
  rmdir "$backup"
  mv "$PREFIX/runtime/pi" "$backup"
fi
mv "$pi_stage" "$PREFIX/runtime/pi"

install_daz_secrets_stack "$script_dir"
bootstrap_omp "$PREFIX" "$script_dir" "$OMP_VERSION"

# --- Mnemos memory system (when bundled for this platform) ---------------------
if [ "$HAVE_MNEMNOS" = 1 ]; then
  if [ ! -f "$PREFIX/local/mnemnos.toml" ]; then
    cat > "$PREFIX/local/mnemnos.toml" <<EOF
[server]
bind = "127.0.0.1:8432"

[postgres]
dsn = "postgres://$USER@127.0.0.1:5432/mnemnos?sslmode=disable"
EOF
  fi
  if [ ! -f "$PREFIX/local/mnemnos-ui.toml" ]; then
    cat > "$PREFIX/local/mnemnos-ui.toml" <<EOF
bind = "127.0.0.1:8433"
mnemnos_url = "http://127.0.0.1:8432"
EOF
  fi
  # mnemnosd migrates its schema itself but never creates its database. Only a
  # fresh bootstrap may create it; updates merely attest its continued presence.
  if [ "$fresh_store_install" = 1 ]; then
    ensure_postgres_database mnemnos
  else
    require_configured_postgres_database mnemnos
  fi
fi

# --- record installed versions (updater binary already staged) -----------------
cp "$script_dir/MANIFEST" "$PREFIX/MANIFEST"
atomic_require_runtime "$PREFIX"
write_active_json "$PREFIX/local/front/active.json" blue true

# --- services -------------------------------------------------------------------
LAUNCH_GAUGES="$(config_has_launch_gauges "$PREFIX/local/config.toml")"
if [ "$NO_SERVICE" = 1 ]; then
  say "skipping service setup (--no-service). Run manually:"
  echo "  cd $PREFIX && ./bin/agentd3-front --daemon-listen 127.0.0.1:8620 --ui-listen 127.0.0.1:8621"
  echo "  cd $PREFIX && ./bin/agentd3.blue serve -addr 127.0.0.1:8630"
  echo "  cd $PREFIX && ./bin/agentd3-ui.blue -addr 127.0.0.1:8640 -api http://127.0.0.1:8620"
  if [ "$HAVE_MNEMNOS" = 1 ]; then
    echo "  cd $PREFIX && ./bin/mnemnosd --config local/mnemnos.toml"
    echo "  cd $PREFIX && ./bin/mnemnos-ui --config local/mnemnos-ui.toml"
  fi
  if [ "$HAVE_GAUGE" = 1 ]; then
    echo "  cd $PREFIX && ./bin/agentd-gauge"
  fi
else
  if [ "$OS" = Darwin ]; then
    la="$HOME/Library/LaunchAgents"
    mkdir -p "$la"
    service_path="$(service_path_value)"
    write_plist() { # label, program...
      local label="$1"; shift
      local args=""
      for a in "$@"; do args="$args<string>$a</string>"; done
      cat > "$la/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>$args</array>
  <key>WorkingDirectory</key><string>$PREFIX</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$service_path</string></dict>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$PREFIX/local/state/$label.log</string>
  <key>StandardErrorPath</key><string>$PREFIX/local/state/$label.log</string>
</dict></plist>
EOF
      launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$la/$label.plist"
    }
    say "installing launchd agents (front 127.0.0.1:8620 + blue/green)"
    if [ "$HAVE_MNEMNOS" = 1 ]; then
      write_plist com.boringstack.mnemnos "$PREFIX/bin/mnemnosd" --config "$PREFIX/local/mnemnos.toml"
      write_plist com.boringstack.mnemnos-ui "$PREFIX/bin/mnemnos-ui" --config "$PREFIX/local/mnemnos-ui.toml"
    fi
    write_plist com.boringstack.agentd3-front "$PREFIX/bin/agentd3-front" \
      --daemon-listen 127.0.0.1:8620 --ui-listen 127.0.0.1:8621 \
      --state "$PREFIX/local/front/active.json"
    write_plist com.boringstack.agentd3-blue "$PREFIX/bin/agentd3.blue" serve -addr 127.0.0.1:8630
    write_plist com.boringstack.agentd3-green "$PREFIX/bin/agentd3.green" serve -addr 127.0.0.1:8631 -standby
    write_plist com.boringstack.agentd3-ui-blue "$PREFIX/bin/agentd3-ui.blue" -addr 127.0.0.1:8640 -api http://127.0.0.1:8620
    write_plist com.boringstack.agentd3-ui-green "$PREFIX/bin/agentd3-ui.green" -addr 127.0.0.1:8641 -api http://127.0.0.1:8620
    if [ "$HAVE_GAUGE" = 1 ] && [ "$LAUNCH_GAUGES" != "false" ]; then
      write_plist com.boringstack.agentd-gauge "$PREFIX/bin/agentd-gauge"
    fi
    # Daily 04:30 update check. Never (re)bootstrapped from inside an updater
    # run — launchctl bootout of this label would kill the running update.
    if [ "$FROM_UPDATER" = 0 ]; then
      cat > "$la/com.boringstack.agentd3-update.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.boringstack.agentd3-update</string>
  <key>ProgramArguments</key><array><string>$PREFIX/bin/agentd3-update</string></array>
  <key>WorkingDirectory</key><string>$PREFIX</string>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>30</integer></dict>
  <key>StandardOutPath</key><string>$PREFIX/local/state/update.log</string>
  <key>StandardErrorPath</key><string>$PREFIX/local/state/update.log</string>
</dict></plist>
EOF
      launchctl bootout "gui/$(id -u)/com.boringstack.agentd3-update" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$la/com.boringstack.agentd3-update.plist"
    fi
  else
    sd="$HOME/.config/systemd/user"
    mkdir -p "$sd"
    cat > "$sd/agentd3-front.service" <<EOF
[Unit]
Description=agentd3 front proxy (127.0.0.1:8620)
After=network.target
[Service]
WorkingDirectory=$PREFIX
ExecStart=$PREFIX/bin/agentd3-front --daemon-listen 127.0.0.1:8620 --ui-listen 127.0.0.1:8621 --state $PREFIX/local/front/active.json
Restart=always
RestartSec=2
[Install]
WantedBy=default.target
EOF
    cat > "$sd/agentd3-blue.service" <<EOF
[Unit]
Description=agentd3 daemon blue
After=network.target
[Service]
WorkingDirectory=$PREFIX
ExecStart=$PREFIX/bin/agentd3.blue serve -addr 127.0.0.1:8630
Restart=always
RestartSec=2
[Install]
WantedBy=default.target
EOF
    cat > "$sd/agentd3-green.service" <<EOF
[Unit]
Description=agentd3 daemon green (standby)
After=network.target
[Service]
WorkingDirectory=$PREFIX
ExecStart=$PREFIX/bin/agentd3.green serve -addr 127.0.0.1:8631 -standby
Restart=always
RestartSec=2
[Install]
WantedBy=default.target
EOF
    cat > "$sd/agentd3-ui-blue.service" <<EOF
[Unit]
Description=agentd3 UI blue
After=network.target
[Service]
WorkingDirectory=$PREFIX
ExecStart=$PREFIX/bin/agentd3-ui.blue -addr 127.0.0.1:8640 -api http://127.0.0.1:8620
Restart=always
RestartSec=2
[Install]
WantedBy=default.target
EOF
    cat > "$sd/agentd3-ui-green.service" <<EOF
[Unit]
Description=agentd3 UI green
After=network.target
[Service]
WorkingDirectory=$PREFIX
ExecStart=$PREFIX/bin/agentd3-ui.green -addr 127.0.0.1:8641 -api http://127.0.0.1:8620
Restart=always
RestartSec=2
[Install]
WantedBy=default.target
EOF
    if [ "$HAVE_GAUGE" = 1 ]; then
      cat > "$sd/agentd-gauge.service" <<EOF
[Unit]
Description=agentd-gauge
After=network.target
[Service]
WorkingDirectory=$PREFIX
ExecStart=$PREFIX/bin/agentd-gauge
Restart=always
RestartSec=2
[Install]
WantedBy=default.target
EOF
    fi
    if [ "$HAVE_MNEMNOS" = 1 ]; then
      cat > "$sd/mnemnos.service" <<EOF
[Unit]
Description=Mnemos memory daemon
After=network.target
[Service]
WorkingDirectory=$PREFIX
ExecStart=$PREFIX/bin/mnemnosd --config $PREFIX/local/mnemnos.toml
Restart=always
RestartSec=2
[Install]
WantedBy=default.target
EOF
      cat > "$sd/mnemnos-ui.service" <<EOF
[Unit]
Description=Mnemos UI
After=network.target
[Service]
WorkingDirectory=$PREFIX
ExecStart=$PREFIX/bin/mnemnos-ui --config $PREFIX/local/mnemnos-ui.toml
Restart=always
RestartSec=2
[Install]
WantedBy=default.target
EOF
    fi
    cat > "$sd/agentd3-update.service" <<EOF
[Unit]
Description=agentd3 stack auto-update
[Service]
Type=oneshot
WorkingDirectory=$PREFIX
ExecStart=$PREFIX/bin/agentd3-update
EOF
    cat > "$sd/agentd3-update.timer" <<EOF
[Unit]
Description=Daily agentd3 stack update check
[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
    say "installing systemd user units (front 127.0.0.1:8620 + blue/green)"
    systemctl --user daemon-reload
    if [ "$HAVE_MNEMNOS" = 1 ]; then
      systemctl --user enable --now mnemnos.service mnemnos-ui.service
    fi
    systemctl --user enable --now agentd3-front.service agentd3-blue.service agentd3-green.service \
      agentd3-ui-blue.service agentd3-ui-green.service
    if [ "$HAVE_GAUGE" = 1 ] && [ "$LAUNCH_GAUGES" != "false" ]; then
      systemctl --user enable --now agentd-gauge.service
    fi
    systemctl --user enable --now agentd3-update.timer
    loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes' || \
      echo "NOTE: run 'sudo loginctl enable-linger $USER' so services survive logout."
  fi

  say "waiting for daemon health on 127.0.0.1:8620 (build_sha $SOURCE_SHA)"
  wait_healthz_sha "http://127.0.0.1:8620/healthz" "$SOURCE_SHA" 30
  say "agentd3 is up: API http://127.0.0.1:8620  UI http://127.0.0.1:8621"
  if [ "$HAVE_MNEMNOS" = 1 ]; then
    say "waiting for Mnemos health on 127.0.0.1:8432"
    m_healthy=0
    for i in $(seq 1 30); do
      if curl -sf --max-time 2 http://127.0.0.1:8432/healthz >/dev/null 2>&1; then m_healthy=1; break; fi
      sleep 2
    done
    if [ "$m_healthy" = 1 ]; then
      say "Mnemos is up: API http://127.0.0.1:8432  UI http://127.0.0.1:8433"
    else
      fail "mnemnosd did not become healthy in 60s — check $PREFIX/local/state/*.log (pgvector installed? database created?)"
    fi
  fi
fi

say "done. Next steps:"
cat <<EOF
  1. Log in: open the UI at http://127.0.0.1:8621 and use the provider
     controls to authenticate your OMP/Pi account (the bundled local broker
     at $PREFIX/local/omp runs the OAuth flow). At least one provider login
     is needed before turns can run. Credentials persist through the
     configured daz-secrets provider and are never stored in runtime files.
  2. Open the UI:   http://127.0.0.1:8621   (Mnemos UI: http://127.0.0.1:8433)
  3. Config lives in $PREFIX/local/config.toml (DSN, optional settings).
  4. Zero-downtime updates: $PREFIX/bin/agentd3-update (daily 04:30). That is
     the only updater. It stages the idle color and flips the loopback front.
EOF
