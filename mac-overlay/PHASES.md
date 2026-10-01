# Founder Office Copilot — Phases

Status as of this writing: the single-conversation assistant (always-on transcription +
on-demand streamed response) is done and working end-to-end. This file tracks what's done
and what's next.

## Done

### Phase 1 — Settings, secure key storage, scrollable windows
- Real Settings window (agent name, "about you", custom rules, Gemini API key via Keychain,
  separate transcription/response model fields).
- Overlay content scrolls instead of clipping.

### Phase 2 — Single always-on assistant (evolved from the original plan)
The original plan had one Gemini Live session doing both transcription and reactive
suggestions. In practice that coupling caused real bugs (session drops losing the ability to
answer, garbled audio from unmixed mic+system streams, stale multi-topic context bleeding
into new questions), so the architecture split into two independent pieces:

- **Transcription**: `GeminiLiveClient` — a Gemini Live WebSocket session, transcription-only
  (automatic voice-activity-detection, no output audio/text requested). Mic (`AudioCaptureManager`)
  and system audio (`SystemAudioCaptureManager`) are mixed into one real waveform by
  `AudioMixer` before reaching it — sending the two as independently-timed streams was
  producing hallucinated, language-mixing transcription.
- **Response**: `GeminiResponseGenerator` — a one-shot `streamGenerateContent` (SSE) REST
  call, triggered only by `requestResponse()` (⌘⇧R). Grounded in `transcriptSinceLastResponse()`
  — everything heard since the last response, not the whole session's history (an earlier bug
  had the whole history bleeding in, causing the model to answer an already-answered topic
  instead of the new one). Streaming means the first words appear in a few hundred ms instead
  of a multi-second blocking wait.
- No more Meeting/Personal mode distinction — always-listening, single unified system
  instruction. Chat is two roles only: Heard / Response. Nothing is ever deleted or trimmed
  from the chat history.
- Shortcuts cheat sheet in the overlay (keyboard icon, top right): ⌘⇧A show/hide, ⌘⇧R respond
  now, ⌘⇧V toggle screenshot/screen-share visibility, double-click to maximize.
- Project tree cleaned up (dead browser prototype, unused SpeechRecognitionEngine, stale
  transcription-locale settings removed); git initialized with a safety-net baseline commit.

### Phase 2.5 — Trim response context for long-session scalability (character cap)
`appendHeardDelta` merges everything heard into ONE growing `.heard` message until a response
starts, so the "current turn" is a single message and a 30+ minute gap between ⌘⇧R presses made
one enormous prompt. A message-COUNT limit could not bound that, so the cap works at the
character level.

- `ChatSessionManager.defaultConversationCharacterLimit` (24,000 characters, ~6k tokens),
  counted in characters to match `ContextEngine`'s existing `maxEvidenceCharacterBudget`
  convention rather than inventing a token estimator. Not user-configurable.
- `responseContext(recentContextLimit:characterLimit:)` keeps the existing message-count bound
  and adds the character budget; `ResponseContext.boundedOrderedMessages` is the new
  character-bounded view that `AIEngineController.requestResponse()` sends to
  `GeminiResponseGenerator`.
- Trimming favours the CURRENT TURN over background history, keeps the NEWEST text (a partially
  fitting message contributes its tail), never turns a non-empty turn into an empty one, and
  passes anything under the limit through byte-for-byte with original ids/timestamps. No
  ellipsis or marker is inserted - nothing is invented into the prompt.
- **The retrieval query is deliberately NOT trimmed.** `ResponseContext.currentTurn` and
  `orderedMessages` keep their pre-2.5 meaning, so `retrievedContextText(forCurrentTurn:)` and
  `ContextEngine` still see the full text and Phase 4.2's evidence-sufficiency grounding cannot
  change as a side effect. Pinned by `testRetrievalQuerySourceRemainsUntrimmed`.
