"""SecVF YARA file-scanner — watches a directory for new files, runs them
against a compiled YARA rule set, emits JSONL events Promtail tails.

Reads-only the watched directory. Writes only to LOG_FILE. No network."""
from __future__ import annotations

import hashlib
import json
import logging
import os
import pathlib
import signal
import sys
import time
from datetime import datetime, timezone

import yara
from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

LOG = logging.getLogger("yara-scanner")
WATCH_DIR    = pathlib.Path(os.environ.get("WATCH_DIR", "/quarantine"))
RULES_DIR    = pathlib.Path(os.environ.get("RULES_DIR", "/yara-rules"))
LOG_FILE     = pathlib.Path(os.environ.get("LOG_FILE", "/var/log/yara/scan.jsonl"))
DO_INITIAL   = os.environ.get("INITIAL_SCAN", "true").lower() == "true"
MAX_FILE_MB  = int(os.environ.get("MAX_FILE_SIZE_MB", "100"))
MAX_BYTES    = MAX_FILE_MB * 1024 * 1024


def compile_rules() -> yara.Rules | None:
    """Compile every `.yar`/`.yara` under RULES_DIR. Returns None if no rules."""
    candidates = {}
    for ext in ("*.yar", "*.yara"):
        for path in RULES_DIR.rglob(ext):
            # Namespace by relative path so duplicate rule names don't collide
            ns = str(path.relative_to(RULES_DIR).with_suffix(""))
            candidates[ns] = str(path)
    if not candidates:
        LOG.warning("No YARA rules found in %s", RULES_DIR)
        return None
    LOG.info("Compiling %d YARA rule files", len(candidates))
    return yara.compile(filepaths=candidates)


def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def emit(record: dict) -> None:
    """Append one JSON object to LOG_FILE, one line."""
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    record.setdefault("ts", datetime.now(timezone.utc).isoformat())
    with LOG_FILE.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def scan_file(rules: yara.Rules, path: pathlib.Path) -> None:
    """Scan one file, emit zero-or-more match records + a scan summary."""
    try:
        st = path.stat()
    except FileNotFoundError:
        return  # file disappeared between detection and scan

    if not st.st_size:
        return  # empty file, skip
    if st.st_size > MAX_BYTES:
        emit({"event": "scan.skipped", "reason": "too-large",
              "file": str(path), "size_bytes": st.st_size})
        return

    try:
        digest = sha256(path)
    except (OSError, PermissionError) as e:
        emit({"event": "scan.error", "file": str(path), "error": str(e)})
        return

    try:
        matches = rules.match(str(path), timeout=60)
    except yara.Error as e:
        emit({"event": "scan.error", "file": str(path), "error": str(e),
              "sha256": digest})
        return

    # Always emit a "scanned" record so we can prove a file was checked
    emit({
        "event": "scan.done",
        "file": str(path),
        "sha256": digest,
        "size_bytes": st.st_size,
        "match_count": len(matches),
    })

    for m in matches:
        emit({
            "event": "scan.match",
            "file": str(path),
            "sha256": digest,
            "size_bytes": st.st_size,
            "rule": m.rule,
            "namespace": m.namespace,
            "tags": list(m.tags),
            "meta": dict(m.meta) if m.meta else {},
            "strings_matched": len(m.strings),
        })

    LOG.info("scanned %s sha256=%s matches=%d", path, digest[:12], len(matches))


class Handler(FileSystemEventHandler):
    def __init__(self, rules: yara.Rules) -> None:
        self.rules = rules

    def _maybe_scan(self, p: str) -> None:
        path = pathlib.Path(p)
        if not path.is_file():
            return
        # Tiny debounce: wait for the writer to finish
        time.sleep(0.5)
        scan_file(self.rules, path)

    def on_created(self, event):
        if not event.is_directory:
            self._maybe_scan(event.src_path)

    def on_moved(self, event):
        if not event.is_directory:
            self._maybe_scan(event.dest_path)


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    if not WATCH_DIR.exists():
        LOG.error("WATCH_DIR %s does not exist (is it mounted?)", WATCH_DIR)
        return 1

    rules = compile_rules()
    if rules is None:
        # No rules — keep running so the container doesn't crashloop;
        # operators may add rules later and restart.
        LOG.warning("Running without rules; restart after adding files to %s", RULES_DIR)
        while True:
            time.sleep(60)

    emit({"event": "scanner.started",
          "watch_dir": str(WATCH_DIR),
          "rules_dir": str(RULES_DIR)})

    if DO_INITIAL:
        LOG.info("Initial sweep of %s", WATCH_DIR)
        for f in WATCH_DIR.rglob("*"):
            if f.is_file():
                scan_file(rules, f)

    observer = Observer()
    observer.schedule(Handler(rules), str(WATCH_DIR), recursive=True)
    observer.start()

    stop = False
    def _stop(*_):
        nonlocal stop
        stop = True
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    try:
        while not stop:
            time.sleep(1)
    finally:
        observer.stop()
        observer.join()
        emit({"event": "scanner.stopped"})

    return 0


if __name__ == "__main__":
    sys.exit(main())
