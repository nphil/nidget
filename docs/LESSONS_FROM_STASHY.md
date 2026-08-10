# Lessons from Stashy → Nidget

Distilled from Stashy (`nphil/stashy`, iOS 26 SwiftUI media client): `docs/PERF_STABILITY_REVIEW_2026-07-01.md`,
`docs/OPTIMIZATION_PLAN_2026-06-30.md`, `docs/ENGINEERING_NOTES.md`, `CLAUDE.md`, and shipped source
under `ios/Stashy/`. Only **proven/observed/shipped** mechanisms are included; speculative/refuted
findings are dropped. Context gap to remember: Stashy runs Swift 6 strict concurrency; Nidget's
`ARCHITECTURE.md` pins `SWIFT_VERSION = 5.0`, no strict concurrency — treat §2's concurrency items
as voluntary discipline, not compiler-enforced. Stashy is video-heavy; §5 filters out what doesn't
transfer to SQLite lists / Swift Charts / themed cards.

---

## 1. SwiftUI performance rules Stashy adopted

**Static decorative layers get one identity key, never re-evaluate on scroll.** `ThemedBackground`'s
`MeshGradient` body reads only theme/tuning and is `.id()`-tagged by a `Hashable` struct of exactly
those inputs — free while scrolling, and correctly replaces a stale off-screen tab's retained layer
on theme change. `MeshGradient(...).id(BackdropIdentity(theme:, vibrancy:))`. Apply to Nidget's
`Backdrop.swift` — 40 themes + a tab structure that keeps stale views alive is the same shape.

**Never track a per-frame geometry value in `@State` on a scroll hot path.** `onGeometryChange` on
`.frame(in: .global)` fires every scroll frame; writing it to `@State` re-renders every visible cell
at 120 Hz (Stashy shipped and reverted this judder). Track only stable values (cell `size`) in a
reference box, not `@State`; reconstruct global origin later, on demand, from a gesture's own
coordinate converter. Applicable to transaction-row swipe actions or a category long-press preview.

**Rasterize a dense, mostly-static overlay with `.drawingGroup()` — scoped narrowly.** Stashy's
debug stats panel (dozens of translucent text/bar layers redrawn every compositor frame) got
`.drawingGroup()` around the static rows only; the interactive `Toggle` stayed outside (interactive
controls rasterize poorly). Same shape for a dense dashboard sparkline/gauge cluster: group the
static marks, keep buttons/pickers out.

**Debounce query changes; dedupe async work with a generation token.** `PaginatedLoader<T>` discards
results from a superseded in-flight load via a generation token, plus a ~250 ms debounce on query
text. Apply to Nidget's transaction search/filter and Chart data recomputed on filter change — else
a slow query resolving late overwrites a newer result.

**Actor caches need in-flight coalescing, cleared on both success and failure paths.** Stashy's
`ImageCache.image(for:)` had none — actor reentrancy let concurrent callers for the same key both
pass the cache-miss check, 2–5x duplicate fetch/decode. Fix: actor-local
`inFlight: [Key: Task<Value, Error>]`, join-or-create, remove the entry in a `defer` covering
**both** outcomes (clear-on-success-only permanently poisons the key after one failure). Use for
category-icon caches and derived-chart-data caches keyed by month/account. **Cancellation hazard:**
a view-cancelled `.task(id:)` awaiting the shared task must not propagate cancellation into it and
abort every other awaiter — shield with an unstructured inner task if multiple views share a key.

**Cost caches by decoded bytes, not encoded bytes.** Stashy's `NSCache.cost` was JPEG byte count
against a decoded UIImage bitmap — 10–20x under real memory cost, bounded only by `countLimit` in
practice. Fix: `cgImage.bytesPerRow * cgImage.height` as cost, and set `totalCostLimit` on purpose.
Applies to any decoded-image or rendered-chart-snapshot cache.

