#!/usr/bin/env python3
"""
Puente automático Log-to-Trace para Mattermost, Loki y Tempo.
Convierte los request_id de Mattermost y los traceID de Loki en trazas OTLP válidas en Tempo.
"""
import os
import re
import time
import json
import glob
import hashlib
import urllib.request

TEMPO_URL = os.getenv("TEMPO_ENDPOINT", "http://mattermost-tempo:4318/v1/traces")
LOKI_URL = os.getenv("LOKI_ENDPOINT", "http://mattermost-loki:3100/loki/api/v1/push")
CONTAINERS_DIR = "/var/lib/docker/containers"

# 1. Captura el traceID= de 16 hex en los logs
LOKI_TRACE_RE = re.compile(r'traceID=([a-fA-F0-9]{16})')
# 2. Captura el request_id de Mattermost (con o sin escapes de Docker json-file)
MM_REQ_RE = re.compile(r'request_id\\?":\\?"([a-z0-9]{26})')

seen_ids = set()

def send_trace_to_tempo(trace_id_32, span_id_16, name, service, attributes, is_error=False):
    now_ns = time.time_ns()
    payload = {
        "resourceSpans": [{
            "resource": {
                "attributes": [
                    {"key": "service.name", "value": {"stringValue": service}},
                    {"key": "service.namespace", "value": {"stringValue": "mattermost"}}
                ]
            },
            "scopeSpans": [{
                "scope": {"name": "mattermost-otel-bridge", "version": "1.0.0"},
                "spans": [{
                    "traceId": trace_id_32,
                    "spanId": span_id_16,
                    "name": name,
                    "kind": 2,
                    "startTimeUnixNano": str(now_ns - 45_000_000),
                    "endTimeUnixNano": str(now_ns),
                    "attributes": attributes,
                    "status": {"code": 2 if is_error else 1}
                }]
            }]
        }]
    }
    try:
        req = urllib.request.Request(
            TEMPO_URL,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        urllib.request.urlopen(req, timeout=2)
    except Exception:
        pass

def send_enriched_log_to_loki(log_dict, trace_id_32):
    log_dict["trace_id"] = trace_id_32
    payload = {
        "streams": [{
            "stream": {
                "job": "mattermost",
                "service": "mattermost-app",
                "level": log_dict.get("level", "info")
            },
            "values": [[str(time.time_ns()), json.dumps(log_dict)]]
        }]
    }
    try:
        req = urllib.request.Request(
            LOKI_URL,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        urllib.request.urlopen(req, timeout=2)
    except Exception:
        pass

def process_line(line):
    m_loki = LOKI_TRACE_RE.search(line)
    if m_loki:
        short_id = m_loki.group(1).lower()
        if short_id not in seen_ids:
            seen_ids.add(short_id)
            trace_32 = "0000000000000000" + short_id
            attrs = [
                {"key": "trace.short_id", "value": {"stringValue": short_id}},
                {"key": "log.raw", "value": {"stringValue": line[:200]}}
            ]
            send_trace_to_tempo(trace_32, short_id, "HTTP GET /loki/api/v1/query", "mattermost-loki", attrs)

    m_mm = MM_REQ_RE.search(line)
    if m_mm:
        req_id = m_mm.group(1)
        if req_id not in seen_ids:
            seen_ids.add(req_id)
            trace_32 = hashlib.md5(req_id.encode()).hexdigest()
            span_16 = trace_32[:16]
            try:
                outer = json.loads(line)
                inner = json.loads(outer.get("log", "{}"))
            except Exception:
                inner = {"msg": line[:200], "request_id": req_id}

            method = inner.get("method", "HTTP")
            url_path = inner.get("url", "/api/v4")
            status = str(inner.get("status_code", "200"))
            is_err = status.startswith(("4", "5")) or inner.get("level") == "error"

            attrs = [
                {"key": "http.method", "value": {"stringValue": method}},
                {"key": "http.url", "value": {"stringValue": url_path}},
                {"key": "http.status_code", "value": {"stringValue": status}},
                {"key": "mattermost.request_id", "value": {"stringValue": req_id}}
            ]
            send_trace_to_tempo(trace_32, span_16, f"{method} {url_path} ({status})", "mattermost-app", attrs, is_err)
            send_enriched_log_to_loki(inner, trace_32)

    if len(seen_ids) > 5000:
        seen_ids.clear()

def main():
    files = {}
    for lf in glob.glob(f"{CONTAINERS_DIR}/*/*-json.log"):
        try:
            f = open(lf, "r", errors="ignore")
            lines = f.readlines()[-100:]
            for l in lines:
                process_line(l)
            files[lf] = f
        except Exception:
            pass

    while True:
        for lf in glob.glob(f"{CONTAINERS_DIR}/*/*-json.log"):
            if lf not in files:
                try:
                    f = open(lf, "r", errors="ignore")
                    f.seek(0, os.SEEK_END)
                    files[lf] = f
                except Exception:
                    continue

        for lf, f in list(files.items()):
            try:
                line = f.readline()
                while line:
                    process_line(line)
                    line = f.readline()
            except Exception:
                pass
        time.sleep(0.3)

if __name__ == "__main__":
    main()
