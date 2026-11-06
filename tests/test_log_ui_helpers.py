import tarfile
from pathlib import Path

from app import extract_mac_candidates, build_archive_catalog


def test_extract_mac_candidates_from_tarball_names():
    names = [
        "00CB7AC3E122_Logs_11-01-26-04-37PM.tgz",
        "00CB7AC3E122_Logs_11-02-26-01-44AM.tgz",
        "00D3A5F11200_Logs_11-02-26-06-32AM.tgz",
        "00D3A5F11200_Logs_11-03-26-11-11AM.tgz",
    ]

    macs = extract_mac_candidates(names)
    assert macs == ["00:CB:7A:C3:E1:22", "00:D3:A5:F1:12:00"]


def test_build_archive_catalog_groups_logs_by_mac(tmp_path):
    tar_paths = []
    for i, name in enumerate([
        "00CB7AC3E122_Logs_11-01-26-04-37PM.tgz",
        "00D3A5F11200_Logs_11-02-26-06-32AM.tgz",
    ]):
        tar_path = tmp_path / name
        with tarfile.open(tar_path, "w:gz") as tf:
            content_a = "ERROR boot failed\n" if i == 0 else "INFO ok\n"
            content_b = "WARN gateway retry\n" if i == 0 else "PANIC reboot\n"
            info1 = tarfile.TarInfo("nvram2/logs/a.log")
            info1.size = len(content_a.encode())
            tf.addfile(info1, fileobj=__import__("io").BytesIO(content_a.encode()))
            info2 = tarfile.TarInfo("nvram2/logs/b.log")
            info2.size = len(content_b.encode())
            tf.addfile(info2, fileobj=__import__("io").BytesIO(content_b.encode()))
        tar_paths.append(tar_path)

    catalog = build_archive_catalog(tmp_path)

    assert catalog["macs"] == ["00:CB:7A:C3:E1:22", "00:D3:A5:F1:12:00"]
    assert "nvram2/logs/a.log" in catalog["by_mac"]["00:CB:7A:C3:E1:22"][0]["log_files"]
    assert "nvram2/logs/b.log" in catalog["by_mac"]["00:CB:7A:C3:E1:22"][0]["log_files"]
