# Review RDK Logger

Web UI and CLI for reviewing RDK log bundles (`<MAC>_Logs_<MM-DD-YY-HH-MMAM>.tgz`).

- Groups bundles by device MAC and capture time
- Lists every log in a bundle, including rotated logs (`PAMlog.txt.0`, `csc_mon.log.1`, ...)
- Counts errors/warnings per file (`ERROR`, `PANIC`, `FAIL`, `EXCEPTION`, `WARN`, ...)
- Side-by-side viewer (up to 4 panes) with search, severity filters, jump-to-next-error and download
- Drag-and-drop upload, light/dark theme, shareable URLs

## Install (Linux server)

One-liner — clones the repo, creates a virtualenv, writes `.env` with a random secret,
installs a systemd service and checks that it responds:

```bash
curl -fsSL https://raw.githubusercontent.com/udaybhadauria/Review_LogFiles/main/install_review_rdklog.sh | bash
```

With options:

```bash
curl -fsSL https://raw.githubusercontent.com/udaybhadauria/Review_LogFiles/main/install_review_rdklog.sh \
  | bash -s -- --dir /opt/review_logfiles --port 8443 --open-firewall
```

| Option | Meaning |
| --- | --- |
| `--dir PATH` | Install directory (default `~/Review_LogFiles`) |
| `--repo URL` / `--branch REF` | Source repository and branch/tag |
| `--host ADDR` / `--port N` | Listen address / HTTPS port (stored in `.env`) |
| `--no-service` / `--service` | Skip / force the systemd service |
| `--open-firewall` | Open the port in ufw or firewalld |
| `--skip-packages` | Don't install OS packages |
| `--uninstall [-y]` | Remove the service (and optionally the directory) |

Re-run the same command (or `bash ~/Review_LogFiles/install_review_rdklog.sh`) to update.
Supported package managers: apt, dnf, yum, zypper, apk, pacman, brew. Requires Python 3.10+.

## Configuration

Settings live in `.env` (see `.env.example`): `APP_HOST`, `APP_PORT`, `FLASK_SECRET_KEY`,
`APP_SSL`, `SSL_CERT`/`SSL_KEY`, `ARCHIVE_DIR`, `MAX_UPLOAD_MB`.
A self-signed certificate is generated on first start if none is configured.

## Run locally

```bash
python -m venv .venv && . .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt -e .
python app.py                                   # https://localhost:5001
```

## CLI

```bash
review-rdk-logger .                                       # every .tgz in a directory
review-rdk-logger 00CB7AC3E122_Logs_11-01-26-04-37PM.tgz --output reports/report.json
```

## Tests

```bash
python -m pytest -q
```
