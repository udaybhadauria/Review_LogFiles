"""Flask web UI for browsing RDK log bundles.

All runtime state (``.env``, ``uploads/``, ``certs/``) lives in the data directory, which is
``$REVIEW_DATA_DIR`` or the current working directory.
"""

from __future__ import annotations

import argparse
import ipaddress
import logging
import os
import re
import secrets
import socket
import sys
import tarfile
import tempfile
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from pathlib import Path
from typing import Any

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from flask import Flask, Response, jsonify, redirect, render_template, request, url_for
from werkzeug.utils import secure_filename

from . import __version__
from .reviewer import decode_text, find_archives, is_log_member, summarize_archive

log = logging.getLogger("review_rdk_logger.web")


def _load_dotenv(path: Path) -> None:
    if not path.is_file():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip("'\""))


def _env_flag(name: str, default: str) -> bool:
    return os.environ.get(name, default).strip().lower() not in {"0", "false", "no", "off", ""}


DATA_DIR = Path(os.environ.get("REVIEW_DATA_DIR") or Path.cwd()).resolve()
_load_dotenv(DATA_DIR / ".env")

APP_HOST = os.environ.get("APP_HOST", "0.0.0.0")
APP_PORT = int(os.environ.get("APP_PORT", "5001"))
APP_SSL = _env_flag("APP_SSL", "1")
UPLOAD_DIR = Path(os.environ.get("UPLOAD_DIR") or DATA_DIR / "uploads")
ARCHIVE_DIR = Path(os.environ.get("ARCHIVE_DIR") or DATA_DIR)
CERT_PATH = Path(os.environ.get("SSL_CERT") or DATA_DIR / "certs" / "cert.pem")
KEY_PATH = Path(os.environ.get("SSL_KEY") or DATA_DIR / "certs" / "key.pem")
MAX_VIEW_BYTES = int(os.environ.get("MAX_VIEW_BYTES", 5 * 1024 * 1024))
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = int(os.environ.get("MAX_UPLOAD_MB", "500")) * 1024 * 1024
app.secret_key = os.environ.get("FLASK_SECRET_KEY") or secrets.token_hex(32)

_CAPTURE_TIME = re.compile(r"_Logs_(\d{2}-\d{2}-\d{2})-(\d{2})-(\d{2})(AM|PM)", re.IGNORECASE)


def normalize_mac(value: str | None) -> str | None:
    if not value:
        return None
    cleaned = re.sub(r"[^A-Fa-f0-9]", "", value)
    if len(cleaned) < 12:
        return None
    cleaned = cleaned[:12]
    return ":".join(cleaned[i : i + 2] for i in range(0, len(cleaned), 2)).upper()


def extract_mac_candidates(names: list[str]) -> list[str]:
    macs: list[str] = []
    for candidate in names:
        match = re.search(r"([A-Fa-f0-9]{12})", Path(candidate).name)
        if not match:
            continue
        mac = normalize_mac(match.group(1))
        if mac and mac not in macs:
            macs.append(mac)
    return macs


def parse_capture_time(name: str) -> str | None:
    match = _CAPTURE_TIME.search(name)
    if not match:
        return None
    date, hour, minute, meridiem = match.groups()
    try:
        return datetime.strptime(f"{date} {hour}:{minute}{meridiem.upper()}", "%m-%d-%y %I:%M%p").isoformat()
    except ValueError:
        return None


@lru_cache(maxsize=128)
def _archive_members(path: str, _mtime_ns: int, _size: int) -> tuple[tuple[str, int], ...]:
    with tarfile.open(path, "r:*") as archive:
        return tuple((m.name, m.size) for m in archive if m.isfile() and is_log_member(m.name))


@lru_cache(maxsize=64)
def _archive_summary(path: str, _mtime_ns: int, _size: int) -> dict[str, dict[str, int]]:
    return summarize_archive(path)


def _cache_key(path: Path) -> tuple[str, int, int]:
    stat = path.stat()
    return str(path), stat.st_mtime_ns, stat.st_size


def _archive_dirs(root: Path | None = None) -> list[Path]:
    dirs = [UPLOAD_DIR, root or ARCHIVE_DIR]
    unique: list[Path] = []
    for directory in dirs:
        if directory.is_dir() and directory.resolve() not in {d.resolve() for d in unique}:
            unique.append(directory)
    return unique


def resolve_archive(name: str, root: Path | None = None) -> Path | None:
    """Map a bare archive file name to a file inside one of the allowed archive directories."""
    if not name or name != Path(name).name or name.startswith("."):
        return None
    for directory in _archive_dirs(root):
        candidate = directory / name
        if candidate.is_file():
            return candidate
    return None


