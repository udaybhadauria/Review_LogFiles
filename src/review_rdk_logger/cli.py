from __future__ import annotations

import argparse
import json
from pathlib import Path

from .reviewer import review_directory, review_tgz_bundle


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Review TGZ log bundles and summarize error keywords.")
    parser.add_argument("path", nargs="?", default=".", help="A .tgz file or a directory containing .tgz files")
    parser.add_argument("--output", help="Optional output file for the JSON summary")
    return parser


def main() -> int:
    parser = _build_parser()
    args = parser.parse_args()

    target = Path(args.path)
    if target.is_file() and target.suffix.lower() == ".tgz":
        report = review_tgz_bundle(target)
        data = report
    elif target.is_dir():
        data = review_directory(target)
    else:
        parser.error(f"Path is not a valid .tgz file or directory: {target}")

    output_text = json.dumps(data, indent=2)
    if args.output:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(output_text + "\n", encoding="utf-8")
    else:
        print(output_text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
