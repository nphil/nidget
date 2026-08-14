# Nidget

A beautiful, offline-first iOS companion for [Actual Budget](https://actualbudget.org) — plus
retirement planning. Native SwiftUI, zero third-party dependencies, built for daily use in a few
taps.

- **Talks to your own Actual server** (e.g. on unRAID) over Tailscale using Actual's CRDT sync
  protocol, implemented natively in Swift — no JS bridge, no cloud middleman.
- **Fully functional offline.** Your budget is a local SQLite file; every change is applied locally
  first and syncs opportunistically when the server is reachable.
- **40 hand-tuned themes** (20 light, 20 dark) that change typography, card construction, corner
  geometry, backgrounds, shadows, chrome, spacing, chart rendering, and motion — not just colors.
  Each one has its own home screen icon, and Settings can keep the icon matched to the theme you
  are using.
- **A one-screen dashboard** you compose yourself: pick widgets, drag to rearrange, resize —
  everything fits without scrolling.
- **3-tap transaction capture** with payee/category learning, from any tab, plus Siri/Shortcuts.
- **Bank imports arrive via your Actual server's bank sync** — nothing to set up in the app.
- **On-device AI (llama.cpp)**: categorization suggestions and semantic search with models you
  download from Hugging Face — nothing leaves the phone.
- **Retirement planning**: FI number, Monte Carlo projection bands, success probability,
  coast-FIRE age — driven by your real accounts and spending.
- **Security**: credentials in the Keychain, optional Face ID lock, privacy blur in the app
  switcher, support for Actual's end-to-end encryption.

## Requirements

- Xcode 26 or later, iOS 26.0+ device or simulator
- An Actual server (`actual-server` / sync server) reachable from your phone — a Tailscale tailnet
  works great

## Installation

Nidget ships as an **unsigned IPA** you sideload onto your own device (it is not an App Store app),
so you need a sideloading tool: **[Feather](https://github.com/khcrysalis/Feather) /
[AltStore](https://altstore.io) / SideStore**.

- **Option A — add the app source** (recommended; you get updates in-app): add this URL as a source
  in Feather/AltStore/SideStore, then install **Nidget** from it:

  ```
  https://raw.githubusercontent.com/nphil/nidget/main/apps.json
  ```

- **Option B — direct download:** grab `Nidget.ipa` from the
  [latest release](https://github.com/nphil/nidget/releases/latest) and sideload it.

Then jump to [First run](#first-run) to point the app at your server.

## Building from source

1. Clone the repo and fetch the prebuilt AI engine (one-time step before opening Xcode):

   ```
   bash scripts/fetch-llama-xcframework.sh
   ```

   This downloads `llama.xcframework` into the gitignored `Frameworks/` directory. The framework
   is built from a pinned llama.cpp commit by the *Build llama.xcframework* GitHub workflow and
   published as a `llama-<pin>` prerelease asset, so the repo itself stays lean — no Git LFS.
2. Open `Nidget.xcodeproj` in Xcode.
3. Select the *Nidget* target → Signing & Capabilities → pick your team (automatic signing).
4. Build & run on your device.

No packages to resolve — the app has zero third-party dependencies. New `.swift` files under
`Nidget/` are picked up automatically (the project uses filesystem-synchronized groups, so there is
no file list to maintain in the pbxproj).

### Release pipeline

`.github/workflows/ios-build.yml` runs on every push to `main`: it restores `llama.xcframework`
from the Actions cache (keyed on the pinned llama.cpp commit) and runs
`scripts/fetch-llama-xcframework.sh` — a no-op on a cache hit, otherwise a download of the
`llama-<pin>` prerelease asset published by the *Build llama.xcframework* workflow (run that one
first, and again whenever the pin bumps). Then it bumps the version, builds
unsigned (`CODE_SIGNING_ALLOWED=NO`), fails fast on real compiler diagnostics (annotated inline on
the diff), verifies the packaged `.app` actually contains an executable, publishes a GitHub Release
with `Nidget.ipa`, and patches `apps.json` — which is what Option A above reads, so a push is all it
takes for the app to offer an update on your phone. You can also run it by hand from
Actions → *Build IPA* → *Run workflow*.

Release builds ship with `VALIDATE_PRODUCT=NO` and `CADisableMinimumFrameDurationOnPhone`
(uncapped 120Hz ProMotion) — both proven in Stashy.

## First run

1. **Connect**: enter your server URL (e.g. `http://unraid.tailnet-name.ts.net:5006`) and your
   Actual server password.
2. **Pick your budget file.** If the file is end-to-end encrypted, you'll be asked for the
   encryption password too.
3. Nidget downloads the budget file and syncs. Everything after that works offline; changes queue
   and sync when the server is reachable. Bank imports set up on your Actual server (its own bank
   sync) show up automatically — there's nothing to connect inside the app.

## Security notes

- The Actual password, session token, and E2E password are stored in the iOS Keychain
  (`AfterFirstUnlockThisDeviceOnly`), never in UserDefaults or files.
- `Support/Info.plist` relaxes App Transport Security because Actual servers on a tailnet are
  commonly plain HTTP — the transport is already end-to-end encrypted by Tailscale (WireGuard). If
  you serve HTTPS (e.g. `tailscale serve`), you can remove `NSAllowsArbitraryLoads`.
- Optional Face ID lock (Settings → Security) gates the whole UI; amounts can also be blurred with
  Privacy Mode.

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the module contracts and
[docs/PROTOCOL.md](docs/PROTOCOL.md) for the wire-protocol reference (Actual sync CRDT, HLC clocks,
merkle trie, SimpleFIN). High level:

```
SwiftUI Views ── AppStore (@Observable, MainActor)
                   │            │
             DatabaseQueue   SyncEngine (actor) ── ActualAPI ── your server
                   │            │
             BudgetDatabase  CRDT outbox (offline queue)
                (SQLite)
```

Mutations are turned into CRDT messages, applied to the local SQLite budget file synchronously,
queued in a local outbox, and pushed/pulled via `/sync/sync` (protobuf) with hybrid-logical-clock
timestamps and a merkle-trie consistency check — the same scheme Actual's own clients use, so
Nidget coexists safely with the web app and other devices.

## Known limitations

- Creating a *new* budget file from the app isn't supported — point it at an existing Actual
  budget (the usual companion-app setup).
- Schedules and rules are read-only surfaces for now (upcoming widget); editing them is on the
  roadmap.
- iPhone-only, portrait-first.
