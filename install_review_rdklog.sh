#!/usr/bin/env bash
#
# Review LogFiles installer / updater.
#
# Works standalone (clones the repo itself) or from inside an existing checkout:
#   curl -fsSL https://raw.githubusercontent.com/udaybhadauria/Review_LogFiles/main/install_review_rdklog.sh | bash
#   curl -fsSL .../install_review_rdklog.sh | bash -s -- --dir /opt/review_logfiles --port 8443
#   ./install_review_rdklog.sh --no-service
#
# Re-running the script is safe: it updates the code, dependencies and service in place.
set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/udaybhadauria/Review_LogFiles.git}"
BRANCH="${BRANCH:-main}"
PROJECT_DIR="${PROJECT_DIR:-$HOME/Review_LogFiles}"
APP_HOST="${APP_HOST:-0.0.0.0}"
APP_PORT="${APP_PORT:-5001}"
SERVICE_NAME="${SERVICE_NAME:-review-rdklog}"
INSTALL_SERVICE="auto"
SKIP_PACKAGES=0
OPEN_FIREWALL=0
ALLOW_ROOT=0
ACTION="install"
ASSUME_YES=0
DIR_FROM_USER=0
PORT_FROM_USER=0
HOST_FROM_USER=0
APP_SCHEME="https"
PKG_FAILED=0
PKG_LOG="$(mktemp "${TMPDIR:-/tmp}/review-rdklog-pkgs.XXXXXX")"

if [[ -t 1 ]]; then
  C_BLUE=$'\033[1;34m' C_YELLOW=$'\033[1;33m' C_RED=$'\033[1;31m' C_GREEN=$'\033[1;32m' C_RESET=$'\033[0m'
else
  C_BLUE="" C_YELLOW="" C_RED="" C_GREEN="" C_RESET=""
fi
step() { printf '\n%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[error]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
trap 'die "Installer failed at line $LINENO: $BASH_COMMAND"' ERR

usage() {
  cat <<EOF
Review LogFiles installer

Usage: install_review_rdklog.sh [options]

Options:
  --dir PATH         Install directory            (default: \$HOME/Review_LogFiles)
  --repo URL         Git repository to clone      (default: $REPO_URL)
  --branch REF       Branch or tag to deploy      (default: $BRANCH)
  --host ADDR        Address the app listens on   (default: $APP_HOST)
  --port N           HTTPS port                   (default: $APP_PORT)
  --service          Force systemd service install
  --no-service       Do not install a systemd service
  --service-name N   systemd unit name            (default: $SERVICE_NAME)
  --open-firewall    Open the port in ufw/firewalld if active
  --skip-packages    Do not install OS packages (git/python3/...)
  --allow-root       Allow running as root (service will run as root)
  --status           Show version, service state and health of an installation
  --uninstall        Stop/remove the service and optionally the install dir
  -y, --yes          Do not prompt for confirmation
  -h, --help         Show this help

Every option can also be given as an environment variable
(REPO_URL, BRANCH, PROJECT_DIR, APP_HOST, APP_PORT, SERVICE_NAME).
EOF
}

need_arg() { [[ $# -ge 2 && -n "$2" ]] || die "Option $1 requires a value"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)          need_arg "$@"; PROJECT_DIR="$2"; DIR_FROM_USER=1; shift 2 ;;
    --repo)         need_arg "$@"; REPO_URL="$2"; shift 2 ;;
    --branch)       need_arg "$@"; BRANCH="$2"; shift 2 ;;
    --host)         need_arg "$@"; APP_HOST="$2"; HOST_FROM_USER=1; shift 2 ;;
    --port)         need_arg "$@"; APP_PORT="$2"; PORT_FROM_USER=1; shift 2 ;;
    --service)      INSTALL_SERVICE="yes"; shift ;;
    --no-service)   INSTALL_SERVICE="no"; shift ;;
    --service-name) need_arg "$@"; SERVICE_NAME="$2"; shift 2 ;;
    --open-firewall) OPEN_FIREWALL=1; shift ;;
    --skip-packages) SKIP_PACKAGES=1; shift ;;
    --allow-root)   ALLOW_ROOT=1; shift ;;
    --uninstall)    ACTION="uninstall"; shift ;;
    --status)       ACTION="status"; shift ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; die "Unknown option: $1" ;;
  esac
