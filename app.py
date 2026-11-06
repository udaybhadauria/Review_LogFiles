from __future__ import annotations

import ipaddress
import os
import re
import tarfile
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from flask import Flask, jsonify, render_template, request

BASE_DIR = Path(__file__).resolve().parent
UPLOAD_DIR = BASE_DIR / "uploads"
UPLOAD_DIR.mkdir(exist_ok=True)
CERT_PATH = BASE_DIR / "cert.pem"
KEY_PATH = BASE_DIR / "key.pem"

app = Flask(__name__, template_folder="templates", static_folder="static")
app.config["MAX_CONTENT_LENGTH"] = 500 * 1024 * 1024
app.secret_key = "review-rdk-log-ui-secret-key"


def normalize_mac(value: str | None) -> str | None:
    if not value:
        return None
    cleaned = re.sub(r"[^A-Fa-f0-9]", "", value)
    if len(cleaned) < 12:
        return None
    cleaned = cleaned[:12]
    mac = ":".join(cleaned[i : i + 2] for i in range(0, len(cleaned), 2)).upper()
    return mac


def extract_mac_candidates(names: list[str]) -> list[str]:
    macs: list[str] = []
    for candidate in names:
        stem = Path(candidate).name
        match = re.search(r"([A-Fa-f0-9]{12})", stem)
        if not match:
            continue
        mac = normalize_mac(match.group(1))
        if mac and mac not in macs:
            macs.append(mac)
    return macs


def _is_logish(name: str) -> bool:
    lower = name.lower()
    if lower.endswith((".log", ".txt", ".out", ".cfg", ".xml", ".json", ".csv", ".ini", ".conf")):
        return True
    return "/" in lower and any(lower.endswith(suffix) for suffix in (".log", ".txt", ".out"))


def _list_archive_logs(archive_path: Path) -> list[str]:
    with tarfile.open(archive_path, "r:*") as archive:
        return [member.name for member in archive.getmembers() if member.isfile() and _is_logish(member.name)]


def build_archive_catalog(root_path: str | Path) -> dict[str, Any]:
    target = Path(root_path)
    archives: list[Path] = []

    if target.is_file():
        archives = [target]
    elif target.is_dir():
        archives = sorted(target.glob("*.tgz")) + sorted(target.glob("*.tar.gz"))
        archives.extend(sorted((UPLOAD_DIR).glob("*.tgz")))
        archives.extend(sorted((UPLOAD_DIR).glob("*.tar.gz")))
        seen: set[Path] = set()
        unique_archives: list[Path] = []
        for path in archives:
            resolved = path.resolve()
            if resolved not in seen:
                seen.add(resolved)
                unique_archives.append(path)
        archives = unique_archives

    by_mac: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for archive in archives:
        if not archive.exists() or not archive.is_file():
            continue
        basename = archive.name
        macs = extract_mac_candidates([basename])
        mac = macs[0] if macs else "UNKNOWN"
        log_files = _list_archive_logs(archive)
        by_mac[mac].append(
            {
                "archive": basename,
                "path": str(archive),
                "log_files": log_files,
            }
        )

    ordered_macs = sorted(by_mac)
    if "UNKNOWN" in ordered_macs:
        ordered_macs.remove("UNKNOWN")
        ordered_macs.append("UNKNOWN")

    catalog = {
        "macs": ordered_macs,
        "by_mac": {key: value for key, value in sorted(by_mac.items()) if key != "UNKNOWN"},
    }
    if "UNKNOWN" in by_mac:
        catalog["by_mac"]["UNKNOWN"] = by_mac["UNKNOWN"]
    return catalog


def read_log_member(archive_name: str, member_name: str) -> str:
    archive_path = (UPLOAD_DIR / archive_name).resolve()
    if not archive_path.exists():
        raise FileNotFoundError(f"Archive not found: {archive_name}")

    with tarfile.open(archive_path, "r:*") as archive:
        try:
            member = archive.getmember(member_name)
        except KeyError as exc:
            raise FileNotFoundError(f"Member not found: {member_name}") from exc
        extracted = archive.extractfile(member)
        if extracted is None:
            raise FileNotFoundError(f"Could not read member: {member_name}")
        payload = extracted.read()
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError:
        return payload.decode("utf-8", errors="replace")


def ensure_ssl_certificates() -> None:
    if CERT_PATH.exists() and KEY_PATH.exists():
        return

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, "localhost"),
    ])

    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(datetime.now(timezone.utc) - timedelta(days=1))
        .not_valid_after(datetime.now(timezone.utc) + timedelta(days=365))
        .add_extension(
            x509.SubjectAlternativeName(
                [
                    x509.DNSName("localhost"),
                    x509.IPAddress(ipaddress.ip_address("127.0.0.1")),
                    x509.IPAddress(ipaddress.ip_address("0.0.0.0")),
                ]
            ),
            critical=False,
        )
        .sign(key, hashes.SHA256())
    )

    KEY_PATH.write_bytes(
        key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    CERT_PATH.write_bytes(cert.public_bytes(serialization.Encoding.PEM))


@app.route("/")
def index():
    catalog = build_archive_catalog(BASE_DIR)
    return render_template("index.html", catalog=catalog)


@app.route("/upload", methods=["POST"])
def upload_archives():
    uploaded = request.files.getlist("archives")
    for file_obj in uploaded:
        if file_obj and file_obj.filename:
            filename = Path(file_obj.filename).name
            if filename.lower().endswith((".tgz", ".gz")):
                saved_path = UPLOAD_DIR / filename
                file_obj.save(saved_path)
    return index()


@app.route("/api/log-content")
def api_log_content():
    archive_name = request.args.get("archive", "")
    member_name = request.args.get("path", "")
    if not archive_name or not member_name:
        return jsonify({"error": "archive and path are required"}), 400

    try:
        content = read_log_member(archive_name, member_name)
    except FileNotFoundError as exc:
        return jsonify({"error": str(exc)}), 404

    payload = {
        "archive": archive_name,
        "path": member_name,
        "content": content[:200000],
    }
    return jsonify(payload)


@app.route("/api/catalog")
def api_catalog():
    return jsonify(build_archive_catalog(BASE_DIR))


if __name__ == "__main__":
    ensure_ssl_certificates()
    app.run(host="0.0.0.0", port=5001, debug=False, ssl_context=(str(CERT_PATH), str(KEY_PATH)))
