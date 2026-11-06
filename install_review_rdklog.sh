#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

REPO_URL="${REPO_URL:-https://github.com/udaybhadauria/Review_LogFiles.git}"
PROJECT_DIR="${PROJECT_DIR:-$HOME/Review_LogFiles}"
SERVICE_NAME="${SERVICE_NAME:-review-rdklog.service}"
APP_PORT="${APP_PORT:-5001}"
APP_HOST="${APP_HOST:-0.0.0.0}"
APP_USER="${APP_USER:-$(id -un)}"
APP_GROUP="${APP_GROUP:-$(id -gn)}"

echo "=== Review LogFiles install starting ==="

if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

if command -v systemctl >/dev/null 2>&1; then
  SYSTEMCTL_AVAILABLE=true
else
  SYSTEMCTL_AVAILABLE=false
fi

if command -v apt-get >/dev/null 2>&1; then
  echo "=== Step 0: Install base packages ==="
  ${SUDO} apt-get update
  ${SUDO} apt-get install -y git curl python3 python3-venv python3-pip ca-certificates
fi

if [[ -n "${SUDO}" && "${SYSTEMCTL_AVAILABLE}" == true ]]; then
  echo "=== Step 1: Stop any existing service ==="
  ${SUDO} systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
fi

if command -v fuser >/dev/null 2>&1; then
  echo "=== Step 2: Free port ${APP_PORT} if needed ==="
  fuser -k "${APP_PORT}/tcp" 2>/dev/null || true
fi

if [[ -d "${PROJECT_DIR}/.git" ]]; then
  echo "=== Step 3: Updating existing repo ==="
  git -C "${PROJECT_DIR}" fetch --all --prune || true
  if git -C "${PROJECT_DIR}" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "${PROJECT_DIR}" pull --ff-only || true
  else
    echo "ERROR: repo exists but is empty. Push the app code to the remote repo first or use a repo with files."
    exit 1
  fi
else
  echo "=== Step 3: Cloning repo ==="
  rm -rf "${PROJECT_DIR}"
  git clone "${REPO_URL}" "${PROJECT_DIR}"
  if ! git -C "${PROJECT_DIR}" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "ERROR: repo cloned successfully but is empty. The repository has no committed files yet."
    echo "Fix: push the app files to GitHub or clone the actual project repo before running this installer."
    exit 1
  fi
fi

cd "${PROJECT_DIR}"

if [[ ! -f requirements.txt || ! -f app.py ]]; then
  echo "ERROR: requirements.txt and app.py were not found in ${PROJECT_DIR}."
  echo "This usually means the repo is empty or the wrong repository was cloned."
  exit 1
fi

echo "=== Step 4: Clean stale runtime files ==="
rm -rf .venv __pycache__ .pytest_cache .mypy_cache uploads 2>/dev/null || true
mkdir -p uploads

if [[ ! -f .env ]]; then
  cp .env.example .env 2>/dev/null || true
fi

if [[ -f .env ]]; then
  echo "=== Step 5: Create default app environment config ==="
  if ! grep -q '^APP_PORT=' .env 2>/dev/null; then
    printf '\nAPP_PORT=%s\nAPP_HOST=%s\nFLASK_SECRET_KEY=%s\n' "${APP_PORT}" "${APP_HOST}" "$(openssl rand -hex 32 2>/dev/null || python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)" >> .env
  fi
fi

echo "=== Step 6: Create virtual environment ==="
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip setuptools wheel
pip install -r requirements.txt

if [[ -f setup_review_rdklog.sh ]]; then
  echo "=== Step 7: Run project setup hook ==="
  bash setup_review_rdklog.sh || true
fi

if [[ -f app.py ]]; then
  echo "=== Step 8: Smoke test the app locally ==="
  nohup python app.py >/tmp/review_rdklog_app.log 2>&1 &
  sleep 4
  curl -k -fsI "https://127.0.0.1:${APP_PORT}/" >/dev/null || echo "WARN: local smoke test did not respond yet"
  pkill -f "python app.py" 2>/dev/null || true
fi

if [[ "${SYSTEMCTL_AVAILABLE}" == true ]]; then
  echo "=== Step 9: Create systemd service ==="
  cat > "/etc/systemd/system/${SERVICE_NAME}" <<EOF
[Unit]
Description=Review LogFiles HTTPS App
After=network.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${PROJECT_DIR}
Environment=APP_PORT=${APP_PORT}
Environment=APP_HOST=${APP_HOST}
Environment=FLASK_SECRET_KEY=${APP_SECRET_KEY:-$(openssl rand -hex 32 2>/dev/null || python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)}
ExecStart=${PROJECT_DIR}/.venv/bin/python ${PROJECT_DIR}/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  ${SUDO} systemctl daemon-reload
  ${SUDO} systemctl enable --now "${SERVICE_NAME}"
  ${SUDO} systemctl status "${SERVICE_NAME}" --no-pager || true
fi

if [[ -d "${PROJECT_DIR}" ]]; then
  chown -R "${APP_USER}:${APP_GROUP}" "${PROJECT_DIR}" 2>/dev/null || true
  find "${PROJECT_DIR}" -type d -exec chmod 755 {} +
  find "${PROJECT_DIR}" -type f -exec chmod 644 {} +
  chmod 700 "${PROJECT_DIR}/.venv" 2>/dev/null || true
fi

if [[ "${SYSTEMCTL_AVAILABLE}" == true ]]; then
  echo "=== Step 10: Final service smoke test ==="
  ${SUDO} systemctl is-active "${SERVICE_NAME}" || echo "WARN: service is not active yet"
  curl -k -fsI "https://127.0.0.1:${APP_PORT}/" >/dev/null || echo "WARN: service endpoint not responding yet; check journalctl -u ${SERVICE_NAME}"
fi

echo ""
echo "Review LogFiles installation complete."
echo "Project directory: ${PROJECT_DIR}"
echo "Service: ${SERVICE_NAME}"
echo "HTTPS URL: https://127.0.0.1:${APP_PORT}/"
echo "Logs: journalctl -u ${SERVICE_NAME} -f"
