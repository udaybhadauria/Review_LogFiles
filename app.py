"""Run the web UI straight from a source checkout: ``python app.py``.

Installed setups should use the ``review-rdk-web`` command instead.
"""

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "src"))
os.environ.setdefault("REVIEW_DATA_DIR", str(ROOT))

from review_rdk_logger.web import app, main  # noqa: E402,F401

if __name__ == "__main__":
    main()
