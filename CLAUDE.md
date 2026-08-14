# Nidget — project memory

Native SwiftUI iOS 26 companion for Actual Budget. Owner: Nitin (nphil). Sideloaded via
Feather from the apps.json source in this repo. CI on main builds, releases, and updates
apps.json on every push; versions derive from published v* tags, never the working tree.

## Standing rules (do not drop these)

1. **The in-app Guide must always match the app.** `Nidget/Features/Guide/` is a visual
   tutorial shown during onboarding and reopenable from Settings. Whenever a feature is
   added, removed, or meaningfully changed, update the relevant Guide page in the same
   change. This is a hard requirement from the owner.
2. **User-facing copy style**: plain, warm, natural sentences. No em dashes. Short words
   over jargon. Never sound like an LLM. The owner is new to envelope budgeting, so copy
   explains by showing, not lecturing.
3. Push to `main` only states that compile; the CI compile gate publishes every green push
   as a release straight to the owner's phone.
4. All AI is on-device (llama.cpp via `Frameworks/llama.xcframework`, a release asset
   fetched by `scripts/fetch-llama-xcframework.sh` — never committed, never LFS). No cloud
   AI calls, ever. The embedding index (`nidget-ai.sqlite`) is local-only and must never
   sync to the Actual server.
5. The Xcode project is a hand-written pbxproj using filesystem-synchronized groups: new
   Swift files need no project edits, but build-setting/framework changes are careful
   hand edits. Versions in it are CI-managed; preserve them when editing.
6. **App icons are drawn by a script, never by hand.** `scripts/render-app-icons.pl` writes
   the primary icon (light/dark/tinted) plus one alternate per theme, deriving each theme's
   colors from its own palette in ThemeCatalog. Add or recolor a theme and re-run
   `perl scripts/render-app-icons.pl`, then commit the PNGs it changes. Editing a PNG by hand
   is wasted work: the next run overwrites it.

## Key references

- `docs/ARCHITECTURE.md` — module contracts (binding). `docs/AI.md` — AI layer contract.
- `docs/PROTOCOL.md` — verified Actual sync wire protocol; raw SQLite column names for
  CRDT messages live here (e.g. transactions.description = payee id via payee_mapping,
  category via category_mapping.transferId — note the payee/category asymmetry).
- `docs/LESSONS_FROM_STASHY.md` — perf/stability rules ported from the owner's Stashy app.
- HomeBoy (`nphil/HomeBoy`) is the reference for the AI engine port; keep deliberate,
  not automatic, sync with it.

## Owner preferences observed

- Wants autonomy: make sensible decisions, call them out afterwards.
- Token-conscious: cheaper models for well-specced work, Fable for hard/judgment work.
- Cares about fluidity (120Hz, themed motion), one-screen dashboard, few-tap daily flows.