done

[[ "$APP_PORT" =~ ^[0-9]+$ && "$APP_PORT" -ge 1 && "$APP_PORT" -le 65535 ]] || die "Invalid port: $APP_PORT"
[[ "$SERVICE_NAME" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "Invalid service name: $SERVICE_NAME"

if [[ "$(id -u)" -eq 0 && $ALLOW_ROOT -eq 0 ]]; then
  die "Do not run as root. Run as the user that should own the app (sudo is used only when needed), or pass --allow-root."
fi
if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
  warn "sudo not found; OS package and service steps may fail."
fi

HAS_SYSTEMD=0
if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then HAS_SYSTEMD=1; fi
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

# When executed from inside an existing checkout, deploy that checkout instead of cloning.
SELF="${BASH_SOURCE[0]:-}"
if [[ $DIR_FROM_USER -eq 0 && -n "$SELF" && -f "$SELF" ]]; then
  SELF_DIR="$(cd -- "$(dirname -- "$SELF")" && pwd)"
  if [[ -d "$SELF_DIR/.git" && -f "$SELF_DIR/app.py" ]]; then PROJECT_DIR="$SELF_DIR"; fi
fi
PROJECT_DIR="${PROJECT_DIR%/}"

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local answer=""
  if [[ -r /dev/tty ]]; then read -r -p "$1 [y/N] " answer </dev/tty || true; fi
  [[ "$answer" =~ ^[Yy]$ ]]
}

service_exists() { [[ $HAS_SYSTEMD -eq 1 && -f "$UNIT_PATH" ]]; }

# ---------------------------------------------------------------------------

prereqs_ok() {
  command -v git >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 \
    && python3 -c 'import sys, venv, ensurepip; sys.exit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1
}

# Runs with errexit disabled (called via ||), so every step is chained explicitly.
os_install() {
  if command -v apt-get >/dev/null 2>&1; then
    if command -v fuser >/dev/null 2>&1; then
      while $SUDO fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
        info "Waiting for another apt/dpkg process to finish..."
        sleep 3
      done
    fi
    $SUDO apt-get update -qq >>"$PKG_LOG" 2>&1
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      git curl ca-certificates python3 python3-venv python3-pip >>"$PKG_LOG" 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y -q git curl ca-certificates python3 python3-pip
  elif command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y -q git curl ca-certificates python3 python3-pip
  elif command -v zypper >/dev/null 2>&1; then
    $SUDO zypper --non-interactive install git curl ca-certificates python3 python3-pip
  elif command -v apk >/dev/null 2>&1; then
    $SUDO apk add --no-cache git curl ca-certificates python3 py3-pip
  elif command -v pacman >/dev/null 2>&1; then
    $SUDO pacman -Sy --noconfirm --needed git curl ca-certificates python python-pip
  elif command -v brew >/dev/null 2>&1; then
    brew install git python3
  else
    warn "No supported package manager found."
    return 1
  fi
}

install_packages() {
  if [[ $SKIP_PACKAGES -eq 1 ]]; then
    info "Skipping OS packages (--skip-packages)"
  elif prereqs_ok; then
    ok "git, curl and Python (with venv) already installed"
  else
    info "Installing git, curl, python3 and venv support"
    if ! os_install; then
      PKG_FAILED=1
      tail -n 5 "$PKG_LOG" | sed 's/^/      /' >&2
      warn "OS package installation failed (full log: $PKG_LOG); continuing with what is already installed."
    fi
  fi
  for cmd in git curl; do command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed."; done
}

find_python() {
  local candidate
  PYTHON=""
  for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null 2>&1 \
      && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
      PYTHON="$(command -v "$candidate")"
      break
    fi
  done
  [[ -n "$PYTHON" ]] || die "Python 3.10+ is required. Found: $(python3 -V 2>&1 || echo none)"
  ok "Using $("$PYTHON" -V 2>&1) ($PYTHON)"
}

sync_repo() {
  if [[ -d "$PROJECT_DIR/.git" ]]; then
    local origin
    origin="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)"
    [[ -n "$origin" && "$origin" != "$REPO_URL" ]] && warn "Existing checkout tracks $origin (not $REPO_URL); keeping it."
    if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=no)" ]]; then
      local stash="installer-$(date +%Y%m%d-%H%M%S)"
      warn "Local changes found; stashing them as '$stash' (restore with: git -C $PROJECT_DIR stash pop)"
      git -C "$PROJECT_DIR" stash push -q -m "$stash"
    fi
    info "Fetching $BRANCH"
    git -C "$PROJECT_DIR" fetch -q --tags origin "$BRANCH" || die "Could not fetch '$BRANCH' from origin."
    if git -C "$PROJECT_DIR" show-ref -q --verify "refs/tags/$BRANCH"; then
      git -C "$PROJECT_DIR" -c advice.detachedHead=false checkout -q "tags/$BRANCH"
    else
      git -C "$PROJECT_DIR" checkout -q "$BRANCH" 2>/dev/null \
        || git -C "$PROJECT_DIR" checkout -q -b "$BRANCH" "origin/$BRANCH"
      git -C "$PROJECT_DIR" merge -q --ff-only "origin/$BRANCH" \
        || die "Local branch '$BRANCH' has diverged from origin; resolve it manually in $PROJECT_DIR."
    fi
  else
    if [[ -e "$PROJECT_DIR" && -n "$(ls -A "$PROJECT_DIR" 2>/dev/null)" ]]; then
      die "$PROJECT_DIR exists, is not empty and is not a git checkout. Choose another --dir."
    fi
    info "Cloning $REPO_URL ($BRANCH) into $PROJECT_DIR"
    mkdir -p "$(dirname "$PROJECT_DIR")"
    local depth=(--depth 1)
    [[ -d "$REPO_URL" ]] && depth=()
    git clone -q ${depth[@]+"${depth[@]}"} --branch "$BRANCH" "$REPO_URL" "$PROJECT_DIR" \
      || die "git clone failed. Check the URL/branch and your network or credentials."
  fi
  [[ -f "$PROJECT_DIR/pyproject.toml" && -d "$PROJECT_DIR/src/review_rdk_logger" ]] \
    || die "$PROJECT_DIR does not look like the Review LogFiles project (pyproject.toml/src missing)."
  ok "Code at $(git -C "$PROJECT_DIR" rev-parse --short HEAD) ($(git -C "$PROJECT_DIR" log -1 --format=%s | cut -c1-60))"
}

