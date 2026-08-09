#!/usr/bin/env python3
"""
Lists every model this API key can see, filtered to ones that support
bidiGenerateContent (the Live API) - i.e. the authoritative source of truth for which
model name to actually use, instead of guessing preview model ids.

Usage:
    GEMINI_API_KEY=... ./gemini-live-test-venv/bin/python3 list_live_models.py
"""
import json
import os
import sys
import urllib.request

api_key = os.environ.get("GEMINI_API_KEY") or (sys.argv[1] if len(sys.argv) > 1 else None)
if not api_key:
    print("Usage: python3 list_live_models.py YOUR_API_KEY  (or set GEMINI_API_KEY)")
    sys.exit(1)

url = f"https://generativelanguage.googleapis.com/v1beta/models?key={api_key}&pageSize=200"

with urllib.request.urlopen(url) as resp:
    data = json.load(resp)

models = data.get("models", [])
live_models = [m for m in models if "bidiGenerateContent" in m.get("supportedGenerationMethods", [])]

print(f"Total models visible to this key: {len(models)}")
print(f"Models supporting bidiGenerateContent (Live API): {len(live_models)}\n")

for m in live_models:
    name = m.get("name", "?")
    display = m.get("displayName", "")
    print(f"- {name}  ({display})")

if not live_models:
    print("No Live-capable models found for this key/account.")
