from __future__ import annotations

import re
import tarfile
from collections import Counter
from pathlib import Path
from typing import Any, Iterator

KEYWORD_PATTERN = re.compile(
    r"\b(ERROR|WARN|WARNING|PANIC|FAIL|FAILED|EXCEPTION|CRITICAL|SEGFAULT|TRACEBACK|FATAL)\b", re.IGNORECASE
)
WARN_KEYWORDS = frozenset({"WARN", "WARNING"})
LOG_SUFFIXES = frozenset({".log", ".txt", ".out", ".cfg", ".xml", ".json", ".csv", ".ini", ".conf", ".db", ""})
ARCHIVE_GLOBS = ("*.tgz", "*.tar.gz")
_ROTATION_SUFFIX = re.compile(r"(\.\d+)+$")


def is_log_member(name: str) -> bool:
    """True for text-like log files, including rotated ones such as ``PAMlog.txt.0``."""
    base = _ROTATION_SUFFIX.sub("", name.rsplit("/", 1)[-1])
    return bool(base) and Path(base).suffix.lower() in LOG_SUFFIXES


def decode_text(data: bytes) -> str | None:
    if b"\x00" in data[:8192]:
        return None
    return data.decode("utf-8", errors="replace")


def scan_text(text: str) -> Counter[str]:
    return Counter(match.upper() for match in KEYWORD_PATTERN.findall(text))


def severity_counts(hits: Counter[str]) -> dict[str, int]:
    warn = sum(count for key, count in hits.items() if key in WARN_KEYWORDS)
    return {"error": sum(hits.values()) - warn, "warn": warn}


def find_archives(directory: str | Path) -> list[Path]:
    target = Path(directory)
    return sorted({path for pattern in ARCHIVE_GLOBS for path in target.glob(pattern) if path.is_file()})


def iter_archive_logs(archive_path: str | Path) -> Iterator[tuple[str, str]]:
    """Yield ``(member_name, text)`` for every text log inside the archive, without extracting to disk."""
    with tarfile.open(archive_path, "r:*") as archive:
        for member in archive:
            if not member.isfile() or not is_log_member(member.name):
                continue
            handle = archive.extractfile(member)
            if handle is None:
                continue
            text = decode_text(handle.read())
            if text is not None:
                yield member.name, text


def summarize_archive(archive_path: str | Path) -> dict[str, dict[str, int]]:
    """Per-file error/warn counts, keyed by archive member name."""
    return {name: severity_counts(scan_text(text)) for name, text in iter_archive_logs(archive_path)}


def review_tgz_bundle(tgz_path: str | Path) -> dict[str, Any]:
    archive_path = Path(tgz_path)
    totals: Counter[str] = Counter()
    files: list[dict[str, Any]] = []

    for name, text in iter_archive_logs(archive_path):
        hits = scan_text(text)
        totals.update(hits)
        files.append({"path": name, **severity_counts(hits)})

    reviewed = [entry for entry in files if entry["error"] or entry["warn"]]
    reviewed.sort(key=lambda entry: (entry["error"], entry["warn"]), reverse=True)
    return {
        "archive": archive_path.name,
        "source_path": str(archive_path),
        "log_files": len(files),
        "error_count": sum(totals.values()),
        "keywords": dict(sorted(totals.items())),
        "highlights": sorted(totals),
        "top_files": reviewed[:10],
        "files_reviewed": sorted(entry["path"] for entry in files),
    }


def review_directory(input_dir: str | Path) -> list[dict[str, Any]]:
    return [review_tgz_bundle(path) for path in find_archives(input_dir)]