# venv -> distro venv package -> venv without pip + get-pip.py, so locked-down hosts still work.
create_venv() {
  local venv="$1" ver
  "$PYTHON" -m venv "$venv" >/dev/null 2>&1 && return 0
  rm -rf -- "$venv"
  ver="$("$PYTHON" -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"
  if command -v apt-get >/dev/null 2>&1 && [[ $SKIP_PACKAGES -eq 0 && $PKG_FAILED -eq 0 ]]; then
    info "Installing python${ver}-venv"
    if $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "python${ver}-venv" >/dev/null 2>&1 \
      && "$PYTHON" -m venv "$venv" >/dev/null 2>&1; then
      return 0
    fi
    rm -rf -- "$venv"
  fi
  warn "The venv/ensurepip module is unavailable; bootstrapping pip with get-pip.py"
  "$PYTHON" -m venv --without-pip "$venv" \
    || die "Could not create a virtualenv. Install python${ver}-venv (e.g. sudo apt-get install python${ver}-venv)."
  curl -fsSL --max-time 60 "${GET_PIP_URL:-https://bootstrap.pypa.io/get-pip.py}" | "$venv/bin/python" - -q \
    || { rm -rf -- "$venv"; die "Could not bootstrap pip. Install python${ver}-venv, or check network access to bootstrap.pypa.io / PyPI."; }
}

setup_venv() {
  local venv="$PROJECT_DIR/.venv"
  if [[ -x "$venv/bin/python" ]] && ! "$venv/bin/python" -c 'import sys' >/dev/null 2>&1; then
    warn "Existing virtualenv is broken; recreating it."
    rm -rf -- "$venv"
  fi
  if [[ ! -x "$venv/bin/python" ]]; then
    info "Creating virtualenv"
    create_venv "$venv"
  fi
  info "Installing Python dependencies"
  local pip_hint="Check network access to PyPI (set HTTPS_PROXY, or PIP_INDEX_URL for an internal mirror) and re-run."
  "$venv/bin/python" -m pip install -q --disable-pip-version-check --upgrade pip setuptools wheel \
    || die "Could not upgrade pip. $pip_hint"
  "$venv/bin/python" -m pip install -q --disable-pip-version-check -e "$PROJECT_DIR" \
    || die "Could not install Python dependencies. $pip_hint"
  "$venv/bin/review-rdk-web" --version >/dev/null || die "Package installed but 'review-rdk-web' does not run."
  ok "Installed $("$venv/bin/review-rdk-web" --version) into $venv"
}

