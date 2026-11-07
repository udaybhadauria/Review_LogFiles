FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    REVIEW_DATA_DIR=/data \
    APP_HOST=0.0.0.0 \
    APP_PORT=5001

WORKDIR /app
COPY pyproject.toml README.md ./
COPY src ./src
RUN pip install . && useradd --system --uid 10001 --home-dir /data review && mkdir -p /data && chown review /data

USER review
VOLUME ["/data"]
EXPOSE 5001

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD \
  python -c "import os,ssl,urllib.request as u; s=os.environ.get('APP_SSL','1').lower() not in ('0','false','no','off'); u.urlopen(('https' if s else 'http')+'://127.0.0.1:'+os.environ.get('APP_PORT','5001')+'/healthz', context=ssl._create_unverified_context(), timeout=4)"

CMD ["review-rdk-web"]