def build_archive_catalog(root_path: str | Path) -> dict[str, Any]:
    target = Path(root_path)
    if target.is_file():
        archives = [target]
    else:
        seen: set[str] = set()
        archives = []
        for directory in _archive_dirs(target if target.is_dir() else None):
            for path in find_archives(directory):
                if path.name not in seen:
                    seen.add(path.name)
                    archives.append(path)

    upload_root = UPLOAD_DIR.resolve()
    by_mac: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for archive in archives:
        try:
            members = _archive_members(*_cache_key(archive))
        except (tarfile.TarError, OSError, EOFError) as exc:
            log.warning("Skipping unreadable archive %s: %s", archive.name, exc)
            continue
        macs = extract_mac_candidates([archive.name])
        mac = macs[0] if macs else "UNKNOWN"
        stat = archive.stat()
        by_mac[mac].append(
            {
                "archive": archive.name,
                "mac": mac,
                "captured_at": parse_capture_time(archive.name),
                "size": stat.st_size,
                "modified": datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat(),
                "deletable": archive.resolve().parent == upload_root,
                "log_files": [name for name, _ in members],
                "sizes": dict(members),
            }
        )

    for entries in by_mac.values():
        entries.sort(key=lambda e: e["captured_at"] or e["modified"], reverse=True)

    ordered = sorted(mac for mac in by_mac if mac != "UNKNOWN")
    if "UNKNOWN" in by_mac:
        ordered.append("UNKNOWN")
    return {"macs": ordered, "by_mac": {mac: by_mac[mac] for mac in ordered}}


def read_log_member(archive_name: str, member_name: str, max_bytes: int = MAX_VIEW_BYTES) -> dict[str, Any]:
    archive_path = resolve_archive(archive_name)
    if archive_path is None:
        raise FileNotFoundError(f"Archive not found: {archive_name}")
    with tarfile.open(archive_path, "r:*") as archive:
        try:
            member = archive.getmember(member_name)
        except KeyError as exc:
            raise FileNotFoundError(f"File not found in archive: {member_name}") from exc
        handle = archive.extractfile(member) if member.isfile() else None
        if handle is None:
            raise FileNotFoundError(f"Not a regular file: {member_name}")
        payload = handle.read(max_bytes)
    text = decode_text(payload)
    return {
        "archive": archive_name,
        "path": member_name,
        "size": member.size,
        "truncated": member.size > len(payload),
        "binary": text is None,
        "content": text or "",
    }


