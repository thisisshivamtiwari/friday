#!/usr/bin/env python3
"""
Quick sanity check for the new "Respond Now" mechanism: a plain one-shot REST call to
generateContent (NOT the Live WebSocket) with the accumulated transcript as context.
Verifies the exact request/response shape before it goes into Swift.

Usage:
    GEMINI_API_KEY=... ./gemini-live-test-venv/bin/python3 test_one_shot_response.py
"""
import json
import os
import sys
import urllib.request

MODEL = "gemini-2.5-flash"

api_key = os.environ.get("GEMINI_API_KEY") or (sys.argv[1] if len(sys.argv) > 1 else None)
if not api_key:
    print("Usage: python3 test_one_shot_response.py YOUR_API_KEY  (or set GEMINI_API_KEY)")
    sys.exit(1)

system_instruction = "You are a terse assistant. Reply in one short sentence."
transcript = (
    "Heard: What is the difference between a classification and a regression problem? "
    "Heard: Give a concrete example of each."
)

payload = {
    "contents": [{"role": "user", "parts": [{"text": transcript}]}],
    "systemInstruction": {"parts": [{"text": system_instruction}]},
}

url = f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent"
req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json", "x-goog-api-key": api_key},
    method="POST",
)

try:
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read())
except urllib.error.HTTPError as e:
    print(f"❌ HTTP {e.code}: {e.read().decode()}")
    sys.exit(1)

try:
    text = data["candidates"][0]["content"]["parts"][0]["text"]
    print(f"✅ Got a real response:\n{text}")
except (KeyError, IndexError):
    print("❌ Unexpected response shape:")
    print(json.dumps(data, indent=2))
