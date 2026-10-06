// Conforms to Cityflo Mobile Spec rev. C — do not modify.

# Cityflo search explorer (iOS take-home)

A SwiftUI app for searching Cityflo's Mumbai routes. Type a stop, route or trip ID, open a route to see its trips, and your recent searches are still there after a relaunch.

The decisions behind it are in [DECISION.md](DECISION.md), and the steering ledger is in [decisions.jsonl](decisions.jsonl).

## Run it

Requirements: Xcode 16 or later (built and tested with Xcode 26.1), iOS 17+ simulator.

```sh
open Cityflo.xcodeproj          # then Run the "Cityflo" scheme
# or
xcodebuild -project Cityflo.xcodeproj -scheme Cityflo \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). The `.xcodeproj` is committed, so you only need XcodeGen if you change targets or settings.

Build settings: `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`, `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`. The app builds with zero warnings. It uses no third-party packages, and its tests use Swift Testing.

## How the data is served

`data/routes.json` is bundled, but the app never reads it directly. Every search goes:

```
SearchModel ─▶ CFNetworkConduit (actor, owns URLSession)
            ─▶ URLSession ─▶ SimulatedCityfloProtocol (URLProtocol)
            ─▶ SimulatedBackend (actor): rate limit → latency + jitter → random 503 → search + page
```

The fake endpoint sits underneath `URLSession`. So when a Swift task is cancelled, the cancellation reaches the `URLSessionTask` and then the endpoint, the same path a real request takes.

The endpoint contract is `GET /v1/routes/search?q=&page=`. It returns the snapshot's top-level object with `routes` replaced by one page of matches, plus `page`, `page_size`, `total_results` and `next_page`. The default page size comes from the snapshot's `client_config.results_page_size` (12).

### Live controls

Use these to swap the data or change network conditions without a rebuild:

| How | What it does |
|---|---|
| Antenna button (top right) | Change latency, jitter, rate limit (requests per window, answered with 429 and `Retry-After`), and 503 failure rate while the app runs. Presets: *Instant*, *Typical 4G* (default), *8 am peak*. |
| `CF_NETWORK=instant\|typical\|peak` | Network preset at launch. |
| `CF_DATA_PATH=/abs/path/slice.json` | Serve a different snapshot. The simulator can read Mac file paths, so swapping in a fresh slice needs no rebuild. |
| `CF_QUERY=powai` | Launch straight into a search. |

Set these in *Edit Scheme → Run → Environment Variables*, or with `SIMCTL_CHILD_CF_DATA_PATH=… xcrun simctl launch booted com.cityflo.search-explorer`.

## Where things are

| Path | What |
|---|---|
| `Cityflo/Networking/CFNetworkConduit.swift` | The networking actor: retries, 429 cool-down, errors. |
| `Cityflo/Networking/SimulatedBackend.swift` | The stand-in endpoint and its server-side matching. |
| `Cityflo/Model/` | Lenient wire decoding (`SearchResponse.swift`), the rules for which fields to trust (`RouteNormalizer.swift`), domain types (`Route.swift`). |
| `Cityflo/Features/SearchModel.swift` | Debounce (327 ms), cancellation, the stale-results rule, paging, recents. |
| `Cityflo/Persistence/RecentSearchStore.swift` | Recents file store (actor, writes carry revision numbers). |
| `CityfloTests/` | 37 tests: every bad record in the snapshot, cancellation through URLSession, 429 handling, late responses, paging across queries, recents persistence. |
