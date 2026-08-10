# UX Round 2 — owner requests (2026-08-10, overnight batch)

Execute AFTER the AI/category push is green on CI. Owner is asleep; decisions below are
final unless they conflict with reality on disk. Copy style rule from CLAUDE.md applies
everywhere: natural sentences, no em dashes, never LLM-sounding.

## 1. Guide (tutorial) + onboarding integration — `Nidget/Features/Guide/`

A swipeable, paged visual guide (TabView .page style, themed) teaching BOTH envelope
budgeting (owner is new to it) and this app. Reachable two ways: full-screen cover after
first successful budget-file sync (skippable, `Preferences.hasSeenGuide`), and a
"How Nidget Works" card in Settings (book icon) that reopens it any time (Route.guide).

Seven short pages, each: title, 2-4 short sentences MAX, and a LIVE themed visual built
from the app's real components (not screenshots): mini mocks reusing ProgressRing,
AmountText, NidgetButton, chips, the floating + button, the cleared checkmark, a mini
widget tile. Highlight the actual control being described (accent ring + glow around it).

1. **Give every dollar a job.** Envelope budgeting in one idea: you only budget money you
   already have. Income lands in "To Budget", you deal it out to categories (envelopes),
   and each envelope's balance is what you can still spend. Visual: three envelope cards
   filling from a To Budget pill.
2. **The Budget screen.** Tap a budgeted amount to fill an envelope. Spent shows what left,
   the balance pill is what remains. A red balance means the envelope is empty: move money
   from another envelope (swipe for Move) instead of feeling bad. Visual: mock category row
   with the three numbers labeled by arrows.
3. **Log spending in seconds.** The + button opens Quick Add: amount, payee, done. Nidget
   learns your payees and fills the category next time. The checkmark circle on a
   transaction means your bank confirmed it (cleared); the lock means reconciled. Visual:
   keypad mini + a transaction row with callouts on the checkmark.
4. **Accounts and sync.** On-budget accounts feed your envelopes; off-budget (investments)
   just track worth. Bank imports set up on your Actual server show up here automatically;
   everything works offline and syncs to your Actual server when reachable (the little pill
   up top). Visual: two account cards + sync pill states.
5. **Your dashboard.** Press and hold any tile to rearrange, resize, or swap widgets.
   Tap a tile to jump to that part of the app. Visual: mini 2x2 grid with one jiggling tile.
6. **Retirement.** Link your investment accounts and Nidget projects when work becomes
   optional, using your real spending. Drag on the chart to explore; the sliders show how
   saving or spending differently moves the date. Visual: mini area chart with the
   "enough to retire" line labeled.
7. **Intelligence (optional).** Download a small model from Hugging Face and Nidget can
   suggest categories and find transactions by meaning ("that sushi place"). Everything
   runs on the phone; nothing is ever uploaded. Visual: sparkle chip + a suggested
   category chip.

Progress dots, Skip (top right), final page button "Start budgeting". Reduce Motion
respected on all page visuals.

**Maintenance rule (also in CLAUDE.md): every future feature change updates its page.**

## 2. Retirement planner overhaul — `Nidget/Features/Retirement/`

Reframe around the owner's actual question: "how far from retirement am I, and how does my
spending affect that?" Keep RetirementPlanner math; redesign presentation + inputs.

- **Hero**: "Retirement at ~58" (projected crossing age; "not yet in reach" state if nil)
  with years-to-go subline, then the FI progress ring second. Countdown is the headline.
- **Spending is the star input**: card showing average monthly spending from the last 12
  months of the ACTUAL data (store.monthlySpendSeries), a retirement-spending assumption
  defaulting to it (override keeps existing config field), and a live delta slider
  (spend $X less/more per month) that re-runs the planner and animates BOTH the chart and
  the hero age. One plain sentence under it: "Spending $150 less each month moves
  retirement about 11 months closer." (computed, not canned).
- **Chart made legible + interactive**: portfolio value vs AGE (not year). Single accent
  area; dashed labeled line "Enough to retire" (annotation text, not a bare rule); dot
  marker where the path crosses it with the age label; soft background tint change after
  retirement age. Drag to scrub: callout shows age, projected value, and what that value
  safely provides per month (value * SWR / 12 via AmountText). Segmented toggle
  Simple / Detailed: Simple hides the Monte Carlo bands, Detailed shows p10-p90 bands +
  success probability row. Default Simple (owner found bands confusing).
- **"What would help" card**: three computed rows (each re-runs the planner):
  +$100/mo contributions, -$100/mo spending (note it helps twice: smaller target and more
  saved), +1% return. Each row: lever, "retire ~N months earlier", chevron applies it to
  the what-if state.
