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
#   <prefix>/local/bun/      pinned bun runtime (drives the omp engine)
#   <prefix>/local/omp/      pinned @oh-my-pi/pi-coding-agent + current symlink
#   <prefix>/local/mnemnos.toml + mnemnos-ui.toml   Mnemos config (created once)
#   <prefix>/bin/agentd3-update  auto-updater + daily 04:30 schedule
#   Postgres (+pgvector)     installed/started if absent
#   Services                 launchd agents (macOS) / systemd user units (Linux)
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
manifest_get() { grep -m1 "^$1=" "$script_dir/MANIFEST" | cut -d= -f2-; }
OMP_VERSION="$(manifest_get OMP_VERSION)"
BUN_VERSION="$(manifest_get BUN_VERSION)"
SOURCE_SHA="$(manifest_get SOURCE_SHA)"
[ -n "$OMP_VERSION" ] && [ -n "$BUN_VERSION" ] || fail "MANIFEST incomplete"
HAVE_MNEMNOS=0
[ -x "$script_dir/bin/mnemnosd" ] && HAVE_MNEMNOS=1
HAVE_GAUGE=0
[ -x "$script_dir/bin/agentd-gauge" ] && HAVE_GAUGE=1

OS="$(uname -s)"
say "installing agentd3 (source $SOURCE_SHA, omp $OMP_VERSION, bun $BUN_VERSION) into $PREFIX"

# --- dependencies ------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

if [ "$OS" = Darwin ]; then
  if ! have brew; then
    fail "Homebrew is required on macOS. Install it first:
  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
then re-run this installer."
  fi
  if ! pg_isready -h 127.0.0.1 -p 5432 -q 2>/dev/null; then
    say "Postgres not running — installing postgresql@17 via Homebrew"
    brew list postgresql@17 >/dev/null 2>&1 || brew install postgresql@17
    brew services start postgresql@17
    # postgresql@17 is keg-only; make its CLI tools reachable for this shell.
    PATH="$(brew --prefix postgresql@17)/bin:$PATH"
    for i in $(seq 1 30); do pg_isready -h 127.0.0.1 -p 5432 -q && break; sleep 1; done
    pg_isready -h 127.0.0.1 -p 5432 -q || fail "Postgres did not become ready"
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
  if ! pg_isready -h 127.0.0.1 -p 5432 -q 2>/dev/null; then
    say "Postgres not running — installing via apt (needs sudo)"
    sudo apt-get update -qq && sudo apt-get install -y -qq postgresql
    sudo systemctl enable --now postgresql
    for i in $(seq 1 30); do pg_isready -h 127.0.0.1 -p 5432 -q && break; sleep 1; done
    pg_isready -h 127.0.0.1 -p 5432 -q || fail "Postgres did not become ready"
    # The daemon connects as the current OS user; give it a superuser role so it
    # can create its own database (macOS/Homebrew grants this by default).
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

# --- layout + binaries ---------------------------------------------------------
mkdir -p "$PREFIX/bin" "$PREFIX/local/state" "$PREFIX/local/omp/versions" \
         "$PREFIX/local/omp/state" "$PREFIX/local/omp/workdir"

# The daemon walks up from its cwd looking for go.mod to find its root.
[ -f "$PREFIX/go.mod" ] || printf 'module agentd3-runtime\n' > "$PREFIX/go.mod"

if [ ! -f "$PREFIX/local/config.toml" ]; then
  cat > "$PREFIX/local/config.toml" <<'EOF'
# agentd3 machine-local configuration. Never overwritten by the installer.

[store]
# Postgres DSN. Empty/absent = postgres://<os-user>@127.0.0.1:5432/agentd3
# postgres_dsn = ""

[provider_auth]
# Google Cloud project ID used by the Gemini OAuth flow (optional).
# google_cloud_project = ""

[catalog]
# Optional local Ollama endpoint. When set, model discovery, auto-titling, and
# outcome polish use it; when absent, those features stay silently degraded
# (they are never required for normal operation).
# ollama_host = "http://127.0.0.1:11434"
EOF
fi

# Stage-then-rename so a running daemon's binary is never truncated in place.
stack_bins="agentd3 agentd3-ui agentd3-front agentd3-swap"
[ "$HAVE_MNEMNOS" = 1 ] && stack_bins="$stack_bins mnemnosd mnemnosctl mnemnos-ui"
[ "$HAVE_GAUGE" = 1 ] && stack_bins="$stack_bins agentd-gauge"
for b in $stack_bins; do
  cp "$script_dir/bin/$b" "$PREFIX/bin/.$b.new"
  chmod +x "$PREFIX/bin/.$b.new"
  mv -f "$PREFIX/bin/.$b.new" "$PREFIX/bin/$b"