- Rolling summaries were explicitly NOT built in this phase (the doc's second option); the cap
  is zero-cost and needed no API calls. Revisit only if truncation proves lossy in real use.
- The full transcript is unchanged in `ChatSessionManager.sessions` and `ChatSessionStore` -
  verified by re-reading the store before and after, not merely asserted.

### Phase 3.x / 4.x — Project intelligence (specified conversationally, not in this file)

A substantial memory/extraction/retrieval/project track was designed and built in conversation
after Phase 2, using its own 3.x/4.x numbering. It was never written down here, which made
"what's the next phase?" unanswerable from the repo alone - this section fixes that. NOTE the
numbering collision: this track's "Phase 4" is project intelligence, while **Phase 4 below**
(still open) is the original *local storage & meeting recall* item. They are unrelated.

**Phase 3.1-3.4 — memory graph, extraction, context engine.** Entity/edge memory
(`MemoryEntity`, `MemoryEdge`, `MemoryStore`, `MemoryManager`); LLM extraction with a local
pre-filter, debounce/batching, modality policy and a sensitive-content gate
(`ExtractionCandidate`, `ExtractionHeuristics`, `ExtractionLLMClient`, `ExtractionCoordinator`,
`SensitiveContentGate`); retrieval and prompt assembly (`ContextEngine`, `ContextPacket`,
`ContextPacketFormatter`, `RelevanceScoring`, `KeywordGraphRetrievalProvider`,
`RetrievalProvider`, `CrossLayerConflictResolver`, `TemporalQueryClassifier`,
`EpisodeSummary`). Supersession/contradiction handling never overwrites history.

**Phase 4.1 — project management.** `Project`, `ProjectItem`, `Decision`, `ProjectEvent`,
`ProjectSessionLink`, `ProjectStore`, `ProjectManager`, `ProjectResolution`, plus session→
project assignment in `SessionSidebarView`. Retrieval is project-scoped; cross-project leakage
is prevented structurally (candidates only ever come from the active project).

**Phase 4.2 — synthetic multi-project evaluation harness (DEBUG-only, deletable).**
`Synthetic*.swift` + `QuickSynthetic*.swift`: generate synthetic multi-project meetings,
populate an ISOLATED store sandbox (`SyntheticLab/`, guarded by a fail-closed
`SyntheticStoreLocation.assertSafe`), and score a 12-question evaluation with an LLM judge.
Final result: **12/12 pass, 0 partial / 0 fail / 0 uncertain**, including project-isolation and
cross-project-trap cases.

Two production fixes came out of running it:
- **Negative retrieval / hallucination resistance** (`ContextPacketFormatter`): the
  "I don't have that stored" instruction was reachable only when the retrieved context was
  *entirely* empty, so an off-topic question whose evidence matched on a generic word (e.g.
  "approach") got a confidently invented answer. The directive is now driven by evidence
  *sufficiency* - distinctive-token coverage of the question - and is scoped to the stored
  context block, never a blanket ban on general knowledge. This is what turned Q9 from FAIL
  to PASS.
- **Evaluation runner lifetime** (`SyntheticLabWindow`): the runner was held only in a local,
  so it deallocated mid-run and its `[weak self]` callback silently dropped the whole
  evaluation, leaving the UI stuck on "Running evaluation…" forever.

**Phase 4.3 — Decision → ProjectItem linking. PARTIAL / DEFERRED.**
`Decision.relatedItemID` existed and persisted correctly but was never populated: the
extraction prompt requested `relatedItemName` only for projectItem candidates, and the
decision path never passed the argument. Implemented: project-scoped resolution
(`relatedItemName` → `statement` → `context`) using deterministic token containment, ambiguity
is terminal (several matches → no link, never a guess), project-items-before-decisions
ordering within a batch, and an extraction-prompt section listing the active project's
canonical item names.

Outcome across three live populations: **`relatedItemName` emission 0/7, 0/6, 0/6** - the model
never emitted it despite explicit instruction, so links only ever came from the statement
fallback (1 link, manually verified correct; 0 incorrect links in any run).
**Assessed and deferred**, on evidence: the 12/12 was achieved with zero links;
`CrossLayerConflictResolver`'s dedup branch is unreachable for 3 of the 12 questions
(`historical`/`changeReason` intent returns early); and of the 4 duplicate pairs it could
suppress, 3 carry item-only detail whose removal would *lose* context rather than deduplicate
it. Maximum benefit measured at ~4% of retrieved context on 8/12 questions. Not worth further
prompt iteration now.

**Phase 4.3b — the 0/N diagnosis was WRONG. Corrected by measurement.**
STATUS: implementation COMPLETE and live-probe validated; ONE live end-to-end population
validation still OUTSTANDING (see below). Recorded explicitly so no future session repeats the
wrong diagnosis.

- **Superseded hypothesis:** the model omitted `relatedItemName` because the field was described
  only in prose and `generationConfig` carried no `responseSchema`. A `responseSchema` declaring
  `relatedItemName` as required-but-nullable was added on that basis.
- **What the measurement showed:** a controlled live probe
  (`LiveExtractionSchemaProbeTests`, **18 MEASURED HTTP requests**, real Phase 4.2 transcripts,
  real CleanFixture item names, production payload built by `buildRequestPayload` itself)
  FALSIFIED it. `relatedItemName` was present in **17 of 17** decision candidates, **including
  the schema-OFF control arm**, which emitted non-null names 4 times out of 5. The schema never
  governed emission.
- **The variable that actually governs it** is whether the model is given names it may copy:

  | canonical names supplied | non-null `relatedItemName` |
  |---|---|
  | present | **6/6**, every one an EXACT canonical match |
  | empty | **0/5** |

  Zero invented names in either arm.
- **So 0/7, 0/6, 0/6 was not a defect.** Populating from an EMPTY store means three of the four
  meetings are their project's FIRST, no tracked item exists yet, and `null` is the only correct
  answer. The old numbers measured a fixture property, not a model failure.
- **The real gap** was a decision about work identified in the SAME batch, which the prompt never
  permitted the model to name. `ExtractionLLMClient.systemInstruction` now allows
  `relatedItemName` to be the exact `name` of a `projectItem` candidate emitted in the same
  response, still as an EXACT-string rule. Live result on the empty-names case: **0/5 → 3/5**,
  with **3/3 of the emitted names matching a same-batch item exactly** and 0 invented; the 2
  remaining nulls were correct refusals (one response proposed no items at all, the other's
  decision genuinely was not about the proposed item).
- **A false-AMBIGUITY defect** became reachable once names started being copied verbatim: where
  one item's name is a strict token-subset of another's, naming the longer one matched BOTH and
  the link was discarded. `matchOutcome` now breaks that tie ONLY when exactly one tied item is
  named verbatim AND every other tied item is strictly less specific. Equal-specificity ties
  still refuse to guess, so `testAmbiguousReferenceMatchingTwoSimilarItemsLeavesRelatedItemIDNil`
  is unchanged.
- The `responseSchema` is KEPT on independent merit (`type`/`modality`/`confidence`/`isExplicit`
  are non-optional on the decoder, so declaring them required aligns wire and decoder), but is no
  longer claimed to be the fix for emission.
- Evidence: `~/Documents/FridayPhase42Evidence/Phase43LinkingProbe/` - probe 1 (schema A/B),
  probe 2 (canonical-names ablation), probe 3 (same-batch after the prompt fix), specs and raw
  model output for each.
**Phase 4.3c — live END-TO-END population. PASS.**
One controlled population through the real `SyntheticPopulationRunner` (the same runner the
"3. Populate Friday (isolated)" button drives, invoked through the DEBUG
`--phase43-validate=<dataset>` entry point so the run is reproducible and cannot be invalidated
by a double click). Sandbox cleared first, so EVERY meeting was its project's first and every
link had to come from the same-batch path. 4 extraction calls, 0 response/judge calls, no
evaluation run.

| run | decision candidates | `relatedItemName` emitted | persisted links |
|---|---|---|---|
| prior populations ×3 | 7, 7, 6 | 0, 0, 0 | 0 |
| **this run** | **7** | **4** | **4** |

- All four links resolved via `relatedItemName` (not the statement/context fallback), confirming
  the same-batch prompt change is what does the work.
- **0 cross-project links, 0 dangling links**, verified INDEPENDENTLY in SQL against the store on
  disk, not merely read back from the in-memory managers.
- The three unlinked decisions are correct refusals - no tracked item was their subject.
- Every link is semantically right, e.g. "Split transient and group demand into two separate
  sub-models" → `Split transient and group demand sub-models`.
- Evidence: `~/Documents/FridayPhase42Evidence/Phase43LiveValidation/` -
  `live-validation.json`, a WAL-safe `sqlite3 .backup` snapshot of the validated population, and
  a screenshot of the Graph UI rendering one of the persisted links.
- CleanFixture restored byte-identically afterwards (all three hashes re-verified; 3 projects /
  9 items / 6 decisions / 4 links; 0 `relatedItemID`; no evaluation sessions).

**Phase 4.3 overall: COMPLETE.** Extraction, emission, resolution, ambiguity safety, project
isolation, persistence and end-to-end live behaviour are all validated.

**Phase 4.4 — Semantic retrieval (embeddings / vector search). DEFERRED - not implemented.**
Investigated as the planned successor to 4.3 and deliberately NOT built: the evidence does not
demonstrate a semantic-retrieval or recall failure.

- No observed failure currently requires embeddings or semantic retrieval. The 12-question
  benchmark passes 12/12 with purely lexical retrieval.
- At the current project scale (3 projects, 8-9 items each) in-project retrieval already has
  effectively COMPLETE recall: `KeywordGraphRetrievalProvider` does not filter candidates by
  keyword at all - it admits everything project/temporally admissible, scores it
  (`RelevanceScoring`: keyword 0.30, project 0.20, recency 0.15, confidence 0.15, pinned 0.10,
  confirmations 0.05, relationship 0.05) and takes the top N per layer. Nothing relevant is
  failing to be retrieved, so there is no recall problem for embeddings to solve.
- The measured weakness is DOWNSTREAM of retrieval: `ContextPacketFormatter`'s lexical
  admission gate (`isRelevant` = `keywordOverlap > 0`) deleted **57 of 139 retrieved evidence
  items (41%)** across the 12 questions, after retrieval and after budgeting.
- **Q4 is the clearest example.** "What did we eventually decide to use instead?" contains no
  distinctive domain tokens, so the gate removed all 4 project items, all 3 decisions and all 3
  episodes - the Decision layer contributed NOTHING to the question literally asking what was
  decided. It passed only because ungated raw transcript excerpts (historical evidence is
  exempt from the gate) happened to carry the answer. Three of twelve questions (4, 8b, 10)
  reached the model with zero memory/item/decision evidence.
- Context budget was NOT the binding constraint: `maxEvidenceCharacterBudget` is 6000 and
  rendered contexts ran 2712-6107 characters, so admitting more evidence would mostly fit
  within existing headroom. The gate is the constraint, not the budget.
- REVISIT semantic retrieval when the corpus is large enough to demonstrate a genuine recall
  failure - i.e. when a project holds enough items that top-N-by-score can actually drop
  something relevant. The current synthetic corpus cannot exhibit that.

**Phase 4.4b — work-state admission fallback for subjectless follow-ups.**
STATUS: implemented, deterministically tested, **NOT YET LIVE-VALIDATED**. Do not record this as
complete until the 12-question ablation below has run.

- **Deterministic reproduction** against the real CleanFixture text: "What did we eventually
  decide to use instead?" admits **0 of 6 project items and 0 of 3 decisions** - the Decision
  layer contributes nothing to the question literally asking what was decided.
- **First attempt was wrong, and the suite caught it.** Keying the fallback on "the gate deleted
  every layer" also fires for a genuinely off-topic question, and it broke
  `MultiMeetingScenarioIntegrationTests.testUnrelatedWeatherQuestionDoesNotInjectProjectContext`
  (7 failures). That failure identified the correct discriminator.
- **The discriminator is whether the question has a SUBJECT AT ALL**, which `distinctiveTokens`
  already computes: `"What did we eventually decide to use instead?"` → `{}` (all scaffolding),
  `"What is the weather forecast tomorrow?"` → `{weather, forecast, tomorrow}`. A subjectless
  question is a pure follow-up carrying its subject in the conversation, so a lexical gate has
  nothing to match on and deleting the layer is an artefact, not a judgment. A question that
  DOES name a subject is judged exactly as before.
- `genericTokens` gained the vocabulary of REFERRING to a choice (`decide`, `decision`,
  `instead`, `eventually`, `chose`, `picked`, …). Every word describes the act of choosing and
  none can name a topic, so it cannot make an off-topic question look subjectless.
- Scoped narrowly: work-state layers only (memories and episodes stay strictly gated in every
  case), only when BOTH were emptied, only the top 3 by the score retrieval already computed.
  The fallback and the grounding directive never interact - the directive is suppressed exactly
  when `distinctiveTokens` is empty, which is exactly when the fallback fires.
- `ContextPacketFormatter.format(_:questionText:lifecycleAnnotationsEnabled:workStateFallback
  Enabled:)` - the new flag defaults to `true` and exists so the live A/B can be a
  single-variable ablation, exactly as `lifecycleAnnotationsEnabled` was in Phase 4.5.
**Phase 4.4c — live ON/OFF ablation. COMPLETE. VALID — NO MEASURABLE VALUE DEMONSTRATED.**
Both arms ran the unmodified 12-question benchmark through the real response path
(`requestResponse()` -> `ContextEngine` -> `ContextPacketFormatter` -> `GeminiResponseGenerator`)
and the real judge, from byte-identical CleanFixture baselines, via the DEBUG
`--phase44-arm=on|off` entry point (one process per arm, so an arm cannot be double-invoked).

- **The activation prediction was made OFFLINE and held LIVE.** Only one of the twelve questions
  (`4-decision`, "What did we eventually decide to use instead?") is subjectless, so the flag can
  only reach that one. `testFallbackActivatesOnExactlyOneBenchmarkQuestion` asserted this before
  any call was spent; live, the flag was sensitive on exactly 1/12.
- **Control equivalence is EXACT on that question, verified both ways:** Arm A's counterfactual
  OFF-render equals Arm B's actual context, and Arm B's counterfactual ON-render equals Arm A's
  actual context. The only difference is the fallback's 3 items + 3 decisions (4908 vs 3769 chars).
- **Mechanism works:** ON admitted 3 relevant project items and 3 relevant decisions where the
  gate had deleted everything; OFF admitted nothing - the defect reproduced live.
- **Value not demonstrated:** both arms answered correctly, judged `pass` at confidence 1. ON's
  answer carried extra correct detail traceable to the admitted decisions ("replacing conformal
  prediction and Bayesian optimization") that the judge did not reward. OFF still answered
  correctly from ungated historical transcript excerpts, exactly as predicted above.
- **Harm not demonstrated, and this is the stronger result:** the fallback was completely inert on
  the other 11 questions, and injected NOTHING into either uncovered-subject trap
  (`9-negative-retrieval`, `10-unknown` admitted 0/0 in both arms, byte-identical contexts). The
  Phase 4.2 negative-retrieval and cross-project safety behaviour is intact.
- **Arm A scored 10/12 and Arm B 12/12. This is NOT evidence against the fallback.** Both Arm A
  failures (`3-why`, `9-negative-retrieval`) occurred on contexts BYTE-IDENTICAL to Arm B's, on
  questions where the flag is inert - identical input, different output. Both hallucinated
  workspace specifics absent from the stored context (`knowmyhotel`, WinCloud PMS, Apify); on
  `9-negative-retrieval` the model gave the correct refusal and then hallucinated anyway. That is
  a real, separately-actionable GROUNDING weakness and a demonstration that the benchmark is not
  deterministic run-to-run - it is not a Phase 4.4 result.
- Call accounting: judge **MEASURED 12/arm** (`CountingGenerationClient` at the generation-client
  boundary); response **CORROBORATED 12/arm** (from `GeminiResponseGenerator`'s own run log);
  evaluation-time extraction **STRUCTURAL ≤12/arm** (uninstrumented, but corroborated by fixture
  drift of 9->12 items and 6->9 decisions after Arm A).
- Known confound, reported not hand-waved: `10-unknown`'s context differed across arms for a
  NON-flag reason - evaluation-time extraction mutates the fixture as a run proceeds, so late
  questions can see slightly different stores. It admitted 0/0 in both arms and does not affect
  the verdict, which rests on `4-decision`.
- Instrument defect found by this run: the benchmark fingerprint used Swift's `String.hashValue`,
  which is seeded randomly PER PROCESS, so the two arms fingerprinted the identical question set
  differently. Benchmark identity was verified instead by comparing every recorded question id,
  text, scenario, expected project and ORDER across the artifacts (identical). The fingerprint is
  now FNV-1a, deterministic across processes, and pinned by a unit test.
- Limitations: one run per arm against a stochastic generator (which this experiment directly
  demonstrated matters); only 1 of 12 questions can exercise the feature, and the benchmark was
  deliberately NOT modified to add more; the judge scores answer correctness, not evidence
  quality, so improved grounding can score as a tie.
- **Production default stays ON**, on the evidence: the mechanism does what it was built to do,
  costs nothing on every other question, and demonstrably does not regress the safety cases.
- Evidence: `~/Documents/FridayPhase42Evidence/Phase44WorkStateExperiment/` -
  `Phase44-Final-Comparison.md`, `ArmA-WorkStateON-20260818-003655.json`,
  `ArmB-WorkStateOFF-20260818-003905.json`. CleanFixture restored and re-verified after each arm.

**Phase 4.4 overall: COMPLETE.** Distinct from Phase 4.5, which remains its own separate result.

**Future investigation — intent-aware evidence admission / formatter gate**
The `ContextPacketFormatter` gate is simultaneously the cause of the false negatives above AND
what makes the negative-retrieval and cross-project-trap questions pass (8b, 9, 10 correctly
answer "I don't have that stored" because off-topic evidence is dropped). Candidate approaches:
admit top-scored decisions when the question has no distinctive tokens (the condition Phase
4.2's `distinctiveTokens` already computes), or keep the highest-scored N when the gate would
otherwise delete everything. NOT implemented here - loosening the gate risks regressing Phase
4.2's negative-retrieval and cross-project safety behaviour, so it needs its own scoped change
plus a 12-question re-validation (24 calls).

**Evidence / artifacts to preserve**
- `~/Documents/FridayPhase42Evidence/evaluation-quick-20260813-002926-1786627363.json` -
  the 12/12 evaluation report. Kept OUTSIDE `SyntheticLab/` deliberately: "5. Clear Synthetic
  Data" deletes that whole directory, and an earlier report was lost exactly that way.
- The quick synthetic dataset currently lives under `$TMPDIR/friday-quick-synthetic/` and is
  **not durable** - macOS may purge it. Needs copying next to the evaluation report.
- The populated `SyntheticLab/` stores are the only ones containing a non-null
  `relatedItemID`; re-creating them costs 4 real extraction calls.

**Known technical debt from this track**
- `ChatSessionStore` write race - **FIXED**, see "ChatSessionStore concurrency fix" below.
- `ContextPacketFormatter.genericTokens` and `ExtractionCoordinator.genericLinkTokens` are two
  separate hand-maintained stopword-ish sets, and `RelevanceScoring.tokenize`'s rule is
  reimplemented in both because it is `private`.
- `SessionSearchTests.testSortedByMostRecentFirstWithinAGroup` fails between roughly 00:00 and
  03:00 local time (its fixture assumes `now - 3h` is still "today").
- The `Synthetic*`/`QuickSynthetic*` family, its AutomatedTests symlinks, its `project.pbxproj`
  entries and the two Debug menu items are all TEMPORARY and meant to be deleted once this
  validation work is finished.

**ChatSessionStore concurrency fix (PRODUCTION, completed)**

The defect: every write (`createSession`, `updateSessionMetadata`, `appendOrUpdateMessage`,
`deleteSession`) created a FRESH background `NSManagedObjectContext` via
`container.performBackgroundTask`, with no ordering between writes, and every save used
`try? context.save()`. That produced two established data-loss modes:

1. **create/append ordering** - an append could fetch the session before the create had
   committed, hit its `guard let sessionEntity ... else { return }`, and drop the message
   entirely.
2. **same-row conflict** - `appendOrUpdateMessage` and `updateSessionMetadata` (issued
   back-to-back by `ChatSessionManager.appendHeardDelta`) mutated the same session row from two
   contexts; under the default `NSErrorMergePolicy` the losing save threw and `try?` discarded
   it.

Observed live during Phase 4.3 population: 3 of 4 meeting transcripts silently lost (one at 0%,
others at 44% and 86% of their real length) while extraction - which reads in-memory text - saw
all four. Real transcription was only spared because its writes are naturally spaced out, so
this was a genuine production persistence risk, not a test artifact.

The fix:
- ONE private background `NSManagedObjectContext` per `ChatSessionStore` instance, created in
  `init` (`container.newBackgroundContext()`).
- Every write runs through that context's `perform` queue, which Core Data executes FIFO -
  creates therefore precede appends, and no two writes touch the same row concurrently.
- `NSMergeByPropertyObjectTrumpMergePolicy` is set as defence-in-depth; serialization, not the
  merge policy, is the mechanism.
- Save failures are logged with operation + session/message ids instead of being swallowed by
  `try?`.
- Public APIs, signatures and fire-and-forget semantics are unchanged; no `ChatSessionManager`
  call site changed; no actor introduced; no schema or Core Data model change, therefore no
  migration.

Validation evidence:
- `ChatSessionStore` tests 10 -> 16 (rapid-fire 50 appends; create-then-immediate-append;
  interleaved append+metadata; duplicate-id convergence; ordering; delete cascade). All read
  back through a SEPARATE store instance on a real on-disk temp store, and all wait on the
  store's own completion callbacks rather than sleeping.
- Full suite: **661 tests, 0 failures, 1 skipped**, run twice. The remaining skip is only the
  pre-existing screen-recording permission-denied test.
- The Phase 2.5 persistence `XCTSkipIf` (which existed solely to tolerate this race) was REMOVED
  and replaced with a real assertion - not another skip. That test passed 10/10 before the edit
  and 5/5 after.
- Load-bearing proof: reverting ONLY the serialization change produced **55, 56 and 54 failures
  across three runs** of the same 16 tests (the varying count is itself the race signature).
  Source was restored byte-identically afterwards.
- Debug build succeeded; Release build succeeded.
- Gemini/API calls: 0. Production stores byte-identical. SyntheticLab untouched.

Remaining limitations (deliberately not addressed):
- Persistence errors are now logged but NOT surfaced through the fire-and-forget API; a caller
  still cannot observe a failure unless it passes a completion.
- Serialization is per `ChatSessionStore` INSTANCE. Two independent instances opened on the same
  file could still race. Nothing does that today (the Synthetic lab shares one instance), but it
  is an invariant, not a guarantee.
- The synthetic population's own workarounds (`awaitSessionPersisted`, and the verify-and-repair
  `awaitTranscriptPersisted`) are now redundant but were intentionally left in place.
- `MemoryStore` and `ProjectStore` use the same `performBackgroundTask` pattern but have NOT been
  audited. This is recorded as a possible future investigation only - there is no evidence they
  carry the same defect, and no such claim is made here.

### Phase 4.5 — Truth / Uncertainty / Evidence Layer (work-state visibility)
STATUS: **COMPLETE / LIVE VALIDATED.** Mechanism works and is live-validated; its VALUE is
explicitly NOT demonstrated for the one question tested (see below).

`ContextPacketFormatter` now renders each `ProjectItem`'s lifecycle status beside the item in
the retrieved context - `[proposed] [planned] [active] [in progress] [blocked] [completed]
[achieved] [resolved] [abandoned]` - so "what is finished" and "what is still open" are visible
to the model rather than inferable only from wording. Retrieval, scoring, the admission gate,
temporal grouping, grounding, the judge and extraction are all unchanged; the annotation is
appended to already-selected bullets and nothing else.

Validation:
- Offline: formatter tests 31 -> 43; full suite green; Debug and Release builds succeeded.
- Live: the 12-question benchmark remained **12/12**, with lifecycle annotations verified
  present in the rendered context that reached the model.

Controlled ON/OFF value experiment (the point of the phase, run separately):
- Single-variable ablation on "Which calibration work is finished and which is still
  outstanding?" (`project-a`), one run per arm, 3 Gemini calls per arm (1 response + 1 judge,
  judge MEASURED, + 1 evaluation-time extraction).
- The authoritative clean fixture was snapshotted WAL-safely (`sqlite3 .backup`), restored
  byte-identically before each arm with the app fully closed, and re-verified each time
  (3 projects / 9 items / 6 decisions / 5 sessions / 4 links; research 3 completed + 3 planned;
  zero duplicates; zero evaluation-derived items).
- Control held byte-for-byte: `contextWithoutLifecycleAnnotations` identical across arms,
  identical evidence items in identical order, identical bullets modulo the suffixes; ON carried
  5 annotations, OFF carried none.
- **Result: VALID — NO MEASURABLE VALUE DEMONSTRATED for this question/fixture.** Both arms
  judged `pass` at confidence 1, and NEITHER arm misclassified any item it named. The OFF arm
  was in fact slightly more complete. The item/transcript wording already encoded status
  lexically.
- This does NOT show lifecycle annotations are generally worthless: one question, one fixture,
  one run per arm, non-deterministic generation, and only two statuses present (`completed`,
  `planned`) - the cases where status should matter most (`abandoned`, `blocked`, a status that
  CHANGED across meetings) are absent and untested. The 12/12 regression is NOT evidence of this
  phase's value and must not be cited as such.

More important incidental finding: `Fix message payload normalization layer` (completed) was
RETRIEVED but dropped by the formatter's lexical admission gate in BOTH arms, so it never
reached the model as project state. This is a separate defect from the lifecycle result - it
degrades every arm equally and this ablation could not have caught it - and it corroborates the
Phase 4.4 diagnosis (57 of 139 retrieved evidence items removed by the same gate). **The
admission gate, not further lifecycle work, is the more promising follow-up target.**

Evidence (durable, outside SyntheticLab, in `~/Documents/FridayPhase42Evidence/
Phase45ValueExperiment/`):
- `Phase45-Final-Comparison.md` - the full comparison and reasoning.
- `ArmA-LifecycleON-20260815-214833.json` - `20fac9b09bda71cbf42de0e7bcffd57bfecfd31ffa30c59f46d1eb74440259aa`
- `ArmB-LifecycleOFF-20260815-215440.json` - `cb507dd89f3bb58d7c9e7f458b9d909b44fae9095db94abc745c3d023d219fc7`
- `CleanFixture/` - the authoritative baseline both arms started from.
- `ArmA-LifecycleON-20260815-213956.json` and `ArmA-partial-evidence-20260815.md` are INVALID
  incident runs (the ON arm was invoked twice), retained for audit history only.

Harness debt: evaluation-time extraction still mutates the fixture on every focused run (an
evaluation session plus duplicate items), which is why each arm requires a full restore. The
response and evaluation-extraction call counts remain structural, not instrumented; only the
judge is measured.

### Phase 5 — Project Graph UI
STATUS: **IMPLEMENTED, TESTED, VISUALLY VERIFIED.** Menu bar → "Project Graph…"
(⌘⇧G), plus a DEBUG-only "Project Graph (Synthetic Lab)…" that opens the same UI on the
isolated lab stores.

**Architecture — four PURE layers under one thin view.** Nothing in the SwiftUI layer knows
about Core Data, and every algorithm is testable without a window:

    stores → managers (already in memory)
        → GraphSnapshotBuilder   (projection: nodes, edges, integrity issues)
        → GraphFilter            (project / kind / lifecycle / search)
        → GraphLayoutEngine      (deterministic positions)
        → GraphViewport          (zoom, pan, hit testing, fit, focus)
        → GraphView / GraphSidebar / GraphInspector

**The two rules the projection enforces.**
1. NEVER FABRICATE AN EDGE. Every edge reads a field that literally holds the other end's id.
   A `Decision` with `relatedItemID == nil` produces NO edge - asserted against the real
   fixture, whose six decisions are all nil and share heavy vocabulary with the items, so any
   similarity-based inference would light it up.
2. NEVER SILENTLY REPAIR. A dangling or cross-project `relatedItemID` becomes a
   `GraphIntegrityIssue` and NO edge, surfaced in the inspector rather than fixed or dropped.

**Node types** are `project`, `projectItem`, `decision`, `session`, `person` - each with real
rows behind it. `Meeting` is deliberately EXCLUDED (`ProjectManager.createMeeting` has no
caller outside its own store write; every populated fixture holds 0 meetings, so the node type
could never appear). `ProjectEvent` is excluded as a node but surfaced as a project's recent
activity, because an event is history about another entity rather than a participant in
relationships.

**Determinism** is a tested property, not an aspiration: node ids are `(kind, persisted UUID)`
never `UUID()`, dictionary/set iteration never reaches the output unsorted, and layout is
closed-form. Force-directed layout was considered and rejected - this graph is strongly
partitioned by project, so a relaxation algorithm would rediscover structure the data already
states, at O(n²) per iteration and with seed-dependent output.

**Performance** (measured, printed by `testLayoutAndFilterScaleTo1000Nodes`):

| nodes | edges | layout | filter |
|---|---|---|---|
| 13 | 31 | 0.0ms | 0.0ms |
| 105 | 302 | 0.3ms | 0.1ms |
| 521 | 1510 | 2.3ms | 0.7ms |
| 1041 | 3020 | 6.8ms | 1.3ms |

Snapshot build at 1041 nodes: 18.4ms. Layout is recomputed ONLY when the filtered snapshot
changes - selection, hover, pan and zoom never reposition a node.

**Accessibility.** The canvas is `.accessibilityHidden(true)` and the sidebar's node browser is
the supported route through the same filtered data: a real `List` with a selection binding, so
arrow keys, type-select and VoiceOver all work. Each row announces type, title, status, project
and relationship count - everything a sighted user reads from position and shape.

**Two defects found by looking at it, not by testing it.** Both are why visual verification was
worth doing: (1) the initial fit ran against an `HSplitView`'s unsettled intermediate width and
pinned the graph at the 10% minimum scale with every label suppressed - the canvas now re-fits
until the user takes the camera, and refuses to fit to implausibly small sizes; (2) drawing a
label per node was unreadable on the real corpus (labels are far wider than the nodes rings are
sized to separate), so labels are now placed greedily in priority order - selection and its
neighbours first, then projects - and any that would collide is dropped until zoom reveals it.

**Verification.** 60 graph tests (projection 25, filter/layout 20, viewport 15) plus 12
adversarial cases: cycles, self-reference, supersession chains, near-identical names in one
project, unlinked sessions, missing people, duplicate titles across projects, empty/single-node
graphs. Visually verified in BOTH themes against the real 29-node / 44-relationship fixture, and
the decision inspector correctly reports "Not linked to a tracked work item" - the Phase 4.3
truth surfaced rather than hidden. Screenshots:
`~/Documents/FridayPhase42Evidence/GraphUI/`.

**DEBUG-only verification tooling** (part of the SyntheticLab family, same removal list):
`--graph-preview` opens only the graph window and returns BEFORE audio capture, system-audio
capture and the Gemini Live session start, so taking a screenshot of a graph never has the side
effect of recording the room or costing anything; `--graph-appearance=light|dark` pins the
theme; `--graph-select=<kind>` preselects through the ordinary selection property.

**Known limitations.** Edge selection is not implemented (nodes only). Very dense clusters drop
labels until zoomed. The graph reads a snapshot on open/reload rather than observing the
managers live. `ProjectEvent`/`Meeting` have no nodes, as described above.

### MVP productization — experimental code removed, product UI built
STATUS: **IN PROGRESS.** The research track above is complete and validated; this phase turns the
validated engine into a product. Historical conclusions above are unchanged - nothing in this
section rewrites them.

**Removed from the product** (~6,000 lines). The SyntheticLab family and the phase harnesses had
served their purpose and were shipping inside the app:
`SyntheticLabWindow`, `SyntheticEvaluationRunner`, `SyntheticConversationLab`,
`SyntheticPopulationRunner`, `SyntheticScenarioLibrary`, `SyntheticGenerationClient`,
`SyntheticDatasetRunner`, `SyntheticMeetingGenerator`, `QuickSyntheticGenerator(+Window)`,
`Phase43LiveValidation`, `Phase44LiveAblation`, `DebugConversationExporter`, plus their four
experiment-only test files and every Debug menu item and launch hook they carried. All durable
evidence was preserved OUTSIDE the repository first, in `~/Documents/FridayPhase42Evidence/`.

**Experimental flags retired, mechanisms kept.** `lifecycleAnnotationsEnabled` and
`workStateFallbackEnabled` existed only so their ablations could run. Both mechanisms measured
VALID with no harm, so both are now unconditional production behaviour and the flags are gone -
which also removes the last `#if DEBUG` branch from the response path, so Debug and Release now
assemble context identically.

**Startup.** `AppDelegate.aiEngine` is lazy: as a stored property it opened three Core Data
stores before `applicationDidFinishLaunching` ran.

**Known flake fixed, not tolerated.** `SessionSearchTests.testSortedByMostRecentFirstWithinAGroup`
failed between roughly 00:00 and 03:00 local time because its fixture assumed `now - 3h` was
still "today". It now anchors at midday, so it tests ordering rather than the clock.

**New product surface.** A standard macOS sidebar workspace window (⌘0) alongside the existing
overlay: Home, Projects (tabbed detail: overview / work / decisions / timeline / people), Work,
Decisions, People, Knowledge Graph, and a ⌘F search palette across every entity. Built on a real
design system (`DesignSystem.swift`) - one spacing scale, one type scale, one radius set, one
lifecycle colour vocabulary, shared primitives - so no screen styles itself.

**Chat moved into the workspace, with real sources.** `AIEngineController` now keeps the
`ContextPacket` it built for each response (`AnswerSource`/`ResponseEvidenceStore`), so an answer
can show what it was grounded in. Sources carry the retrieval layer's OWN typed ids, so clicking
one opens the entity it genuinely pointed at - nothing is reconstructed from answer text and no
citation is ever invented. A universal `EntityInspectorSheet` reached from any source gives
decision → work item → project → person traversal, and says "Not linked to a tracked work item"
when that is the truth.

**Screen-capture defect found and fixed (security + grounding).** Every response silently
captured and uploaded a full screenshot, with no setting and no disclosure. This explains the
hallucination recorded under Phase 4.4: on `9-negative-retrieval` the assistant described a
hotel-pricing codebase in detail because that codebase was open on screen - it was reading the
screen, not recalling prior knowledge, which also corrects the earlier "generation
nondeterminism" reading (the two arms' TEXT contexts were byte-identical; their IMAGES were not).
It is also a privacy defect: the captured screen included an open `.env` with a live API key.
Screen context is now **off by default**, and when on the frame is disclosed as a source.
Regression-tested in `AnswerSourceTests`.

**Round-trip, timeline, onboarding, customisation.** The signature interaction is complete:
an inspector offers "Ask AI about this" (which SEEDS the composer rather than sending, so the
user stays in control) and "Open in graph" (which selects and centres that node - the graph model
is now owned by the window so a focused node survives navigation). Graph nodes hand off to the
same universal inspector via `GraphNode.entityReference`. A global `ActivityTimelineView` renders
real `ProjectEvent` rows grouped by day, filterable by project and by the three groups a founder
actually distinguishes; entries open the entity they happened to, and are non-clickable when the
id no longer resolves rather than linking to the wrong thing. First-run onboarding explains the
model in four cards. Settings gained appearance (system/light/dark, applied to the workspace
window only so the overlay keeps its dark treatment) and density.

Two naming defects caught and fixed during this work, both the same mistake: a type that belongs
to the domain was declared inside a SwiftUI view file (`EntityReference`, then `AppAppearance`/
`AppDensity`), making it invisible to the test package; and a view named `TimelineView` silently
shadowed SwiftUI's own `TimelineView`, rebinding the animation in `AvatarBlobView`.

**Core loop LIVE VALIDATED.** Two real end-to-end runs through the production path (production
`AIEngineController.requestResponse()`, production `ContextEngine`, production
`GeminiResponseGenerator`, production `ResponseEvidenceStore`; nothing mocked):

| question | project | answer | sources | navigable |
|---|---|---|---|---|
| "What did we decide about the demand pipeline?" | Hotel Revenue | correct and specific | 7 | 7/7 |
| "Why did we rule out conformal prediction?" | Trustworthy AI | correct and specific | 11 | 11/11 |

Every source id was independently resolved back to a real record in the store. Three real defects
were found BY RUNNING IT, none of which any test had caught:

1. **Typing required the microphone.** `requestResponse()` guarded on `isActive` - the AUDIO
   master switch - so asking a typed question meant switching on the mic and opening a Gemini
   Live session. Response generation is a plain REST call that needs neither. Listening and
   answering are now independent.
2. **A new chat had no project scope**, so `ProjectResolution` Tier 1 failed, retrieval had
   nothing to scope to, and the founder's first question always returned "I don't have that
   stored" - with 0 sources. The composer now carries a visible project selector that links the
   session through the existing `ProjectSessionLink` mechanism. Same question, after: 7 sources.
3. **Sources cited the current conversation and listed the same meeting twice** (once as an
   episode, once as historical evidence). Self-citation is circular, and one entity is one source
   however many retrieval layers surfaced it. Both fixed and regression-tested.

Also finished: search results gained Ask AI / Open in Graph actions using the same entity
resolution as the inspector, and the density setting now actually drives row rhythm (spacing
only - type sizes are deliberately not scaled).

Tests: **697 passing, 1 skipped** (down from 789 by removing ~115 experiment-only tests, not by
weakening coverage). Debug and Release both build.

## Next

### Phase 3 — Screen understanding
STATUS: not started. `sendLiveImageChunk()` still exists on `AIEngineController`; the
screen-recording permission check is no longer a stub (`CGPreflightScreenCaptureAccess` in
`Utilities.swift`); `ScreenCaptureManager.swift` does not exist, so nothing produces frames.
`sendLiveImageChunk()` already exists as a pass-through on `AIEngineController` /
`GeminiLiveClient`, but nothing produces frames to feed it yet — no `ScreenCaptureManager`.
- New `ScreenCaptureManager.swift` (ScreenCaptureKit), periodic (≤1 FPS) JPEG frame, in-memory
  only, never written to disk.
- Needs a decision: fold into the transcription-only Live session (adds visual grounding to
  transcription, but that connection no longer produces replies so an image alone doesn't do
  much there), or send the latest frame alongside the transcript in the one-shot response
  request instead (matches the current response architecture better - "answer this, and here's
  what's on screen right now").
- Real screen-recording permission check (`PermissionsManager` already has the accessibility
  check; screen-recording check is still a stub) with graceful degradation if denied.

### Phase 4 — Local storage & meeting recall
NOTE: partly overtaken by the project-intelligence track above (which introduced `Meeting.swift`,
`EpisodeSummary`, and a `MeetingRecord` table inside `ProjectStore`). `MeetingStore.swift`,
`MeetingHistoryView.swift` and `MeetingPlatformDetector.swift` do NOT exist; the Teams bundle-ID
fix listed below is already done (`Utilities.swift`). Re-scope before starting.
- `MeetingStore.swift`: Core Data with an in-code `NSManagedObjectModel` (no `.xcdatamodeld`
  bundle, avoids another manual Xcode resource registration) - start time, duration, platform,
  participants, full transcript, AI summary, user notes.
- On Stop listening (or app quit while active), ask Gemini for a short summary and save a
  `Meeting` record.
- `MeetingHistoryView.swift`: scrollable list + text search, detail view with transcript/
  summary/editable notes.
- Fix `MeetingPlatformDetector`'s stale Teams bundle ID (`com.microsoft.teams` →
  `com.microsoft.teams2`, same fix already applied to `TeamsParticipantDetector`).

### Phase 5 — Personalization & polish
- Proactive recall: cheap local match against `MeetingStore` by participant/platform at
  session start, surface "last time with this group: …" from a prior summary.
- Per-session persona override (Interview / Sales call / Board meeting) without touching the
  saved default in Settings.
- Live session indicator ("connected · Xm streaming") so the always-on state and implicit
  cost is never a silent black box.
- `HotKeyManager` polish for History/Settings shortcuts if the above land.

## Verification checklist (every phase)

1. `DEVELOPER_DIR="/Users/shivamtiwari/Downloads/Xcode-beta.app/Contents/Developer" xcodebuild -project FounderOfficeCopilot.xcodeproj -scheme FounderOfficeCopilot -configuration Debug build` — must end `BUILD SUCCEEDED`, zero warnings.
2. `cd AutomatedTests && DEVELOPER_DIR=... swift test` — all tests pass.
3. Manual run-through of the phase's behavior, in a real call where possible.
4. Confirm no regression to what already works: no API key configured still degrades
   gracefully, screen-recording denial (once Phase 3 lands) still degrades gracefully.