**Disk/memory eviction needs hysteresis.** Evicting to *exactly* the cap means the next write goes
back over it, triggering a full scan+sort every time. Evict to an ~85% low-water mark instead —
amortizes the scan. Relevant if Nidget caches rendered chart/report images to disk.

**Glass only over vibrant/varied content; solid fills for small repeated elements.** Stashy's filter
chips read invisible glassed over a flat material panel; fixed as glass *container* + solid *chips*.
For Nidget: reserve `glassEffect` for surfaces over the mesh/chart backdrop, keep category pills and
account badges solid — cheaper to composite at scroll speed too.

**`.contentTransition(.numericText())` + `.animation(.snappy, value:)` for rolling numbers.** Shipped
on Stashy's selection-count and progress digits. Nidget's own architecture doc already wants this on
hero balances — extend to every animated total: category remaining, transaction count, FI-number
ticking during a Monte Carlo re-run.

**Keep the modifier chain unconditional; gate the *effect*, not the view's structural type.**
Wrapping a grid/list in `if isPresented { … }` around an overlay/popover host changes structural
identity for the whole subtree, forcing a full rebuild + animation restart. Keep the modifier always
present; disable with `.allowsHitTesting(false)` / `GestureMask.none` / opacity when inactive.

**Host popovers/dropdowns from a stable sibling, never from a view whose branch can flip.** A
`.popover` hosted inside a `@ViewBuilder` that switches grid/spinner/empty branches gets torn down
and re-presented (flicker) every branch flip. Host from a dedicated, always-present `ZStack` sibling
instead — applicable to a dashboard-widget config popover or a transaction filter panel over a list
that can be loading/empty/populated.

**Disable animation via `.transaction` for scroll-driven dismissals.** `.transaction { $0.animation =
nil }` on a subtree makes a scroll-triggered dismiss vanish on the first moving frame instead of
visibly sliding away mid-scroll, without touching global animation config.

**`LazyVStack`/`LazyVGrid` for any transaction list or dashboard widget grid**, never eager
`VStack`/`Grid` for data-driven collections. Pair with the `.task(id:)` cancellation guard below for
row-level async work (icon loads keyed to row identity).

