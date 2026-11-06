import tarfile
from pathlib import Path

from review_rdk_logger.reviewer import review_tgz_bundle


def test_review_tgz_bundle_extracts_and_reports_errors(tmp_path):
    log_dir = tmp_path / "logs"
    log_dir.mkdir()
    (log_dir / "system.log").write_text(
        "INFO boot complete\nERROR network unreachable\nWARN retrying\n",
        encoding="utf-8",
    )
    (log_dir / "second.log").write_text(
        "PANIC system halted\nINFO recovery started\n",
        encoding="utf-8",
    )

    archive_path = tmp_path / "sample_logs.tgz"
    with tarfile.open(archive_path, "w:gz") as tf:
        for path in log_dir.iterdir():
            tf.add(path, arcname=path.name)

    report = review_tgz_bundle(archive_path)

    assert report["archive"] == archive_path.name
    assert report["log_files"] >= 2
    assert report["error_count"] >= 2
    assert "ERROR" in report["highlights"]
    assert "PANIC" in report["highlights"]
