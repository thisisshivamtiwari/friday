#!/usr/bin/env python3
"""
Verifies three protocol mechanisms against the real Gemini Live API before they get
implemented in Swift - same discipline as test_gemini_live.py, because guessing field
names from summarized docs has already caused real bugs in this project once.

1. sessionResumption in setup doesn't break the handshake, and a handle can later be
   passed back in a new setup message to resume.
2. contextWindowCompression in setup doesn't break the handshake.
3. THE IMPORTANT ONE: with realtimeInputConfig.automaticActivityDetection.disabled=true,
   does the server actually withhold a response until the client sends activityEnd -
   i.e. can we drive "listen continuously, but only reply when triggered" ourselves,
   instead of relying on the server's own voice-activity-detection turn boundaries?

Usage:
    GEMINI_API_KEY=... ./gemini-live-test-venv/bin/python3 test_manual_turn_control.py
"""
import asyncio
import base64
import json
import math
import os
import struct
import sys

import websockets

MODEL = "gemini-3.1-flash-live-preview"  # confirmed working model from earlier testing


def as_text(raw) -> str:
    return raw.decode("utf-8") if isinstance(raw, bytes) else raw


def sine_wave_pcm16(seconds: float, sample_rate: int = 16000, freq: float = 440.0) -> bytes:
    """A quiet test tone - real audio content, not silence, since some VAD/ASR paths
    treat true silence specially. We don't care what it transcribes to for this test."""
    n = int(seconds * sample_rate)
    samples = [int(3000 * math.sin(2 * math.pi * freq * i / sample_rate)) for i in range(n)]
    return struct.pack(f"<{n}h", *samples)


async def connect(api_key: str):
    url = (
        "wss://generativelanguage.googleapis.com/ws/"
        "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        f"?key={api_key}"
    )
    return await websockets.connect(url, max_size=10 * 1024 * 1024)


async def test_setup_fields_accepted(api_key: str):
    """Confirms sessionResumption + contextWindowCompression don't break the handshake."""
    print("\n=== Test 1: sessionResumption + contextWindowCompression in setup ===")
    setup = {
        "setup": {
            "model": f"models/{MODEL}",
            "generationConfig": {"responseModalities": ["AUDIO"]},
            "systemInstruction": {"parts": [{"text": "You are a terse test assistant."}]},
            "outputAudioTranscription": {},
            "sessionResumption": {},
            "contextWindowCompression": {
                "triggerTokens": 20000,
                "slidingWindow": {"targetTokens": 10000},
            },
        }
    }
    async with await connect(api_key) as ws:
        await ws.send(json.dumps(setup))
        print(">> sent setup with sessionResumption + contextWindowCompression")
        raw = as_text(await asyncio.wait_for(ws.recv(), timeout=15))
        print("<<", raw[:300])
        if "setupComplete" not in raw:
            print("⚠️  FAILED - setup with these fields was rejected")
            return False
        print("✅ setupComplete - both fields accepted")

        # Send a trivial text turn and confirm we get a sessionResumptionUpdate with a handle
        await ws.send(json.dumps({
            "clientContent": {
                "turns": [{"role": "user", "parts": [{"text": "Say hi."}]}],
                "turnComplete": True,
            }
        }))
        saw_handle = False
        try:
            async with asyncio.timeout(15):
                while True:
                    raw = as_text(await ws.recv())
                    data = json.loads(raw)
                    if "sessionResumptionUpdate" in data:
                        handle = data["sessionResumptionUpdate"].get("newHandle")
                        print(f"✅ Got sessionResumptionUpdate handle: {handle}")
                        saw_handle = True
                    if data.get("serverContent", {}).get("turnComplete"):
                        break
        except (asyncio.TimeoutError, TimeoutError):
            pass
        return saw_handle


async def test_manual_activity_boundary(api_key: str):
    """THE key test: does disabling automaticActivityDetection actually withhold a
    response until we send activityEnd ourselves, even though we keep streaming audio
    and waiting well past when automatic VAD would normally have triggered a reply?"""
    print("\n=== Test 2: manual activityStart/activityEnd turn control ===")
    setup = {
        "setup": {
            "model": f"models/{MODEL}",
            "generationConfig": {"responseModalities": ["AUDIO"]},
            "systemInstruction": {"parts": [{"text": "You are a terse test assistant."}]},
            "outputAudioTranscription": {},
            "inputAudioTranscription": {},
            "realtimeInputConfig": {
                "automaticActivityDetection": {"disabled": True}
            },
        }
    }
    async with await connect(api_key) as ws:
        await ws.send(json.dumps(setup))
        raw = as_text(await asyncio.wait_for(ws.recv(), timeout=15))
        print("<<", raw[:300])
        if "setupComplete" not in raw:
            print("⚠️  FAILED - automaticActivityDetection.disabled setup was rejected")
            return False
        print("✅ setupComplete with automatic VAD disabled")

        await ws.send(json.dumps({"realtimeInput": {"activityStart": {}}}))
        print(">> sent activityStart")

        chunk = sine_wave_pcm16(1.0)
        b64 = base64.b64encode(chunk).decode("ascii")
        for _ in range(4):
            await ws.send(json.dumps({
                "realtimeInput": {"audio": {"mimeType": "audio/pcm;rate=16000", "data": b64}}
            }))
            await asyncio.sleep(1)
        print(">> streamed 4s of audio, well past when auto-VAD would normally reply")

        # Confirm NOTHING resembling a real reply arrived yet (no turnComplete)
        got_early_turn_complete = False
        try:
            async with asyncio.timeout(3):
                while True:
                    raw = as_text(await ws.recv())
                    print("<< (unexpected, before activityEnd):", raw[:200])
                    data = json.loads(raw)
                    if data.get("serverContent", {}).get("turnComplete"):
                        got_early_turn_complete = True
        except (asyncio.TimeoutError, TimeoutError):
            pass

        if got_early_turn_complete:
            print("❌ Got turnComplete BEFORE activityEnd - manual control did not withhold the reply")
            return False
        print("✅ No reply arrived despite 4s of audio and a 3s extra wait - manual gating is holding")

        await ws.send(json.dumps({"realtimeInput": {"activityEnd": {}}}))
        print(">> sent activityEnd - now expecting a real reply")

        try:
            async with asyncio.timeout(15):
                while True:
                    raw = as_text(await ws.recv())
                    data = json.loads(raw)
                    server_content = data.get("serverContent", {})
                    if "text" in server_content.get("outputTranscription", {}):
                        print("<< outputTranscription:", server_content["outputTranscription"]["text"])
                    if server_content.get("turnComplete"):
                        print("✅ turnComplete arrived AFTER activityEnd, as expected")
                        return True
        except (asyncio.TimeoutError, TimeoutError):
            print("⚠️  No reply arrived even after activityEnd")
            return False


async def main():
    api_key = os.environ.get("GEMINI_API_KEY") or (sys.argv[1] if len(sys.argv) > 1 else None)
    if not api_key:
        print("Usage: python3 test_manual_turn_control.py YOUR_API_KEY  (or set GEMINI_API_KEY)")
        sys.exit(1)

    r1 = await test_setup_fields_accepted(api_key)
    r2 = await test_manual_activity_boundary(api_key)

    print("\n=== Summary ===")
    print(f"sessionResumption + contextWindowCompression accepted, handle received: {r1}")
    print(f"manual activityStart/activityEnd controls when a reply is generated: {r2}")


if __name__ == "__main__":
    asyncio.run(main())