def ensure_ssl_certificates() -> None:
    if CERT_PATH.exists() and KEY_PATH.exists():
        return
    log.info("Generating self-signed certificate at %s", CERT_PATH)

    hostname = socket.gethostname()
    names: list[x509.GeneralName] = [x509.DNSName("localhost"), x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]
    if hostname and hostname != "localhost":
        names.append(x509.DNSName(hostname))
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("192.0.2.1", 9))
            names.append(x509.IPAddress(ipaddress.ip_address(probe.getsockname()[0])))
    except OSError:
        pass

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, hostname or "localhost")])
    now = datetime.now(timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=825))
        .add_extension(x509.SubjectAlternativeName(names), critical=False)
        .sign(key, hashes.SHA256())
    )

    KEY_PATH.parent.mkdir(parents=True, exist_ok=True)
    KEY_PATH.write_bytes(
        key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    KEY_PATH.chmod(0o600)
    CERT_PATH.write_bytes(cert.public_bytes(serialization.Encoding.PEM))


def save_uploads(files) -> dict[str, list]:
    saved: list[str] = []
    rejected: list[dict[str, str]] = []
    for file_obj in files:
        if not file_obj or not file_obj.filename:
            continue
        filename = secure_filename(Path(file_obj.filename).name)
        if not filename.lower().endswith((".tgz", ".tar.gz")):
            rejected.append({"name": file_obj.filename, "reason": "only .tgz / .tar.gz files are accepted"})
            continue
        fd, tmp_name = tempfile.mkstemp(dir=UPLOAD_DIR, prefix=".upload-")
        os.close(fd)
        tmp_path = Path(tmp_name)
        try:
            file_obj.save(tmp_path)
            if not tarfile.is_tarfile(tmp_path):
                rejected.append({"name": file_obj.filename, "reason": "not a valid tar archive"})
                continue
            os.replace(tmp_path, UPLOAD_DIR / filename)
            saved.append(filename)
        finally:
            tmp_path.unlink(missing_ok=True)
    return {"saved": saved, "rejected": rejected}


@app.route("/")
def index():
    return render_template("index.html", version=__version__)


@app.route("/healthz")
def healthz():
    return jsonify({"status": "ok", "version": __version__})


@app.route("/upload", methods=["POST"])
def upload_archives():
    save_uploads(request.files.getlist("archives"))
    return redirect(url_for("index"))


@app.route("/api/upload", methods=["POST"])
def api_upload():
    result = save_uploads(request.files.getlist("archives"))
    status = 200 if result["saved"] or not result["rejected"] else 400
    return jsonify(result), status


@app.route("/api/catalog")
def api_catalog():
    return jsonify(build_archive_catalog(ARCHIVE_DIR))


@app.route("/api/summary")
def api_summary():
    archive_path = resolve_archive(request.args.get("archive", ""))
    if archive_path is None:
        return jsonify({"error": "archive not found"}), 404
    return jsonify({"archive": archive_path.name, "files": _archive_summary(*_cache_key(archive_path))})


@app.route("/api/log-content")
def api_log_content():
    archive_name = request.args.get("archive", "")
    member_name = request.args.get("path", "")
    if not archive_name or not member_name:
        return jsonify({"error": "archive and path are required"}), 400
    try:
        return jsonify(read_log_member(archive_name, member_name))
    except FileNotFoundError as exc:
        return jsonify({"error": str(exc)}), 404


@app.route("/api/download")
def api_download():
    archive_name = request.args.get("archive", "")
    member_name = request.args.get("path", "")
    try:
        data = read_log_member(archive_name, member_name, max_bytes=app.config["MAX_CONTENT_LENGTH"])
    except FileNotFoundError as exc:
        return jsonify({"error": str(exc)}), 404
    download_name = f"{Path(archive_name).name.split('.')[0]}__{member_name.replace('/', '_')}"
    return Response(
        data["content"],
        mimetype="text/plain; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{secure_filename(download_name)}"'},
    )


@app.route("/api/archives/<name>", methods=["DELETE"])
def api_delete_archive(name: str):
    archive_path = resolve_archive(name)
    if archive_path is None or archive_path.resolve().parent != UPLOAD_DIR.resolve():
        return jsonify({"error": "only uploaded archives can be deleted"}), 404
    archive_path.unlink()
    return jsonify({"deleted": name})


@app.errorhandler(413)
def too_large(_error):
    limit = app.config["MAX_CONTENT_LENGTH"] // (1024 * 1024)
    return jsonify({"error": f"upload exceeds the {limit} MB limit"}), 413


@app.after_request
def security_headers(response: Response) -> Response:
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("X-Frame-Options", "DENY")
    response.headers.setdefault("Referrer-Policy", "same-origin")
    return response


def _gunicorn_available() -> bool:
    if sys.platform == "win32":
        return False
    try:
        import gunicorn  # noqa: F401
    except ImportError:
        return False
    return True


def _run_gunicorn(host: str, port: int, ssl: bool) -> None:
    from gunicorn.app.base import BaseApplication

    options = {
        "bind": f"{host}:{port}",
        "workers": int(os.environ.get("WEB_WORKERS", "2")),
        "threads": int(os.environ.get("WEB_THREADS", "4")),
        "worker_class": "gthread",
        "timeout": int(os.environ.get("WEB_TIMEOUT", "300")),
        "accesslog": "-",
        "errorlog": "-",
    }
    if ssl:
        options.update(certfile=str(CERT_PATH), keyfile=str(KEY_PATH))

    class _Server(BaseApplication):
        def load_config(self) -> None:
            for key, value in options.items():
                self.cfg.set(key, value)

        def load(self) -> Flask:
            return app

    _Server().run()


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="review-rdk-web", description="Serve the RDK log review web UI.")
    parser.add_argument("--host", default=APP_HOST, help=f"listen address (default: {APP_HOST})")
    parser.add_argument("--port", type=int, default=APP_PORT, help=f"listen port (default: {APP_PORT})")
    parser.add_argument("--no-ssl", action="store_true", help="serve plain HTTP (same as APP_SSL=0)")
    parser.add_argument("--dev", action="store_true", help="use the Flask development server")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    return parser


def main(argv: list[str] | None = None) -> None:
    args = _build_parser().parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    ssl = APP_SSL and not args.no_ssl
    if ssl:
        ensure_ssl_certificates()
    scheme = "https" if ssl else "http"
    log.info("Review RDK Logger %s - data dir %s - %s://%s:%s", __version__, DATA_DIR, scheme, args.host, args.port)
    if not args.dev and _gunicorn_available():
        _run_gunicorn(args.host, args.port, ssl)
    else:
        ssl_context = (str(CERT_PATH), str(KEY_PATH)) if ssl else None
        app.run(host=args.host, port=args.port, debug=False, threaded=True, ssl_context=ssl_context)


if __name__ == "__main__":
    main()