**`.task(id:)` must guard against a superseded task writing stale results.** A cancelled search task
that skips `Task.isCancelled` before writing shared `@Observable` state clobbers a newer task's
results — Stashy's search flashed "No Results" between keystrokes from exactly this. Check
`!Task.isCancelled` before every state write, including "turn off the spinner" (a stale task that
already set `isLoading = true` must not clear a newer task's spinner).

**Hide scroll indicators globally, once, at launch.** `UIScrollView.appearance()` indicator flags off
in app init plus `.scrollIndicators(.hidden)` on root content (propagates via environment), rather
than annotating every `ScrollView`/`List`. Cheap standing polish for a minimal-chrome look.

---

## 2. Stability / correctness gotchas

**SQLite "database is locked" needs retry-with-backoff, not a surfaced error.** Stashy's client
retries a lock conflict at 500/1000/1500 ms. Nidget owns SQLite directly with a CRDT sync engine
writing concurrently with UI writes — the exact shape that produces `SQLITE_BUSY`. Wrap writes in
the same backoff instead of surfacing a transient lock as a user-facing error.

**Optimistic UI edits need a per-id sequence token, checked on success AND rollback.** Stashy's
rating edits raced: tap 3★ then 5★ fires two independent async writes with no ordering, so a
slow-to-return first write overwrites the second on server AND UI ("snap-back"). Fix:
`editSeq: [String: Int]`, capture a token at edit time, apply the response only if the token still
matches — gate the failure/rollback branch the same way, not just success. Applicable to Nidget's
transaction/category quick-edits racing the CRDT sync engine's own writes.

**A poll/refresh loop behind visible UI must never silently self-terminate.** Two Stashy bugs: a
nullable-vs-empty-list server field decoded as a failure on every "no items" tick, which after
enough consecutive failures quietly stopped the poll loop (UI froze on stale data, no error shown);
a re-engage poller abandoned on a transient readiness flag instead of loss of user intent, with no
log line marking the give-up. Distinguish "genuinely empty" from "decode/transient failure"
explicitly; on repeated failure show a reconnecting/stale state and keep retrying with backoff.
Relevant to Actual-server sync-status polling and any timer-driven Monte Carlo recompute.

**Actor reentrancy silently duplicates concurrent identical work** — see in-flight coalescing in §1.
A correctness issue, not just perf, whenever the duplicated work has side effects (a sync request,
a write-through cache).

**`try?` flattens nested optionals (SE-0230)** — `try? url.resourceValues(forKeys:).fileSize` is
`Int?`, not `Int??`; don't write `?? 0 ?? 0`.

**`Double.isFinite` does not guard `Int(_:)` conversion.** `.greatestFiniteMagnitude` passes
`isFinite` and still traps in `Int(x)`. Stashy crashed on exactly this converting
`UIApplication.backgroundTimeRemaining`'s sentinel. Clamp by magnitude before any `Double → Int`
conversion that might see a sentinel/extreme value — never trust `isFinite` alone.

**A `View` struct's synthesized `init` requires call-site args in declaration order** — Swift won't
reorder labelled arguments. Adding a `@Binding` mid-struct without updating call sites is a real
build-breaker; re-check call sites whenever a reusable view's stored-property order changes.

**Wrap non-Sendable framework objects in a tiny `@unchecked Sendable` box before crossing an actor
boundary**, rather than fighting the type system per call site (Stashy did this for
`URLSessionTask`/`AVAssetWriterInput`). If Nidget's Actual networking or zip/crypto layer
hands a non-Sendable completion payload into a `@Sendable` closure, this is the lowest-friction fix.

**`NotificationCenter.addObserver(..., queue: .main, using:)`'s block is `@Sendable`**; to call a
`@MainActor` method from it synchronously (before any suspension point), use
`MainActor.assumeIsolated { … }`, not `Task { @MainActor in … }` (which defers a runloop tick).
Matters for app-lock/backgrounding transitions where frame ordering counts (`AppLockScreen`,
privacy blur on backgrounding).

**A memory-warning/low-resource handler must not block the main thread**, and any `enable()`-style
setup callable more than once needs an idempotency guard checked *before* registering — Stashy
stacked duplicate observers across repeated Settings toggles, each doing a blocking flush.

---

## 3. Build settings & Info.plist keys for a smooth 120 Hz app

Already known and present in Nidget: `CADisableMinimumFrameDurationOnPhone: true` (opts out of the
60fps cap so custom animation/CADisplayLink hits full ProMotion) and `VALIDATE_PRODUCT: NO` (Release
config). Additional Stashy settings worth confirming/adopting:

- `SWIFT_OPTIMIZATION_LEVEL: -O` (Release) / `-Onone` (Debug), with `DEBUG_INFORMATION_FORMAT:
  dwarf-with-dsym` / `dwarf` — set explicitly rather than trusting Xcode template defaults; a
  debug-level optimization accidentally shipped in Release is a common silent perf regression.
- `ENABLE_USER_SCRIPT_SANDBOXING: NO` — only relevant if a Nidget build-phase script needs to write
  outside the sandboxed script environment (e.g. touching `project.pbxproj` at build time).
- Hide scroll indicators app-wide via `UIScrollView.appearance()` at launch (§1) — not a plist key,
  but a one-time startup config worth pairing with a build-settings pass.
- `UIApplicationSceneManifest`/`UISceneConfigurations` and Stashy's `UIBackgroundModes` entries exist
  for its XR-glasses external display and download-keep-alive features — **do not port these** (§5).
  Nidget's Info.plist should stay minimal: ATS, Face ID string, launch screen, as `ARCHITECTURE.md`
  specifies.
- If Nidget ever needs background sync convergence with the Actual server while idle,
  `BGProcessingTask` (registered once in `didFinishLaunchingWithOptions` — a second registration call
  **kills the app**) is the legitimate mechanism: it only runs while the device is idle, a catch-up
  path, not "keep syncing while backgrounded." Don't reach for anything stronger for sync (§5).

---

## 4. CI lessons from Stashy's `ios-build.yml`

Nidget's own workflow already mirrors several of these (version bump + tag + release, IPA-size
floor, fail-fast compile-error grep); this documents *why* each guard exists so the reasoning
survives independent of the current workflow text:

