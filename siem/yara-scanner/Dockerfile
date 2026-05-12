# YARA scanner — a small Python watcher that runs yara-python against new
# files in WATCH_DIR and emits JSONL alerts to LOG_FILE for Promtail.
#
# Built on python:3.12-slim. The yara-python wheels include the matching
# libyara, so no system yara install needed.

FROM python:3.12-slim

LABEL org.opencontainers.image.title="secvf-yara-scanner"
LABEL org.opencontainers.image.description="Watches a directory for new files and scans them against a YARA rule set; emits JSONL alerts."
LABEL org.opencontainers.image.source="https://github.com/DaxxSec/SecVF"
LABEL org.opencontainers.image.licenses="MIT"

# yara-python + watchdog for inotify-style file watching
RUN pip install --no-cache-dir \
        yara-python==4.5.1 \
        watchdog==5.0.3

# Run as an unprivileged user
RUN groupadd --system --gid 10001 yara \
 && useradd  --system --uid 10001 --gid yara --no-create-home yara

WORKDIR /app
COPY scanner.py /app/scanner.py
RUN chown yara:yara /app/scanner.py

USER yara:yara

# Tunables (override in compose via `environment:`)
ENV WATCH_DIR=/quarantine
ENV RULES_DIR=/yara-rules
ENV LOG_FILE=/var/log/yara/scan.jsonl
ENV INITIAL_SCAN=true
ENV MAX_FILE_SIZE_MB=100

CMD ["python", "-u", "/app/scanner.py"]
