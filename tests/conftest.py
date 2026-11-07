import os
import tempfile

# Must be set before review_rdk_logger.web is imported so tests never touch real data.
os.environ["REVIEW_DATA_DIR"] = tempfile.mkdtemp(prefix="review_rdk_test_")
os.environ.setdefault("FLASK_SECRET_KEY", "test")
