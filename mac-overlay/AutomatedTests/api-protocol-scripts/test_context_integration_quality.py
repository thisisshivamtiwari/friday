#!/usr/bin/env python3
"""
Manual verification for Phase 3.4 Stage 7's context-aware response generation: builds the SAME
deterministic five-meeting scenario as MultiMeetingScenarioIntegrationTests.swift (professor
suggestion -> implementation -> poor result -> decision to change -> better result), hand-renders
the "STORED CONTEXT" block the real ContextEngine + CrossLayerConflictResolver +
ContextPacketFormatter pipeline would produce for each of 7 questions (current/historical/
changeReason/whenDecided/two content questions/one unrelated question), sends each to the real
model, and prints everything a human needs to judge quality.

This is deliberately NOT an XCTest - "did the model correctly use CURRENT vs HISTORICAL context,
correctly ignore a superseded fact, correctly answer from evidence vs correctly say it doesn't
know" is a claim about live model judgment, not about what Swift code does with a given context
string (that part IS covered deterministically by ContextPacketFormatterTests/
AIEngineControllerContextIntegrationTests/MultiMeetingScenarioIntegrationTests, all using
constructed ContextPacket values, no network). No automated assertion here can reliably validate
real model judgment run to run - read the printed output yourself against each case's EXPECTED
line.

The context blocks below are hand-authored to MATCH what ContextPacketFormatter.format(_:
questionText:) actually produces (same headings, same "no stored memory" fallback wording, same
[superseded]/[historical] tags) - if that formatter's wording changes, update this script to
match, the same convention test_extraction_quality.py already follows for
ExtractionLLMClient.systemInstruction and test_response_context_recency.py follows for
AIEngineController.unifiedInstruction.

Usage:
    GEMINI_API_KEY=... ./gemini-live-test-venv/bin/python3 test_context_integration_quality.py
"""
import json
import os
import sys
import urllib.request

MODEL = "gemini-flash-latest"  # matches SettingsStore.defaultResponseModel

api_key = os.environ.get("GEMINI_API_KEY") or (sys.argv[1] if len(sys.argv) > 1 else None)
if not api_key:
    print("Usage: python3 test_context_integration_quality.py YOUR_API_KEY  (or set GEMINI_API_KEY)")
    sys.exit(1)

# Kept in sync with AIEngineController.unifiedInstruction - copy the exact wording here if that
# changes (same convention test_response_context_recency.py already uses).
unified_instruction = """You are "Friday", an always-listening personal assistant. You're given some \
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

STORED_CONTEXT_HEADER = (
    "STORED CONTEXT FROM FRIDAY'S MEMORY AND PROJECT HISTORY\n"
    "Everything below was retrieved from previously stored memory, project state, decisions, "
    "and past conversations - NOT from the current conversation above. Use it only if it is "
    "actually relevant to the newest message. Do not repeat or list it unprompted."
)
NOTHING_FOUND = (
    STORED_CONTEXT_HEADER + "\n\n"
    "No stored memory, project, or decision context was found to be relevant to the newest "
    "message. If asked about something from a prior conversation or earlier project history "
    "that isn't shown here, say plainly that you don't have that stored - do not guess or "
    "invent one."
)

# The five-meeting scenario - same facts as MultiMeetingScenarioIntegrationTests.swift.
BAYESIAN_SUGGESTED = "Bayesian calibration - Professor suggested Bayesian calibration for the model. (Meeting 1)"
BAYESIAN_IMPLEMENTED = "Bayesian calibration - Implemented Bayesian calibration for the model. (Meeting 2)"
BAYESIAN_POOR_RESULT = "Bayesian calibration performed poorly. (Meeting 3)"
DECISION_TEMP_SCALING = "Use temperature scaling for calibration going forward (decided in Meeting 4, reason: Bayesian calibration performed poorly)"
TEMP_SCALING_RESULT = "Temperature scaling - Temperature scaling calibration approach performed better than Bayesian calibration. (Meeting 5)"


def context_block(sections):
    """Mirrors ContextPacketFormatter.format(_:questionText:)'s section-joining shape."""
    if not sections:
        return NOTHING_FOUND
    return STORED_CONTEXT_HEADER + "\n\n" + "\n\n".join(sections)


