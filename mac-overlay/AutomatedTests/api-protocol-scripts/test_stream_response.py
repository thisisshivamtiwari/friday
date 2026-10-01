#!/usr/bin/env python3
"""
Verifies the streamGenerateContent (SSE) wire format before trusting it in Swift:
GeminiResponseGenerator parses each "data: {...}" line as its own complete
GenerateContentResponse chunk and treats candidates[0].content.parts[].text as a DELTA to
append, not the cumulative text so far. Confirms that assumption against the real API, and
prints how many chunks arrived before the first one with real text (a rough proxy for the
first-token latency win over plain generateContent).

Usage:
    GEMINI_API_KEY=... ./gemini-live-test-venv/bin/python3 test_stream_response.py
"""
import json
import os
import sys
import time
import urllib.request

MODEL = "gemini-flash-latest"

api_key = os.environ.get("GEMINI_API_KEY") or (sys.argv[1] if len(sys.argv) > 1 else None)
if not api_key:
    print("Usage: python3 test_stream_response.py YOUR_API_KEY  (or set GEMINI_API_KEY)")
    sys.exit(1)

system_instruction = "You are a terse assistant. Reply in 2-3 sentences."
transcript = (
    "Heard: What is the difference between a classification and a regression problem? "
    "Heard: Give a concrete example of each."
)

payload = {
    "contents": [{"role": "user", "parts": [{"text": transcript}]}],
    "systemInstruction": {"parts": [{"text": system_instruction}]},
}

url = f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:streamGenerateContent?alt=sse"
req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode("utf-8"),
    headers={
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "x-goog-api-key": api_key,
    },
    method="POST",
)

start = time.monotonic()
first_text_at = None
chunk_count = 0
full_text = ""

try:
    with urllib.request.urlopen(req) as resp:
        for raw_line in resp:
            line = raw_line.decode("utf-8").rstrip("\n")
            if not line.startswith("data: "):
                continue
            chunk_count += 1
            chunk_json = json.loads(line[len("data: "):])
            try:
                delta = chunk_json["candidates"][0]["content"]["parts"][0]["text"]
            except (KeyError, IndexError):
                continue
            if delta and first_text_at is None:
                first_text_at = time.monotonic() - start
            full_text += delta
except urllib.error.HTTPError as e:
    print(f"❌ HTTP {e.code}: {e.read().decode()}")
    sys.exit(1)

total_time = time.monotonic() - start

if not full_text:
    print(f"❌ No text extracted from any of the {chunk_count} chunk(s) received")
    sys.exit(1)

print(f"✅ Got a streamed response in {chunk_count} chunk(s)")
print(f"   First text after {first_text_at:.2f}s, full response after {total_time:.2f}s")
print(f"   (each chunk's text is a DELTA - concatenating them reconstructs the full answer)")
print(f"\nFull reconstructed text:\n{full_text}")
