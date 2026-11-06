from __future__ import annotations

import json
import re
import tarfile
import tempfile
from pathlib import Path
from typing import Any

KEYWORD_PATTERN = re.compile(r"\b(ERROR|WARN|WARNING|PANIC|FAIL|FAILED|EXCEPTION|CRITICAL|SEGFAULT|TRACEBACK|FATAL)\b", re.IGNORECASE)


def _safe_read_text(path: Path) -> str:
    try:
        data = path.read_bytes()
    except OSError:
        return ""

    if not data or b"\x00" in data:
        return ""

    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("utf-8", errors="replace")


def _collect_log_files(extract_root: Path) -> list[Path]:
    files: list[Path] = []
    for path in extract_root.rglob("*"):
        if path.is_file() and path.suffix.lower() in {".log", ".txt", ".out", ".cfg", ".xml", ""}:
            files.append(path)
    return sorted(files)


def _extract_archive(archive_path: Path) -> Path:
    extract_root = Path(tempfile.mkdtemp(prefix="review_rdk_logger_"))
    with tarfile.open(archive_path, "r:gz") as archive:
        archive.extractall(path=extract_root, filter="data")
    return extract_root


def review_tgz_bundle(tgz_path: str | Path) -> dict[str, Any]:
    archive_path = Path(tgz_path)
    extract_root = _extract_archive(archive_path)

    log_files = _collect_log_files(extract_root)
    keyword_hits: dict[str, int] = {}
    highlight_set: set[str] = set()
    reviewed_count = 0

    for log_file in log_files:
        text = _safe_read_text(log_file)
        if not text:
            continue

        reviewed_count += 1
        found = {match.upper() for match in KEYWORD_PATTERN.findall(text)}
        for token in found:
            keyword_hits[token] = keyword_hits.get(token, 0) + text.upper().count(token)
            highlight_set.add(token)

    report = {
        "archive": archive_path.name,
        "source_path": str(archive_path),
        "log_files": reviewed_count,
        "error_count": sum(keyword_hits.values()),
        "keywords": sorted(keyword_hits),
        "highlights": sorted(highlight_set),
        "files_reviewed": [str(path.relative_to(extract_root)) for path in log_files],
    }
    return report


def review_directory(input_dir: str | Path) -> list[dict[str, Any]]:
    target_dir = Path(input_dir)
    archives = sorted(target_dir.glob("*.tgz"))
    return [review_tgz_bundle(path) for path in archives]