done
if [ "$OS" = Darwin ]; then
  # macOS SIGKILLs binaries whose signature does not validate after copying.
  for b in $stack_bins; do
    codesign --force -s - "$PREFIX/bin/$b" 2>/dev/null || true
  done
fi

# --- bun runtime (drives the omp engine) --------------------------------------
if [ ! -x "$PREFIX/local/bun/bin/bun" ] || \
   [ "$("$PREFIX/local/bun/bin/bun" --version 2>/dev/null)" != "$BUN_VERSION" ]; then
  say "installing bun $BUN_VERSION into $PREFIX/local/bun"
  curl -fsSL https://bun.sh/install | BUN_INSTALL="$PREFIX/local/bun" bash -s -- "bun-v$BUN_VERSION" >/dev/null
  [ -x "$PREFIX/local/bun/bin/bun" ] || fail "bun install failed"
fi

# --- pinned oh-my-pi engine ----------------------------------------------------
# NOTE: the real package is @oh-my-pi/pi-coding-agent — bare "oh-my-pi" on npm
# is an unrelated project.
version_dir="$PREFIX/local/omp/versions/$OMP_VERSION"
if [ ! -x "$version_dir/omp" ]; then
  say "installing @oh-my-pi/pi-coding-agent@$OMP_VERSION"
  mkdir -p "$version_dir"
  npm install --prefix "$version_dir" "@oh-my-pi/pi-coding-agent@$OMP_VERSION" >/dev/null
  cat > "$version_dir/omp" <<'EOF'
#!/usr/bin/env bash
# omp launcher. Resolves its own physical directory (pwd -P) so it works when
# invoked directly or via the local/omp/current symlink. Uses the locally-installed
# bun runtime and the pinned @oh-my-pi/pi-coding-agent package. No env vars required.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BUN_BIN="$DIR/../../../bun/bin/bun"
exec "$BUN_BIN" "$DIR/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js" "$@"
EOF
  chmod +x "$version_dir/omp"
fi
rm -f "$PREFIX/local/omp/current"
ln -s "versions/$OMP_VERSION" "$PREFIX/local/omp/current"
"$PREFIX/local/omp/current/omp" --version >/dev/null 2>&1 || \
  fail "omp engine smoke test failed ($PREFIX/local/omp/current/omp --version)"

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
  # mnemnosd migrates its schema itself but does not create its database.
  if have createdb || { have brew && PATH="$(brew --prefix postgresql@17 2>/dev/null)/bin:$PATH" && have createdb; }; then
    createdb -h 127.0.0.1 -p 5432 mnemnos 2>/dev/null || true
  else
    echo "WARNING: createdb not found; create the 'mnemnos' database manually" >&2
  fi
fi

# --- record installed versions + write the auto-updater --------------------------
cp "$script_dir/MANIFEST" "$PREFIX/MANIFEST"
cat > "$PREFIX/bin/agentd3-update" <<EOF
#!/usr/bin/env bash
# agentd3 stack auto-updater — written by install.sh; rewritten on every update.
# Compares the latest release's VERSION asset against the installed MANIFEST and
# re-runs the (freshly downloaded) installer when anything changed.
set -euo pipefail
PREFIX="$PREFIX"
REPO="$REPO"
EOF
cat >> "$PREFIX/bin/agentd3-update" <<'EOF'
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] update check ($REPO)"
remote="$(curl -fsSL --retry 3 "https://github.com/$REPO/releases/latest/download/VERSION")" || {
  echo "update check failed: cannot fetch VERSION" >&2; exit 1; }
changed=0
for k in SOURCE_SHA OMP_VERSION BUN_VERSION MNEMNOS_SHA GAUGE_SHA; do
  want="$(printf '%s\n' "$remote" | grep -m1 "^$k=" | cut -d= -f2- || true)"
  got="$(grep -m1 "^$k=" "$PREFIX/MANIFEST" 2>/dev/null | cut -d= -f2- || true)"
  if [ "$want" != "$got" ]; then
    echo "  $k: $got -> $want"
    changed=1
  fi
done
if [ "$changed" = 0 ]; then
  echo "up to date."
  exit 0
fi
echo "updating..."
tmp="$(mktemp -d /tmp/agentd3-update.XXXXXX)"
curl -fsSL --retry 3 -o "$tmp/install.sh" \
  "https://github.com/$REPO/releases/latest/download/install.sh"