- **Tee raw `xcodebuild` output, tolerate the pipeline's own exit code, then grep the precise
  `<path>:<line>:<col>: error:` pattern and `exit 1` explicitly.** Guards against a swallowed
  non-zero exit (from `xcpretty`, or a tolerated non-fatal validation step) letting a real compile
  failure show green until a much later step; the exact pattern avoids false-positiving on log prose
  containing the word "error".
- **Emit GitHub `::error file=…,line=…,col=…` annotations from the same grep** — a failed Build step
  is immediately actionable, no log spelunking.
- **A pure linker error carries no `line:col` and slips past the grep** — caught downstream by an
  explicit "built executable present and non-empty" check before packaging, since a broken
  compile/link can otherwise leave a skeleton `.app` that fails much later, or not at all.
- **An IPA byte-size floor as a backstop**, not the primary gate — catches a "successful" package
  step that zipped an empty/broken shell (Stashy saw ~60 KB stub IPAs before this existed). Set the
  floor comfortably below the real app's typical size.
- **Doc-only pushes must not trigger a build** (`paths-ignore` on `**/*.md`, `docs/**`) — saves CI
  minutes for actual code changes.
- **CI auto-commits a version bump `[skip ci]` and pushes/tags on success** — `origin/main` moves
  without the pusher's local branch knowing. Discipline: always `git fetch origin main && git rebase
  origin/main` right before pushing to `main`, or the auto-bump commit races a manual push.
- **Verify the actual published artifact after every push, not just a green check** — Stashy once had
  a `|| true` mask a real failure and ship a broken artifact under a green run. Confirm the release
  asset's size actually changed when a code change was expected.

---

## 5. DO NOT copy — Stashy techniques specific to video/FFmpeg/Live Activity

- **The entire download engine**: 8-way parallel range requests → background handoff, the `-3000`
  background-`URLSession` saga, 64 MB slicing, resume-blob banking, the `beginBackgroundTask`/
  `DownloadKeepAlive` silent-audio-loop trick that renews background runtime indefinitely,
  `BGContinuedProcessingTask`. Nidget's sync payload is small CRDT messages, not gigabyte media —
  none of this applies, and the silent-audio keep-alive is not appropriate for a budgeting app.
- **`FFmpegRemuxer`, `VideoTranscoder`, `LoopbackServer`, `AVPlaybackEngine`, `ScrubFrameProvider`,
  `SlowMoInterpolator`/`VTFrameProcessor`** — codec/container/playback-pipeline specific (HEVC
  remuxing, AV1 hardware-decode gating, playhead-paced on-device remux). No video in Nidget.
- **Live Activity / Dynamic Island download-progress payload** (bytes/speed/ETA `ContentState`, the
  8-segment bar, `pushType` token investigation) — built for long-running transfers; no comparable
  long-running job in a budgeting app to narrate on the Lock Screen.
- **XR glasses (Viture Pro) external-display scene**: multi-scene manifest, external-display role,
  the 10-foot remote-gesture pipe. No external-display use case in Nidget.
- **`RemoteLog`/ntfy telemetry transport** — debug-log-over-HTTP-push built for a no-Mac debugging
  loop. Use ordinary `os_log`/Console instead; don't port the ntfy batching/rate-limit logic.
- **Loopback `NWListener` media server** — only exists because AVPlayer needed a local HTTP endpoint
  to stream a growing remux file. No equivalent need.
- **Codec/hardware-decode capability gating** (chroma subsampling, bit depth, AV1 chipset gating) —
  entirely video-specific domain knowledge, not applicable to financial data.