# Each case: label, question, context sections (mirroring what real retrieval+conflict-
# resolution+temporal-filtering would produce for this question), context categories present,
# temporal statuses present, provenance summary, expectation to check the printed response
# against.
cases = [
    {
        "label": "1. current state",
        "question": "What are we currently using for calibration?",
        "sections": [
            "CURRENT KNOWLEDGE (reflects the latest known state - use this when asked what is true NOW):\n"
            f"From decisions:\n- {DECISION_TEMP_SCALING}\n"
            f"From project state:\n- {TEMP_SCALING_RESULT}"
        ],
        "categories": "decisions, project state",
        "temporal": "current only - the superseded Bayesian item is excluded (cross-layer conflict resolution: linked via Decision.relatedItemID)",
        "provenance": "Meeting 4 (decision), Meeting 5 (project state)",
        "expectation": "must answer 'temperature scaling' - must NOT mention Bayesian calibration as the current approach",
    },
    {
        "label": "2. what did we use before",
        "question": "What did we use before temperature scaling?",
        "sections": [
            "HISTORICAL / PRIOR CONTEXT (describes something that used to be true, or has since changed - "
            "NEVER state this as current fact; only use it for \"before\"/\"why did we change\"/\"when was "
            "this decided\"-type questions):\n"
            f"From project state:\n- {BAYESIAN_IMPLEMENTED} [historical]"
        ],
        "categories": "project state (historical)",
        "temporal": "historical - explicitly tagged [historical], never presented as current",
        "provenance": "Meeting 2 (project state)",
        "expectation": "must answer 'Bayesian calibration' - must frame it as past/former, not current",
    },
    {
        "label": "3. why did we change",
        "question": "Why did we move away from Bayesian calibration?",
        "sections": [
            "CURRENT KNOWLEDGE (reflects the latest known state - use this when asked what is true NOW):\n"
            f"From decisions:\n- {DECISION_TEMP_SCALING}",
            "HISTORICAL / PRIOR CONTEXT (describes something that used to be true, or has since changed):\n"
            f"From project state:\n- {BAYESIAN_POOR_RESULT} [historical]",
        ],
        "categories": "decisions (current), project state (historical)",
        "temporal": "both current (the decision) and historical (the poor result it responded to) - preserved together for a changeReason question",
        "provenance": "Meeting 4 (decision + reason), Meeting 3 (poor result)",
        "expectation": "must explain the reason (poor performance) and name both Bayesian calibration and temperature scaling",
    },
    {
        "label": "4. when was the decision made",
        "question": "When did we decide to switch to temperature scaling?",
        "sections": [
            "CURRENT KNOWLEDGE (reflects the latest known state - use this when asked what is true NOW):\n"
            f"From decisions:\n- {DECISION_TEMP_SCALING}"
        ],
        "categories": "decisions",
        "temporal": "current (the decision itself, with its own decided-at provenance)",
        "provenance": "Meeting 4",
        "expectation": "must reference 'Meeting 4' or otherwise indicate the decision's own recorded timing",
    },
    {
        "label": "5. what did the professor suggest",
        "question": "What did the professor suggest?",
        "sections": [
            "HISTORICAL / PRIOR CONTEXT (describes something that used to be true, or has since changed):\n"
            f"From project state:\n- {BAYESIAN_SUGGESTED} [historical]"
        ],
        "categories": "project state (historical)",
        "temporal": "historical",
        "provenance": "Meeting 1",
        "expectation": "must answer 'Bayesian calibration'",
    },
    {
        "label": "6. what happened in the experiment",
        "question": "What happened when we tried Bayesian calibration?",
        "sections": [
            "HISTORICAL / PRIOR CONTEXT (describes something that used to be true, or has since changed):\n"
            f"From project state:\n- {BAYESIAN_IMPLEMENTED} [historical]\n- {BAYESIAN_POOR_RESULT} [historical]"
        ],
        "categories": "project state (historical)",
        "temporal": "historical",
        "provenance": "Meeting 2, Meeting 3",
        "expectation": "must mention it performed poorly",
    },
    {
        "label": "7. unrelated question",
        "question": "What's a good recipe for pasta?",
        "sections": [],  # nothing shares a keyword with this question - the topic gate excludes everything
        "categories": "(none - topic gate excluded all project evidence)",
        "temporal": "n/a",
        "provenance": "n/a",
        "expectation": "must NOT mention calibration/temperature scaling/Bayesian/the project at all - must answer the pasta question on its own, or say it doesn't have that stored if it can't",
    },
]

url = f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent"

for case in cases:
    label, question, sections = case["label"], case["question"], case["sections"]
    categories, temporal, provenance, expectation = case["categories"], case["temporal"], case["provenance"], case["expectation"]
    stored_context = context_block(sections)
    system_instruction = unified_instruction + "\n\n" + stored_context

    payload = {
        "contents": [{"role": "user", "parts": [{"text": f"Heard: {question}"}]}],
        "systemInstruction": {"parts": [{"text": system_instruction}]},
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "x-goog-api-key": api_key},
        method="POST",
    )

    print("=" * 70)
    print(f"CASE: {label}")
    print(f"QUESTION: {question}")
    print(f"CONTEXT CATEGORIES: {categories}")
    print(f"TEMPORAL STATUS: {temporal}")
    print(f"PROVENANCE SUMMARY: {provenance}")
    print("CONTEXT RETRIEVED (the STORED CONTEXT block actually sent to the model):")
    print("-" * 70)
    print(stored_context)
    print("-" * 70)
    print(f"EXPECTED (read the response yourself against this): {expectation}")
    try:
        with urllib.request.urlopen(req) as resp:
            body = json.loads(resp.read())
            text = body["candidates"][0]["content"]["parts"][0]["text"]
            print(f"MODEL RESPONSE:\n{text}")
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()}")
    print()

print("=" * 70)
print("Review each case above against its EXPECTED line - this script does not grade itself.")
print("Pay special attention to cases 1, 2, 3, and 7: current-vs-historical framing and the")
print("unrelated question NOT pulling in project context are the exact behaviors Stage 7 exists")
print("to guarantee - a wrong answer on any of those is a real finding, not a nitpick.")
