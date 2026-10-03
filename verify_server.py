#!/usr/bin/env python3
# server-side OpenAI key check (GET /verify), plus per-IP key storage
# (GET/POST /keys) so each caller's machine can save more than one key
# and get them back without re-pasting.
#
# keys are stored in plain text in keys_store.json, bucketed by whatever
# IP the request came from. fine for a LAN/dev tool, not for anything
# exposed to the open internet.

import http.server
import json
import os
import secrets
import time
import urllib.request
import urllib.error
from urllib.parse import urlparse, parse_qs

OPENAI_CHECK_URL = "https://api.openai.com/v1/models"
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
KEYS_FILE = os.path.join(BASE_DIR, "keys_store.json")
TOKEN_FILE = os.path.join(BASE_DIR, "server_token.txt")


def load_keys():
    if not os.path.exists(KEYS_FILE):
        return {}
    try:
        with open(KEYS_FILE) as f:
            return json.load(f)
    except (ValueError, OSError):
        return {}


def save_keys(store):
    tmp = KEYS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(store, f, indent=2)
    os.replace(tmp, KEYS_FILE)
    os.chmod(KEYS_FILE, 0o600)


def load_or_create_token():
    if os.path.exists(TOKEN_FILE):
        with open(TOKEN_FILE) as f:
            existing = f.read().strip()
            if existing:
                return existing
    token = secrets.token_urlsafe(24)
    with open(TOKEN_FILE, "w") as f:
        f.write(token)
    os.chmod(TOKEN_FILE, 0o600)
    return token


KEY_STORE = load_keys()
AUTH_TOKEN = load_or_create_token()


class Handler(http.server.BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Auth-Token")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/verify":
            self._handle_verify()
            return

        if parsed.path == "/keys":
            if not self._check_auth():
                return
            self._handle_list_keys(parse_qs(parsed.query))
            return

        self.send_response(404)
        self._cors()
        self.end_headers()

    def do_POST(self):
        if self.path == "/keys":
            if not self._check_auth():
                return
            self._handle_save_key()
            return

        self.send_response(404)
        self._cors()
        self.end_headers()

    def do_DELETE(self):
        if self.path == "/keys":
            if not self._check_auth():
                return
            self._handle_delete_key()
            return

        self.send_response(404)
        self._cors()
        self.end_headers()

    def _check_auth(self) -> bool:
        given = self.headers.get("X-Auth-Token", "")
        if not secrets.compare_digest(given, AUTH_TOKEN):
            self._reply(401, {"status": "error", "message": "missing or wrong X-Auth-Token header"})
            return False
        return True

    def _read_json_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw)
        except ValueError:
            return {}

    def _handle_verify(self):
        auth = self.headers.get("Authorization", "")
        key = auth[7:] if auth.startswith("Bearer ") else ""

        if not key:
            self._reply(400, {"status": "invalid", "message": "no API key given"})
            return

        req = urllib.request.Request(OPENAI_CHECK_URL, headers={"Authorization": "Bearer " + key})
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read())
                model_count = len(data.get("data", []))
                self._reply(200, {"status": "ok", "message": f"key works, {model_count} models visible"})
        except urllib.error.HTTPError as e:
            body = e.read()
            try:
                msg = json.loads(body).get("error", {}).get("message", e.reason)
            except (ValueError, AttributeError):
                msg = e.reason
            self._reply(e.code, {"status": "invalid", "message": f"OpenAI said: {msg}"})
        except urllib.error.URLError as e:
            self._reply(502, {"status": "invalid", "message": f"could not reach OpenAI: {e.reason}"})

    def _handle_list_keys(self, query):
        ip = self.client_address[0]
        entries = KEY_STORE.get(ip, [])
        provider = query.get("provider", [None])[0]
        if provider:
            entries = [e for e in entries if e.get("provider") == provider]
        self._reply(200, {"status": "ok", "keys": entries})

    def _handle_save_key(self):
        ip = self.client_address[0]
        data = self._read_json_body()
        provider = str(data.get("provider", "")).strip()
        key = str(data.get("key", "")).strip()

        if not provider or not key:
            self._reply(400, {"status": "invalid", "message": "need both provider and key"})
            return

        entries = KEY_STORE.setdefault(ip, [])
        if not any(e["provider"] == provider and e["key"] == key for e in entries):
            entries.append({"provider": provider, "key": key, "added": int(time.time())})
            save_keys(KEY_STORE)

        self._reply(200, {"status": "ok", "keys": entries})

    def _handle_delete_key(self):
        ip = self.client_address[0]
        data = self._read_json_body()
        provider = str(data.get("provider", "")).strip()
        key = str(data.get("key", "")).strip()

        entries = KEY_STORE.get(ip, [])
        before = len(entries)
        entries[:] = [e for e in entries if not (e["provider"] == provider and e["key"] == key)]
        if len(entries) != before:
            save_keys(KEY_STORE)

        self._reply(200, {"status": "ok", "keys": entries})

    def _reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print("[verify_server]", fmt % args)


if __name__ == "__main__":
    port = 8070
    print(f"verify server on 0.0.0.0:{port}")
    print("  GET    /verify          - checks a key against OpenAI (Authorization: Bearer header)")
    print("  GET    /keys[?provider] - list keys saved by your IP  [needs X-Auth-Token]")
    print("  POST   /keys            - save {\"provider\":..,\"key\":..} for your IP  [needs X-Auth-Token]")
    print("  DELETE /keys            - remove {\"provider\":..,\"key\":..} for your IP  [needs X-Auth-Token]")
    print()
    print(f"  auth token (put in X-Auth-Token header): {AUTH_TOKEN}")
    print(f"  token also saved at: {TOKEN_FILE}")
    print("  anyone on your LAN can reach this port - the token is what keeps them out of /keys.")
    http.server.HTTPServer(("0.0.0.0", port), Handler).serve_forever()
