import io
import json
import tarfile

import pytest

from review_rdk_logger import __version__, cli
from review_rdk_logger import web as app_module
from review_rdk_logger.reviewer import is_log_member, review_tgz_bundle


def _make_tgz(path, files):
    with tarfile.open(path, "w:gz") as tf:
        for name, content in files.items():
            data = content.encode()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
    return path


@pytest.fixture
def dirs(tmp_path, monkeypatch):
    uploads = tmp_path / "uploads"
    archives = tmp_path / "archives"
    uploads.mkdir()
    archives.mkdir()
    monkeypatch.setattr(app_module, "UPLOAD_DIR", uploads)
    monkeypatch.setattr(app_module, "ARCHIVE_DIR", archives)
    return uploads, archives


@pytest.fixture
def client():
    return app_module.app.test_client()


def test_rotated_logs_are_detected():
    assert is_log_member("nvram2/logs/PAMlog.txt.0")
    assert is_log_member("nvram2/logs/csc_mon.log.12")
    assert is_log_member("nvram2/logs/version.txt")
    assert not is_log_member("nvram2/logs/core.gz")


def test_keyword_counts_do_not_double_count(tmp_path):
    archive = _make_tgz(tmp_path / "x.tgz", {"a.log": "WARNING one\nFAILED two\nERRORS ignored\n"})
    report = review_tgz_bundle(archive)
    assert report["keywords"] == {"FAILED": 1, "WARNING": 1}
    assert report["error_count"] == 2


def test_log_content_reads_archives_outside_uploads(dirs, client):
    _, archives = dirs
    _make_tgz(archives / "00CB7AC3E122_Logs_11-01-26-04-37PM.tgz", {"nvram2/logs/PAMlog.txt.0": "ERROR boom\n"})
    res = client.get("/api/log-content", query_string={"archive": "00CB7AC3E122_Logs_11-01-26-04-37PM.tgz", "path": "nvram2/logs/PAMlog.txt.0"})
    assert res.status_code == 200
    assert res.get_json()["content"] == "ERROR boom\n"


def test_catalog_includes_capture_time_and_rotated_logs(dirs, client):
    _, archives = dirs
    _make_tgz(archives / "00CB7AC3E122_Logs_11-01-26-04-37PM.tgz", {"nvram2/logs/PAMlog.txt.0": "x"})
    entry = client.get("/api/catalog").get_json()["by_mac"]["00:CB:7A:C3:E1:22"][0]
    assert entry["captured_at"] == "2026-11-01T16:37:00"
    assert entry["log_files"] == ["nvram2/logs/PAMlog.txt.0"]
    assert "path" not in entry


@pytest.mark.parametrize("name", ["../secret.tgz", "..", "/etc/passwd", "sub/x.tgz", ".upload-abc"])
def test_archive_name_traversal_is_rejected(dirs, client, name):
    res = client.get("/api/log-content", query_string={"archive": name, "path": "a.log"})
    assert res.status_code == 404


def test_upload_rejects_non_tar_and_accepts_tgz(dirs, client, tmp_path):
    uploads, _ = dirs
    good = _make_tgz(tmp_path / "good.tgz", {"a.log": "INFO\n"})
    res = client.post(
        "/api/upload",
        data={"archives": [(io.BytesIO(b"not a tar"), "evil.tgz"), (good.open("rb"), "good.tgz")]},
        content_type="multipart/form-data",
    )
    body = res.get_json()
    assert body["saved"] == ["good.tgz"]
    assert body["rejected"][0]["name"] == "evil.tgz"
    assert sorted(p.name for p in uploads.iterdir()) == ["good.tgz"]


def test_summary_and_delete_uploaded_archive(dirs, client, tmp_path):
    uploads, archives = dirs
    _make_tgz(uploads / "up.tgz", {"a.log": "ERROR x\nWARN y\n"})
    _make_tgz(archives / "keep.tgz", {"a.log": "ok"})
    assert client.get("/api/summary", query_string={"archive": "up.tgz"}).get_json()["files"] == {
        "a.log": {"error": 1, "warn": 1}
    }
    assert client.delete("/api/archives/keep.tgz").status_code == 404
    assert client.delete("/api/archives/up.tgz").status_code == 200
    assert not (uploads / "up.tgz").exists()


def test_healthz_reports_version(client):
    assert client.get("/healthz").get_json() == {"status": "ok", "version": __version__}


def test_index_serves_packaged_ui(client):
    res = client.get("/")
    assert res.status_code == 200
    assert f"v{__version__}" in res.get_data(as_text=True)
    assert res.headers["X-Content-Type-Options"] == "nosniff"
    assert client.get("/static/app.js").status_code == 200


def test_cli_reviews_directory(tmp_path, capsys, monkeypatch):
    _make_tgz(tmp_path / "a.tgz", {"x.log": "ERROR one\n"})
    monkeypatch.setattr("sys.argv", ["review-rdk-logger", str(tmp_path)])
    assert cli.main() == 0
    assert json.loads(capsys.readouterr().out)[0]["keywords"] == {"ERROR": 1}