exec bash "$tmp/install.sh" --prefix "$PREFIX" --repo "$REPO" --from-updater
EOF
chmod +x "$PREFIX/bin/agentd3-update"

# --- services -------------------------------------------------------------------
if [ "$NO_SERVICE" = 1 ]; then
  say "skipping service setup (--no-service). Run manually:"
  echo "  cd $PREFIX && ./bin/agentd3 serve"
  echo "  cd $PREFIX && ./bin/agentd3-ui"
  if [ "$HAVE_MNEMNOS" = 1 ]; then
    echo "  cd $PREFIX && ./bin/mnemnosd --config local/mnemnos.toml"
    echo "  cd $PREFIX && ./bin/mnemnos-ui --config local/mnemnos-ui.toml"
  fi
  if [ "$HAVE_GAUGE" = 1 ]; then
    echo "  cd $PREFIX && ./bin/agentd-gauge   # macOS dock usage gauge"
  fi
else
  if [ "$OS" = Darwin ]; then
    la="$HOME/Library/LaunchAgents"
    mkdir -p "$la"
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
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$PREFIX/local/state/$label.log</string>
  <key>StandardErrorPath</key><string>$PREFIX/local/state/$label.log</string>
</dict></plist>
EOF
      launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$la/$label.plist"
    }
    say "installing launchd agents"
    # Mnemos first: agentd3's brain features probe it at startup.
    if [ "$HAVE_MNEMNOS" = 1 ]; then
      write_plist com.boringstack.mnemnos "$PREFIX/bin/mnemnosd" --config "$PREFIX/local/mnemnos.toml"
      write_plist com.boringstack.mnemnos-ui "$PREFIX/bin/mnemnos-ui" --config "$PREFIX/local/mnemnos-ui.toml"
    fi
    write_plist com.boringstack.agentd3 "$PREFIX/bin/agentd3" serve
    write_plist com.boringstack.agentd3-ui "$PREFIX/bin/agentd3-ui"
    # agentd-gauge is a Dock GUI app; it retries until agentd3's usage feed is up.
    if [ "$HAVE_GAUGE" = 1 ]; then
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
    cat > "$sd/agentd3.service" <<EOF
[Unit]
Description=agentd3 daemon
After=network.target
[Service]
WorkingDirectory=$PREFIX
ExecStart=$PREFIX/bin/agentd3 serve
Restart=always
RestartSec=2
[Install]
WantedBy=default.target
EOF
    cat > "$sd/agentd3-ui.service" <<EOF
[Unit]
Description=agentd3 UI
After=network.target
[Service]
WorkingDirectory=$PREFIX
ExecStart=$PREFIX/bin/agentd3-ui
Restart=always
RestartSec=2
[Install]
WantedBy=default.target
EOF
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
    say "installing systemd user units"
    systemctl --user daemon-reload
    if [ "$HAVE_MNEMNOS" = 1 ]; then
      systemctl --user enable --now mnemnos.service mnemnos-ui.service
    fi
    systemctl --user enable --now agentd3.service agentd3-ui.service
    systemctl --user enable --now agentd3-update.timer
    loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes' || \
      echo "NOTE: run 'sudo loginctl enable-linger $USER' so services survive logout."
  fi

  say "waiting for daemon health on 127.0.0.1:8620"
  healthy=0
  for i in $(seq 1 30); do
    if curl -sf --max-time 2 http://127.0.0.1:8620/healthz >/dev/null 2>&1; then healthy=1; break; fi
    sleep 2
  done
  if [ "$healthy" = 1 ]; then
    say "agentd3 is up: API http://127.0.0.1:8620  UI http://127.0.0.1:8621"
  else
    fail "daemon did not become healthy in 60s — check $PREFIX/local/state/*.log"
  fi
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
  1. Provider auth (at least one provider is needed to run turns):
       cd $PREFIX && ./bin/agentd3 omp auth login <provider>
     (OAuth providers: claude, openai/codex, grok, ...; API-key providers can
      instead store keys in the OS keychain, e.g.: keyring set glm api_key)
  2. Open the UI:   http://127.0.0.1:8621   (Mnemos UI: http://127.0.0.1:8433)
  3. Config lives in $PREFIX/local/config.toml (DSN, optional settings).
  4. Updates are automatic (daily 04:30 via bin/agentd3-update); run
     $PREFIX/bin/agentd3-update any time to update immediately. Config and
     state are always preserved.
EOF
