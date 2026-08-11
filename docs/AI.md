# Nidget Intelligence — architecture & contracts

On-device AI ported from the user's HomeBoy app (checked out read-only at
`/workspace/nphil/homeboy` — **read its sources before implementing**), adapted for budgeting.
Everything runs locally: llama.cpp (Metal/CPU) with user-downloaded GGUF models from Hugging Face.
No cloud calls, ever. All AI features degrade gracefully to nothing when no model is installed.

## 1. Supply chain (improved over HomeBoy)

HomeBoy commits a prebuilt `llama.xcframework` via Git LFS. Nidget instead treats it as a
**release asset** so the repo stays lean:

- `scripts/build-llama-xcframework.sh` — adapted from HomeBoy's (functions copied verbatim where
  possible). Difference: no submodule; the script shallow-clones
  `https://github.com/ggml-org/llama.cpp` at pinned commit `0ed235ea2c17a19fc8238668653946721ed136fd`
  (HomeBoy's proven pin — bump deliberately, never implicitly) into `build/llama.cpp`, then builds
  the iOS-device (arm64) slice only, Metal embedded, and zips the result to
  `build/llama.xcframework.zip`.
- `.github/workflows/build-llama-xcframework.yml` — manual dispatch, macos-15, Xcode 26.x pinned
  the same way as ios-build; runs the script and publishes the zip to a GitHub release tagged
  `llama-0ed235e` (tag = `llama-<pin7>`, marked prerelease so Feather's apps.json flow ignores it;
  `gh release create --prerelease` and delete+recreate if the tag exists).
- `scripts/fetch-llama-xcframework.sh` — downloads that release zip and unpacks to
  `Frameworks/llama.xcframework` (skips when already present and non-stub). Used by BOTH local
  devs (README documents it as a one-time step before opening Xcode) and CI.
- `ios-build.yml` gains a "Fetch llama.xcframework" step (after checkout, before build) calling the
  fetch script, with `actions/cache` keyed on the pin so the ~1-minute download amortizes. If the
  release asset doesn't exist, fail with a clear `::error::` telling the operator to run the
  Build llama.xcframework workflow first.
- `Frameworks/` is gitignored.

### Xcode project wiring (hand-edited pbxproj — preserve current version numbers!)

- `SWIFT_OBJC_BRIDGING_HEADER = Support/Nidget-Bridging-Header.h` (new file, contains
  `#import "LlamaBridge.h"`), `HEADER_SEARCH_PATHS = $(inherited) $(SRCROOT)/Nidget/AI/Bridge`,
  `CLANG_CXX_LANGUAGE_STANDARD = gnu++17` (replaces gnu++20 — match HomeBoy), and
  `FRAMEWORK_SEARCH_PATHS = $(inherited) $(SRCROOT)/Frameworks` on BOTH target configs.
- llama.xcframework: PBXFileReference (`wrapper.xcframework`, path `Frameworks/llama.xcframework`,
  sourceTree `<group>`), linked in the Frameworks build phase, embedded via a new
  PBXCopyFilesBuildPhase (dstSubfolderSpec = 10, "Embed Frameworks") with
  `ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy)` on the build file (CodeSignOnCopy is safe:
  unsigned CI builds skip signing; Xcode device builds re-sign).
- `LlamaBridge.h` / `LlamaBridge.mm` live in `Nidget/AI/Bridge/` — the synchronized group compiles
  the `.mm` automatically; the header is found via HEADER_SEARCH_PATHS.

## 2. Engine layer (`Nidget/AI/`) — port from HomeBoy, adapt persistence

Port these files, keeping HomeBoy's names and semantics unless noted (each file carries a header
comment: "Ported from HomeBoy (nphil/HomeBoy) — keep in sync deliberately, not automatically."):

- `Bridge/LlamaBridge.h`, `Bridge/LlamaBridge.mm` — byte-for-byte copies.
- `LlmKit.swift` — verbatim (LlamaBackend, EngineStatus, LlmKit facade, ChatBenchmark).
- `ModelCatalog.swift` — verbatim (ModelPurpose, ModelSpec; empty builtIn — user curates).
- `ModelDownloadManager.swift` — port; storage dir = Application Support/Models (excluded from
  iCloud backup via URLResourceValues.isExcludedFromBackup).
- `HuggingFaceRepository.swift` — port (HF search API + repo file listing for GGUF discovery).
- `AIModelManager.swift` — port the lifecycle (load/unload per purpose, auto-unload timer,
  backend preference, EngineStatus publishing) but persist via `Preferences` keys:
  `aiCustomModelsJSON`, `aiEmbeddingModelID`, `aiGenerationModelID`, `aiBackend`,
  `aiAutoUnloadMinutes` (default 5). `@MainActor @Observable final class AIModelManager`
  (`static let shared`) with a nested worker actor for blocking llama calls — UI never blocks.

## 3. Budget-specific AI (`Nidget/AI/`) — new code

### EmbeddingIndex (semantic memory over transactions)

`actor EmbeddingIndex` backed by its own **local-only** SQLite file (`nidget-ai.sqlite` next to the
budget file; never synced to the Actual server; uses the existing `SQLiteDB` wrapper):

