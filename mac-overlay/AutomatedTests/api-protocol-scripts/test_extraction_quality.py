#!/usr/bin/env python3
"""
Manual verification for Phase 3.3's Memory + Project extraction: sends a set of realistic
conversation snippets (the worked examples from the Phase 3.3 design investigation) to the
real extraction model and prints its structured output for a human to read and judge.

This is deliberately NOT an XCTest - "did the model correctly classify this statement's
modality and extract the right fields" is a claim about live model judgment, not about what
Swift code does with a given JSON response (that part IS covered deterministically by
ExtractionLLMClientTests/ExtractionCoordinatorTests, both using a stubbed client). No
automated assertion here can reliably validate real model judgment run to run - read the
printed output yourself against the "expected" annotation on each case.

Usage:
    GEMINI_API_KEY=... ./gemini-live-test-venv/bin/python3 test_extraction_quality.py
"""
import json
import os
import sys
import urllib.request

MODEL = "gemini-flash-latest"

api_key = os.environ.get("GEMINI_API_KEY") or (sys.argv[1] if len(sys.argv) > 1 else None)
if not api_key:
    print("Usage: python3 test_extraction_quality.py YOUR_API_KEY  (or set GEMINI_API_KEY)")
    sys.exit(1)

# Kept in sync with ExtractionLLMClient.systemInstruction - copy the exact wording here if that
# changes, same convention test_response_context_recency.py already uses for
# AIEngineController.unifiedInstruction.
system_instruction = """You extract structured, durable facts and project state from a snippet of conversation \
for "Friday", an always-listening personal assistant. Most conversation contains nothing \
worth extracting - when in doubt, extract nothing.

Output ONLY a single JSON object of the exact shape below - no markdown fences, no \
commentary, nothing else:

{"extractions": [ { ...candidate... }, ... ]}

Each candidate has:
- "type": one of "memoryEdge", "projectItem", "decision"
- "modality": one of "directStatement", "explicitDecision", "explicitTask", "suggestion", \
"speculation", "question", "hypothetical", "inference", "contradiction", "uncertain"
- "confidence": 0.0 to 1.0, how sure you are this is true and stable
- "isExplicit": true ONLY if the speaker directly asked to be remembered ("remember \
that...")

NEVER output a candidate for a question or a hypothetical ("how does X work?", "what if we \
used X?") - if the ENTIRE snippet is only questions/hypotheticals/small talk, output \
{"extractions": []}.

Hedged, uncertain, or merely suggested content ("maybe", "I think", "what if", "should we") \
must be tagged "suggestion", "speculation", or "uncertain", never "directStatement" or \
"explicitDecision".

For "memoryEdge" (a durable fact/preference/goal/relationship about a person, not about a \
project's own work): "subjectName" ("self" for the user speaking about themselves, or a \
person/org name), "subjectKind" (self/person/organization/project/place/concept/tool/other, \
only if subjectName is new), "predicate" (short verb phrase, e.g. "prefers", "works-at"), \
"objectName" (another entity name, if the value is itself a nameable thing) OR \
"literalValue" (a plain value, if not), "memoryCategory" \
(identity/preference/goal/fact/relationship/project/contact/other).

For "projectItem" (a task/objective/requirement/experiment/result/milestone/risk/open \
question/component belonging to a specific project's work): "projectItemKind" \
(task/objective/researchQuestion/component/requirement/artifact/milestone/openQuestion/\
risk/experiment/result), "name" (short label), "itemDescription" (optional detail), \
"projectItemStatus" (proposed/planned/active/inProgress/blocked/completed/achieved/\
resolved/abandoned), "relatedItemName" (optional - e.g. a result's experiment), \
"mentionedProjectName" (the project name if one was explicitly said, else omit).

For "decision" (an explicit, decisive choice about approach/method): "statement" (what was \
decided), "context" (what it concerns, e.g. a component name), "reason" (optional), \
"madeByNames" (people who made it), "mentionedProjectName" (if explicitly said).
"""

# (label, conversation snippet, human-readable expectation to check the output against)
cases = [
    ("direct preference", "I prefer Apple-style interfaces.",
     "one memoryEdge, modality directStatement, subjectName self, predicate~prefers, reasonably high confidence"),
    ("task completion self-report", "I finished Experiment 4.",
     "one projectItem, kind experiment or task, name mentions Experiment 4, status completed"),
    ("explicit decision", "Let's use Bayesian calibration.",
     "one decision, modality explicitDecision, statement mentions Bayesian calibration"),
    ("suggestion, not a decision", "Maybe we should try Bayesian calibration.",
     "at most one decision/projectItem candidate, modality suggestion or speculation, confidence should be low - must NOT be tagged explicitDecision"),
    ("speculation, not a completion", "I think I'll finish this tomorrow.",
     "at most one candidate, modality speculation, must NOT assert a completed status"),
    ("third-party explicit task", "Professor said we should compare A and B.",
     "one projectItem, kind task, status planned or proposed, modality explicitTask or directStatement"),
    ("pure question", "How does Bayesian calibration work?",
     "extractions: [] - a question must never produce a candidate"),
    ("direct vs speculative vs question (three-way contrast)", "I use React. I might use React. Should I use React?",
     "three visibly different outcomes: directStatement (persisted), speculation (low confidence), and no candidate at all for the question"),
    ("ongoing negative result", "Experiment 4 is still failing.",
     "a projectItem status update (not completed) and/or a result-kind candidate describing the failure"),
    ("decision change", "Let's move to Method B.",
     "one decision, modality explicitDecision, statement mentions Method B"),
    ("comparison task", "We should compare A against B.",
     "one projectItem, kind task, name mentions comparing A and B"),
    ("quantified result", "Method B performed 8% better.",
     "one projectItem, kind result, name/description mentions the 8% figure"),
    ("multi-fact single turn", "I prefer dark mode. Let's use Bayesian calibration for the XYZ algorithm. How does it work?",
     "a memoryEdge for dark mode, a decision for Bayesian calibration/XYZ, and NOTHING for the trailing question"),
    ("explicit remember request", "Remember that my favorite color is blue.",
     "one memoryEdge, isExplicit true, high confidence"),
]

url = f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent"

for label, snippet, expectation in cases:
    payload = {
        "contents": [{"role": "user", "parts": [{"text": snippet}]}],
        "systemInstruction": {"parts": [{"text": system_instruction}]},
        "generationConfig": {"responseMimeType": "application/json"},
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "x-goog-api-key": api_key},
        method="POST",
    )
    print("=" * 70)
    print(f"CASE: {label}")
    print(f"INPUT: {snippet}")
    print(f"EXPECTED (read the output yourself against this): {expectation}")
    try:
        with urllib.request.urlopen(req) as resp:
            body = json.loads(resp.read())
            text = body["candidates"][0]["content"]["parts"][0]["text"]
            print("MODEL OUTPUT:")
            try:
                print(json.dumps(json.loads(text), indent=2))
            except json.JSONDecodeError:
                print(text)
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()}")
    print()

print("=" * 70)
print("Review each case above against its EXPECTED line - this script does not grade itself.")