- **Milestones row**: Coast FIRE age with a one-sentence explanation, and halfway-to-FI.
- **Contribution auto-detect**: show "detected from your transfers" monthly contribution
  (average net inflow to linked accounts over 6 months, computed via a TransactionQuery
  over transfer transactions into linked account ids) with manual override retained.
- **Optional AI summary**: when a generation model is loaded, an "Explain my plan" button
  produces a 3-4 sentence on-device narrative of the current what-if state (temperature
  0.3, facts injected into the prompt: ages, amounts, probability; reject/clip rambling
  output at 4 sentences). Hidden entirely when no model is installed.

## 3. Budget month picker — native feel

Replace the month ChipPicker row in BudgetView's header: chevrons stay, the month title
("August 2026") becomes tappable and opens a sheet (detent ~360): year stepper header
(chevrons + year label) over a 3x4 grid of month abbreviations; current month ringed,
selected month accent-filled, future months beyond next month dimmed but selectable, months
with no data still selectable. Selecting closes + navigates with the existing spring
animation. File: MonthPickerSheet.swift in Features/Budget/, reusable by Reports later.

Superseded 2026-08-10: the header row is gone. The same chevrons and tappable month title (and
MonthPickerSheet itself, unchanged) now live in the navigation bar's principal slot with
`.navigationBarTitleDisplayMode(.inline)` and no "Budget" title, so the List is the whole screen
and scrolls under the bar.

## 4. Transactions filter bar redesign (screenshot bug)

Today an account ChipPicker scrolls while the Uncategorized toggle chip sits pinned to the
right and OVERLAPS the scrolling chips (owner screenshot). Fix per iOS conventions: ONE
horizontally scrolling row containing all filters together: [All] [account chips...] then a
thin separator dot, then [Uncategorized] as a toggle chip (question-mark icon, warning tint
when active). Nothing pinned, nothing overlapping. Uncategorized active state must remain
discoverable when scrolled away: when it is ON, show a small warning-tinted dot on the
leading edge of the search field as a reminder (tap clears the filter).

Superseded 2026-08-10: the whole chip row (and its reminder dot) is gone. Account and
Uncategorized are now one `line.3.horizontal.decrease.circle` Menu in the trailing toolbar (an
inline Picker of All Accounts + open accounts, plus an "Uncategorized only" Toggle), which fixes
the too-long account list as well and leaves the List sitting directly under the navigation bar.
Only deep-linked category/payee/month filters still show a clearable chip above the List.

## 5. Dashboard interaction fixes

- Remove the header pencil button. Long-press any tile enters edit mode (already partially
  wired via drag; make explicit: .onLongPressGesture 0.4s + Haptics.tap + jiggle). Exit via
  a floating "Done" capsule (accent, top-right of the grid) that only exists in edit mode.
  Settings' "Edit Dashboard" hint text updates accordingly (Guide page 5 too).
- Tap vs swipe: tiles must ignore touches that move. Wrap tile activation in a drag-aware
  gesture: DragGesture(minimumDistance: 0) tracking; fire navigation only if translation
  magnitude < 10pt AND duration < 0.4s; otherwise treat as swipe. Press-down visual (scale
  0.97) only after ~80ms hold so fast swipes never flash tiles.
- Swipe feedback: the dashboard doesn't scroll by design; when a horizontal/vertical swipe
  (translation > 30pt) ends on the grid background or falls through a tile, pulse a themed
  glow from the swiped-from edge (radial accent gradient, opacity 0 -> 0.35 -> 0, ~0.5s
  theme.motion.spring; skip entirely under Reduce Motion; Haptics.tick once). Communicates
  "everything already fits on one screen."
- Superseded 2026-08-10: the radial pulse is replaced by kobold's edge glow — vertical only,
  a 140pt accent band at the true top (pull down) or bottom (pull up) of the screen whose
  opacity follows the finger live through UIKit's rubber-band resistance curve and eases back
  to 0 on release (theme.motion.spring, or .linear(0.15) under Reduce Motion). It renders
  under Reduce Motion too, since it answers a gesture rather than moving on its own, and it
  no longer fires a haptic. The pressure lives in `DashboardPullState`, read only by
  `DashboardEdgeGlow` (overlaid on the screen as a sibling of the grid), so a drag never
  re-renders the widget grid; tiles report their drags through the `dashboardPull`
  environment closure.

## Sequencing

Workflow C after AI push is green: agent 1 (fable) Guide + onboarding + CLAUDE.md rule
already present; agent 2 (fable) retirement overhaul; agent 3 (sonnet) items 3+4+5. Then
verification (auditor + fixes), push, CI to green. Guide page 7 depends on the AI round
having landed, which is guaranteed by sequencing.