set_env_var() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$file"; then
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k {print k "=" v; next} {print}' "$file" >"$tmp"
    cat "$tmp" >"$file" && rm -f "$tmp"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

setup_env() {
  local env_file="$PROJECT_DIR/.env"
  if [[ ! -f "$env_file" ]]; then
    info "Creating $env_file"
    (umask 077; : >"$env_file")
    [[ -f "$PROJECT_DIR/.env.example" ]] && grep -v '^FLASK_SECRET_KEY=' "$PROJECT_DIR/.env.example" >"$env_file" || true
    HOST_FROM_USER=1 PORT_FROM_USER=1
  fi
  chmod 600 "$env_file"
  [[ $HOST_FROM_USER -eq 1 ]] && set_env_var "$env_file" APP_HOST "$APP_HOST"
  [[ $PORT_FROM_USER -eq 1 ]] && set_env_var "$env_file" APP_PORT "$APP_PORT"
  if ! grep -Eq '^FLASK_SECRET_KEY=.{32,}' "$env_file" || grep -q '^FLASK_SECRET_KEY=change-me' "$env_file"; then
    set_env_var "$env_file" FLASK_SECRET_KEY "$("$PYTHON" -c 'import secrets; print(secrets.token_hex(32))')"
  fi
  read_env_settings
  mkdir -p "$PROJECT_DIR/uploads"
  ok "Configuration in $env_file ($APP_SCHEME, port $APP_PORT)"
}

# The effective settings are whatever .env says (it may have been customised by hand).
env_value() { sed -n "s/^$1=//p" "$PROJECT_DIR/.env" 2>/dev/null | tail -n1 | tr -d "\"'\r"; }
read_env_settings() {
  APP_PORT="$(env_value APP_PORT)"; APP_PORT="${APP_PORT:-5001}"
  case "$(env_value APP_SSL | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off) APP_SCHEME="http" ;;
    *)              APP_SCHEME="https" ;;
  esac
}

port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH "sport = :$1" 2>/dev/null | grep -q .
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

install_service() {
  local run_user run_group
  run_user="$(id -un)"
  run_group="$(id -gn)"
  info "Writing $UNIT_PATH"
  $SUDO tee "$UNIT_PATH" >/dev/null <<EOF
[Unit]
Description=Review LogFiles (RDK log review web app)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${run_user}
Group=${run_group}
WorkingDirectory=${PROJECT_DIR}
Environment=REVIEW_DATA_DIR=${PROJECT_DIR}
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=${PROJECT_DIR}/.env
ExecStart=${PROJECT_DIR}/.venv/bin/review-rdk-web
Restart=on-failure
RestartSec=5
TimeoutStopSec=20
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload
  if ! $SUDO systemctl is-active -q "$SERVICE_NAME" && port_in_use "$APP_PORT"; then
    warn "Port $APP_PORT is already used by another process; the service may fail to start."
  fi
  $SUDO systemctl enable -q "$SERVICE_NAME"
  $SUDO systemctl restart "$SERVICE_NAME"
  ok "Service $SERVICE_NAME enabled and (re)started"
}

open_firewall() {
  [[ $OPEN_FIREWALL -eq 1 ]] || return 0
  if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
    $SUDO ufw allow "${APP_PORT}/tcp" >/dev/null && ok "ufw: opened ${APP_PORT}/tcp"
  elif command -v firewall-cmd >/dev/null 2>&1 && $SUDO firewall-cmd --state >/dev/null 2>&1; then
    $SUDO firewall-cmd -q --permanent --add-port="${APP_PORT}/tcp" && $SUDO firewall-cmd -q --reload \
      && ok "firewalld: opened ${APP_PORT}/tcp"
  else
    info "No active ufw/firewalld found; nothing to open."
  fi
}

