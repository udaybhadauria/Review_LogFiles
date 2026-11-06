# Review RDK Logger

This project is designed to review RDK log bundles stored as `.tgz` archives.

## Purpose

- Untar each log archive
- Scan extracted log files for likely issues
- Highlight common error keywords such as `ERROR`, `PANIC`, `FAIL`, and `EXCEPTION`
- Produce a compact JSON report for each archive

## Quick start

```bash
python -m review_rdk_logger --directory .
```

Or review a single archive:

```bash
python -m review_rdk_logger "00CB7AC3E122_Logs_11-01-26-04-37PM.tgz"
```

## Output

The tool writes a JSON summary to stdout. It also supports writing to a file with `--output report.json`.
