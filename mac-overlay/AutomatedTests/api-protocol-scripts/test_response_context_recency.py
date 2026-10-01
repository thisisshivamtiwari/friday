#!/usr/bin/env python3
"""
Manual verification for Phase 2.5's response-context fix: sends a genuine multi-turn
request (matching what GeminiResponseGenerator.buildContents(from:) now constructs) with an
unrelated earlier topic, then a new topic, and prints the response for a human to read and
judge whether the model stayed on the NEW topic instead of drifting back to the old one.

This is deliberately NOT an XCTest - "did the model answer about the right topic" is a claim
about live model behavior, not about what context Swift constructs (that part IS covered by
GeminiResponseGeneratorTests/ChatSessionManagerTests). No automated assertion here can prove
this reliably run to run, so read the printed response yourself.

Scenario:
  Turn 1 (user):  "Let's discuss apples. Apples are red and sweet."
  Turn 2 (model): "Got it - apples are red and sweet."
  Turn 3 (user):  "Now let's switch topics. Explain gradient descent in one paragraph."

Expected: the response should be substantively about gradient descent, not apples - the
system instruction (copied from AIEngineController.unifiedInstruction) explicitly tells the
model to treat the newest content as primary and only use earlier context when relevant.

Usage:
    GEMINI_API_KEY=... ./gemini-live-test-venv/bin/python3 test_response_context_recency.py
"""
import json
import os
import sys
import urllib.request

MODEL = "gemini-flash-latest"

api_key = os.environ.get("GEMINI_API_KEY") or (sys.argv[1] if len(sys.argv) > 1 else None)
if not api_key:
    print("Usage: python3 test_response_context_recency.py YOUR_API_KEY  (or set GEMINI_API_KEY)")
    sys.exit(1)

# Matches AIEngineController.unifiedInstruction(agentName: "Friday") - keep these in sync if
# that wording changes.
system_instruction = """You are "Friday", an always-listening personal assistant. You're given some \
recent conversation for context, followed by the newest thing heard around the \
user - their own voice and anyone else's, in meetings, calls, or day-to-day life - \
and asked for exactly one substantive, useful response to the newest part.

Use the earlier context only when the newest content actually depends on it - a \
follow-up question, or a reference ("it", "that", "him") pointing at something just \
discussed. If the newest content is a new, unrelated topic, answer it on its own \
terms - don't let earlier context pull your answer back toward whatever was \
discussed before.

If it looks like the user wants help contributing to a live conversation, phrase \
it in the FIRST PERSON as something they could say out loud right now, with real \
structure - a clear point, then a concrete reason or example, not generic filler. \
If it looks like they're asking you something directly, just answer it plainly and \
helpfully. If there's a clear question or problem (including a coding/technical \
problem), solve it directly. No preamble, no meta-commentary about what you're \
doing - just the useful content itself.

Language: reply in the same language as whatever you're actually responding to."""

contents = [
    {"role": "user", "parts": [{"text": "Let's discuss apples. Apples are red and sweet."}]},
    {"role": "model", "parts": [{"text": "Got it - apples are red and sweet."}]},
    {"role": "user", "parts": [{"text": "Now let's switch topics. Explain gradient descent in one paragraph."}]},
]

payload = {
    "contents": contents,
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

full_text = ""
try:
    with urllib.request.urlopen(req) as resp:
        for raw_line in resp:
            line = raw_line.decode("utf-8").rstrip("\n")
            if not line.startswith("data: "):
                continue
            chunk_json = json.loads(line[len("data: "):])
            try:
                full_text += chunk_json["candidates"][0]["content"]["parts"][0]["text"]
            except (KeyError, IndexError):
                continue
except urllib.error.HTTPError as e:
    print(f"❌ HTTP {e.code}: {e.read().decode()}")
    sys.exit(1)

if not full_text:
    print("❌ No text in response")
    sys.exit(1)

mentions_apples = "apple" in full_text.lower()
mentions_gradient = "gradient" in full_text.lower()

print("Sent 3-turn context: apples (user) -> ack (model) -> switch to gradient descent (user)")
print(f"Response mentions 'apple': {mentions_apples}")
print(f"Response mentions 'gradient': {mentions_gradient}")
print("\nFull response (read this yourself - the mention checks above are a hint, not a verdict):\n")
print(full_text)
