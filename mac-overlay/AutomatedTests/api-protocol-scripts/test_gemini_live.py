#!/usr/bin/env python3
"""
Sanity-checks the Gemini Live API (BidiGenerateContent over WebSocket) using the exact
same setup-message shape GeminiLiveClient.swift sends, so wire-format issues surface
here instead of inside the Mac app.

Usage:
    ./gemini-live-test-venv/bin/python3 test_gemini_live.py YOUR_API_KEY
    # or: GEMINI_API_KEY=... ./gemini-live-test-venv/bin/python3 test_gemini_live.py

Tries a short list of candidate Live model ids (these preview names shift often) and
reports which one actually accepts the setup message and completes a round trip.
"""
import asyncio
import json
import os
import sys

import websockets

CANDIDATE_MODELS = [
    # Confirmed via ListModels to support bidiGenerateContent for this key - tried in
    # order of most likely to support response_modalities=TEXT (the native-audio family
    # is audio-to-audio only, confirmed by an earlier test run that rejected TEXT)
    "gemini-3.1-flash-live-preview",
    "gemini-2.5-flash-native-audio-preview-09-2025",
]


def build_setup(model: str) -> dict:
    # All 6 Live-capable models for this key rejected responseModalities=TEXT (audio-to-audio
    # is mandatory), so: request AUDIO (required) but also ask for outputAudioTranscription,
    # which gives a text transcript of the spoken reply alongside the audio. We'll discard the
    # audio bytes client-side and use that transcript as the suggestion text.
    return {
        "setup": {
            "model": f"models/{model}",
            "generationConfig": {"responseModalities": ["AUDIO"]},
            "systemInstruction": {
                "parts": [{"text": "You are a terse test assistant. Reply in one short sentence."}]
            },
            "inputAudioTranscription": {},
            "outputAudioTranscription": {},
        }
    }


def as_text(raw) -> str:
    """The server mixes text and binary WebSocket frames for equivalent JSON payloads -
    normalize both to str before parsing/searching, matching what GeminiLiveClient.swift
    already does (it decodes .data frames as UTF-8 text too)."""
    return raw.decode("utf-8") if isinstance(raw, bytes) else raw


TEST_TURN = {
    "clientContent": {
        "turns": [{"role": "user", "parts": [{"text": "Say hello in five words or fewer."}]}],
        "turnComplete": True,
    }
}


async def try_model(api_key: str, model: str) -> bool:
    url = (
        "wss://generativelanguage.googleapis.com/ws/"
        "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        f"?key={api_key}"
    )
    print(f"\n=== Trying model: {model} ===")
    try:
        async with websockets.connect(url, max_size=10 * 1024 * 1024) as ws:
            await ws.send(json.dumps(build_setup(model)))
            print(">> sent setup")

            raw = as_text(await asyncio.wait_for(ws.recv(), timeout=15))
            print("<<", raw[:500])

            if "setupComplete" not in raw:
                print("⚠️  No setupComplete - this model/setup shape was rejected.")
                return False
            print("✅ setupComplete - setup message shape is accepted for this model.")

            await ws.send(json.dumps(TEST_TURN))
            print(">> sent test turn")

            transcript_so_far = ""
            while True:
                raw = as_text(await asyncio.wait_for(ws.recv(), timeout=20))
                data = json.loads(raw)
                server_content = data.get("serverContent", {})

                output_transcription = server_content.get("outputTranscription", {})
                if "text" in output_transcription:
                    transcript_so_far += output_transcription["text"]
                    print(f"<< outputTranscription delta: {output_transcription['text']!r}")
                else:
                    print("<<", raw[:300])

                if server_content.get("turnComplete"):
                    print(f"✅ turnComplete - full round trip works. Transcribed reply: {transcript_so_far!r}")
                    return True
    except asyncio.TimeoutError:
        print("⚠️  Timed out waiting for a response.")
        return False
    except websockets.exceptions.InvalidStatusCode as e:
        print(f"⚠️  Connection rejected: {e}")
        return False
    except Exception as e:
        print(f"⚠️  Error: {e!r}")
        return False


async def main():
    api_key = os.environ.get("GEMINI_API_KEY") or (sys.argv[1] if len(sys.argv) > 1 else None)
    if not api_key:
        print("Usage: python3 test_gemini_live.py YOUR_API_KEY  (or set GEMINI_API_KEY)")
        sys.exit(1)

    for model in CANDIDATE_MODELS:
        if await try_model(api_key, model):
            print(f"\n🎉 Working model id: {model}")
            print("   Set this as the Gemini model in the app's Settings if it differs from the current default.")
            return

    print("\n❌ None of the candidate models completed a round trip. See errors above.")


if __name__ == "__main__":
    asyncio.run(main())