```sql
CREATE TABLE IF NOT EXISTS tx_embeddings (
  tx_id TEXT PRIMARY KEY, model_id TEXT NOT NULL, text_hash TEXT NOT NULL, vector BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
```

- Embedded text for a transaction: `"<payee name> — <notes>"` (skip empty parts; lowercased).
- `func reindex(transactions: [(id: String, text: String, categoryID: String?)], model: …)
  async` — incremental: (re)embeds only rows whose `text_hash` (SHA256 of text+modelID) changed;
  batches of 32 between `Task.yield()`s; publishes progress `(done, total)` via an
  `AsyncStream` or observable mirror on AIModelManager.
- `func nearest(to text: String, limit: Int) async -> [(txID: String, similarity: Float)]` —
  brute-force cosine over in-memory cache of vectors (loaded once, refreshed on reindex; a few
  thousand 384–768-dim vectors is well under 50ms).
- Vectors stored as little-endian Float32 BLOBs. Wipe-and-rebuild when the embedding model changes.
- `disconnectAndWipe()` in AppStore must also delete `nidget-ai.sqlite`.

### CategorySuggestionService

`@MainActor final class CategorySuggestionService` (owned by AppStore or environment-injected):

- `struct CategorySuggestion { var categoryID: String; var confidence: Double; var source: Source
  ; enum Source { case knn, llm } }`
- `func suggest(payee: String, notes: String?, limit: Int = 3) async -> [CategorySuggestion]`:
  1. kNN: embed the text, take K=12 nearest categorized transactions, weighted vote
     (weight = similarity²; recency multiplier 1.0→0.5 over 18 months), confidence = top weight
     share of total. **Fast path — no generation model needed.**
  2. LLM refinement (only when a generation model is loaded AND top confidence < 0.55): chat with
     a compact prompt — category names list + transaction text + top-3 kNN candidates — asking for
     exactly one category name; match the reply back to a category id (case-insensitive; reject
     hallucinated names, keep kNN answer on mismatch).
- Auto-categorize newly synced bank transactions (Preferences toggle `aiAutoCategorize`, default
  OFF): after a sync completes and changed the `transactions` dataset, `AppStore` looks at bank-
  imported transactions from the last 45 days that are still uncategorized (`importedID != nil`,
  not a transfer, not a split parent), runs `CategorySuggestionService.suggest(...)` on up to 50
  of them per run, and applies only picks with confidence ≥ 0.75 as one batched write. Ids already
  tried this session are skipped on later syncs. Works no matter who imported the transactions —
  the app no longer imports bank data itself, so this only ever sees rows the Actual server's own
  bank sync delivered.

### Semantic search (hybrid)

In TransactionsView: when search text is non-empty and the embedding index is ready, results =
substring matches (existing query) ∪ semantic matches (`nearest(to:)` filtered similarity ≥ 0.55),
substring hits first, semantic-only hits after under a subtle "Related" SectionHeader with a
sparkle icon. Zero behavior change when no embedding model is installed.

### Quick Add

When PayeeField resolves a payee that has no historical category (store.suggestions returns no
categoryID), fire `suggest(...)` and surface the top suggestion as a highlighted chip with a
`sparkles` SF symbol prefix (tap = accept). Never auto-apply. Cancel in-flight work with
`.task(id:)` discipline.

## 4. Management UI (`Nidget/Features/Settings/Intelligence/`)

Settings gains an "Intelligence" card (sparkles icon, shows: models installed count / "Off").
Pushes `IntelligenceView` (Route case `intelligence`) — themed cards, NOT stock Forms:

- **Models**: two slots (Embedding, Generation) — each shows selected model, size, load state
  (loaded/backend/auto-unload countdown from EngineStatus), Load/Unload button, model picker from
  installed models; "Add from Hugging Face" → `HuggingFaceBrowserSheet` (search, pick repo, list
  GGUF files with sizes, download w/ progress bar, cancel; adds ModelSpec + starts download);
  installed model rows: delete file (swipe), re-download.
- **Backend**: ChipPicker Auto / GPU (Metal) / CPU.
- **Search & Suggestions toggles**: semantic search, quick-add suggestions, auto-categorize
  imports (with confidence explanation footnote).
- **Index**: "N of M transactions indexed", Reindex button with progress bar, model-change hint.
- **Benchmark**: pushes `AIBenchmarkView` port (tokens/sec, prefill ms for the loaded generation
  model; embedding throughput for the embedding model) with Nidget theming.

## 5. Conventions

Same rules as the rest of the app (ARCHITECTURE.md §4–6, §16): themes via environment, AmountText
for money, no third-party Swift deps (llama.xcframework is a binary, not SPM), no force unwraps,
os.Logger (`category: "ai"`), never log transaction text or model prompts at `.default` level
(`.debug` only). Every AI feature checks `AIModelManager.shared` state and renders its absence
as helpful empty states, not errors.

## 6. Two generation backends (`AIModelManager` is the router)

Text generation has two interchangeable backends. Embeddings do **not** — the semantic index is
llama.cpp only, because Apple's framework exposes no embedding API to build it from.

