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
- Auto-categorize on SimpleFIN import (Preferences toggle `aiAutoCategorize`, default OFF):
  in `importSimpleFIN`, after building the plan, run suggestions for uncategorized drafts and
  apply only when confidence ≥ 0.75; count applied in ImportSummary line (extend the summary text,
  not the struct's stored properties, unless trivial).

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