health_check() {
  local url="${APP_SCHEME}://127.0.0.1:${APP_PORT}/healthz" _ body
  info "Waiting for $url"
  for _ in $(seq 1 20); do
    if body="$(curl -fsk --max-time 2 "$url" 2>/dev/null)"; then
      ok "App is responding: $body"
      return 0
    fi
    sleep 1
  done
  warn "App did not respond within 20s. Inspect: journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
  return 1
}

primary_ip() {
  local ip=""
  command -v hostname >/dev/null 2>&1 && ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
  [[ -z "$ip" ]] && command -v ip >/dev/null 2>&1 && ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
  echo "${ip:-127.0.0.1}"
}

do_status() {
  [[ -d "$PROJECT_DIR/.git" ]] || die "No installation found at $PROJECT_DIR (use --dir)."
  [[ -f "$PROJECT_DIR/.env" ]] && read_env_settings
  info "Directory: $PROJECT_DIR"
  info "Revision : $(git -C "$PROJECT_DIR" rev-parse --short HEAD) ($(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD))"
  [[ -x "$PROJECT_DIR/.venv/bin/review-rdk-web" ]] && info "Version  : $("$PROJECT_DIR/.venv/bin/review-rdk-web" --version)"
  if service_exists; then
    info "Service  : $SERVICE_NAME is $(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
  else
    info "Service  : not installed"
  fi
  health_check || true
  info "URL      : ${APP_SCHEME}://$(primary_ip):${APP_PORT}"
}

do_uninstall() {
  step "Uninstalling Review LogFiles"
  if service_exists; then
    $SUDO systemctl disable --now -q "$SERVICE_NAME" 2>/dev/null || true
    $SUDO rm -f "$UNIT_PATH"
    $SUDO systemctl daemon-reload
    ok "Removed service $SERVICE_NAME"
  else
    info "No service named $SERVICE_NAME installed"
  fi
  if [[ -d "$PROJECT_DIR" ]]; then
    if confirm "Delete $PROJECT_DIR (including uploads/ and .env)?"; then
      rm -rf -- "$PROJECT_DIR"
      ok "Deleted $PROJECT_DIR"
    else
      info "Kept $PROJECT_DIR"
    fi
  fi
}

do_install() {
  printf '%sReview LogFiles installer%s\n' "$C_BLUE" "$C_RESET"
  info "Directory : $PROJECT_DIR"
  info "Repository: $REPO_URL ($BRANCH)"

  step "1/5 OS packages";        install_packages
  step "2/5 Python";             find_python
  step "3/5 Source code";        sync_repo
  step "4/5 Dependencies";       setup_venv
  step "5/5 Configuration";      setup_env

  local want_service=0
  case "$INSTALL_SERVICE" in
    yes) [[ $HAS_SYSTEMD -eq 1 ]] || die "--service requested but systemd is not available."; want_service=1 ;;
    auto) [[ $HAS_SYSTEMD -eq 1 ]] && want_service=1 ;;
  esac

  local healthy=1
  if [[ $want_service -eq 1 ]]; then
    step "Service"
    install_service
    open_firewall
    health_check || healthy=0
  else
    open_firewall
  fi

  local url="${APP_SCHEME}://$(primary_ip):${APP_PORT}" note=""
  [[ "$APP_SCHEME" == "https" ]] && note="(self-signed certificate - accept the browser warning)"
  printf '\n%sDone.%s\n' "$C_GREEN" "$C_RESET"
  if [[ $want_service -eq 1 ]]; then
    cat <<EOF
  Open:      $url   $note
  Status:    bash $PROJECT_DIR/install_review_rdklog.sh --status
  Logs:      journalctl -u $SERVICE_NAME -f
  Update:    bash $PROJECT_DIR/install_review_rdklog.sh
  Uninstall: bash $PROJECT_DIR/install_review_rdklog.sh --uninstall
EOF
  else
    cat <<EOF
  Start:     cd $PROJECT_DIR && .venv/bin/review-rdk-web
  Open:      $url   $note
EOF
  fi
  cat <<EOF
  CLI:       $PROJECT_DIR/.venv/bin/review-rdk-logger <archive.tgz|directory>
EOF
  [[ $healthy -eq 1 ]] || exit 1
}

case "$ACTION" in
  uninstall) do_uninstall ;;
  status)    do_status ;;
  *)         do_install ;;
esac