- **llama.cpp** (`AIModelManager.Engine(purpose: .generation)`) — a downloaded GGUF model.
  The default (`Preferences.aiGenerationEngine == "llama"`) and unchanged in every respect.
- **Apple Foundation Models** (`Nidget/AI/FoundationModelEngine.swift`) — the phone's built-in
  on-device model. Nothing to download. `@MainActor @Observable` rather than an actor: inference
  happens out of process, so `respond(to:)` is a plain async suspension with no blocking work to
  move off the main thread, and main-actor isolation lets SwiftUI and `AIModelManager` read
  availability synchronously in `body`. `import FoundationModels` is wrapped in
  `#if canImport(FoundationModels)` so an older CI SDK still compiles; the false branch reports
  `.frameworkUnavailable` and generates nothing.

**Availability** is mirrored into Nidget's own `FoundationModelAvailability` so no other file
imports the framework: `.available`, `.deviceNotEligible`, `.notEnabled` (Apple Intelligence is
off in system Settings), `.modelNotReady` (still downloading or warming up), `.frameworkUnavailable`.
`statusMessage` turns each into one plain line for the Intelligence screen, where the Apple option
stays visible but disabled with its reason underneath rather than disappearing.

**Routing.** Every text feature calls `AIModelManager.generate(system:user:maxTokens:temperature:topK:)`
and never picks a backend. `activeGenerationEngine` decides: the selected engine if it can answer,
then whichever other one can. That last step matters — a phone with Apple Intelligence on and
nothing downloaded still gets working text features, which is what makes `generationReady` (true
when *either* backend can produce text) an honest gate for UI like the Retirement screen's
"Explain my plan" card. If the Apple call comes back nil, the router falls through to llama, but
only when a downloaded generation model is actually there. Generation on Apple's model passes
`GenerationOptions(temperature:)` only, and every session is created fresh per call: sessions are
stateful multi-turn transcripts, so reuse would grow context until the window overflowed.

**Batch refinement cap.** `CategorySuggestionService.refinedCategoryID` used to gate on "the llama
model is already loaded", which is almost never true mid-sync and kept LLM refinement rare by
accident. Apple's model has no load step, so that gate has nothing to bite on. The batch path
therefore spends from a budget: `AppStore.autoCategorizeNewArrivals` calls
`resetRefinementBudget(8)` before walking its (up to 50) candidates and `endRefinementBudget()`
after, and refinement refuses once the budget hits zero. Interactive suggestions (Quick Add, one
at a time, user watching) have no budget set and are never limited.

## 7. Review queue (`AppStore.reviewQueue`, `Nidget/Features/Review/`)

Bank imports happen server-side (Actual's own SimpleFIN sync), so the owner's daily job is not
adding transactions, it is deciding what to do with the ones that showed up. The review queue is
that decision list, grouped so a whole category can be confirmed in one tap rather than row by row.

**Three sources, cheapest first.** Every candidate gets a proposal from the first source that can
answer (`ReviewSource` on each item records which one did):

1. **Payee history.** If this payee has been filed before, propose its most common category. One
   query over the last ~180 days of categorized, non-transfer transactions, reduced to
   `[payee id: category id]` once per queue build (never per item); ties go to the more recent
   filing. This is first on purpose. It needs no model downloaded, which is the state the app is
   in until the owner picks one, and for repeat spending it beats kNN outright: it is the actual
   answer the owner gave last time, not a neighbourhood vote about it.
2. **Embedding kNN** (`CategorySuggestionService.suggest`), only for payees with no history and
   only when `embeddingReady`. **Capped at 25 lookups per queue build** — each lookup embeds text
   and searches the index, so without a cap a 200-row queue would stall the screen it is opening.
   Candidates past the cap simply fall through to the third source.
3. **Nothing** — into the "Needs a category" group.

Proposals only ever point at categories that still exist, are not hidden, and are not income (the
same filter as `eligibleCategories()`, plus income). Candidates are uncategorized on-budget
transactions from the last 90 days, minus transfers and Actual's synthetic "Starting Balance" rows.

**Auto-filed spot checks.** `autoCategorizeNewArrivals` applies suggestions at confidence ≥ 0.75
without asking, so the queue shows those back in a third group ("Nidget filed these", rendered
collapsed) for a look. The ids live in `Preferences.aiAutoFiledIDs` (id → unix seconds), recorded
only after the enqueue actually lands. That map is **local only** — it is Nidget's own bookkeeping,
has no column on Actual's server, is never written into a CRDT message, and never syncs, exactly
like `categoryIcons` and the embedding index. It is **pruned at 30 days** (`pruneAutoFiled()`, run
at the start of every `reviewQueue`) and whenever an entry is confirmed, so it stays small.

**Costs.** `reviewCount()` is the badge/widget number (uncategorized in the window plus unconfirmed
auto-filed) and does one query, no AI, no payee map. `applyCategories(_:)` writes many category
changes as ONE batch — one `nextTimestamps` allocation, one `enqueue` — and returns each
transaction's previous category so the caller can offer Undo; passing a nil category clears it,
which is what Undo sends back.
