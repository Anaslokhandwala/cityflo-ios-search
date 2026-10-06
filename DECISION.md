# DECISION.md

The snapshot has 20 routes and 67 trips. I ran all of it: 8 records have something wrong, and none is dropped. The shared rule behind §4 is **show every record we can key, never invent a value, hide only what's contradicted, and say why on screen.**

## 1. Scope cut

**Rule.** Build correctly: the concurrency path (debounce → cancel → key check → 429 cool-down), the trust rules for every field, and recents that persist. Cut:
- a real network endpoint (replaced by an in-process server under `URLSession`);
- an offline cache of the last results;
- UI tests;
- accessibility beyond system defaults;
- any notion of "now" (no "departs in 5 min").

Runner-up, rejected: pointing the app at GitHub's search API for real 429s. That gives real latency, but it would need a second decoder for data that isn't Cityflo-shaped, and the rate limit can't be changed on demand. The in-process server can be, from inside the app, which is exactly what the debrief does.

**Breaks on.** It never sees a real socket: no TLS, no DNS, no half-open connections. Its 429s are well-behaved (`Retry-After` always set, as integer seconds).

**Cost.** If a real gateway sends `Retry-After` as an HTTP date, we fall back to 1 s/2 s backoff and may spend extra budget at peak. The commuter sees a "too many searches" error sooner than they should.

**Would change my mind.** The real search gateway's 429 behaviour; that's the first thing I'd ask the backend team for.

## 2. Cancellation model (rapid typing)

**Rule.** One search task at a time. Each keystroke cancels the previous task and starts a fresh 327 ms debounce, so typing `mumb` one key at a time sends **one** request (test: `rapidTypingSendsOneRequest`). Cancellation is only there to save requests. What guarantees correctness is a check that a response's query key (folded for case and diacritics) still equals what's typed, so a late response can't replace a fresh one even if cancellation never arrives (test: `lateResponseNeverStompsFreshOne`, where the service ignores cancellation). Next-page loads carry a generation number and are dropped if the results they'd append to have been replaced.

**Breaks on.** Cancellation doesn't refund rate-limit budget. A request already accepted by the gateway counts even if we hang up, so cancelling saves server work but not 429s. Only the debounce saves budget. Under the *8 am peak* preset (4 requests/10 s), someone who types, pauses past 327 ms, and retypes 5 times in 10 s gets a 429 on the 5th.

**Cost.** That commuter sees "too many searches, try again in N s" with their previous results still on screen (§3). A tighter limit would make this common at 8 am.

**Would change my mind.** If logs showed people pausing mid-word more often than 327 ms, I'd move matching on-device (fetch the network once, filter locally). That stops typing from costing requests at all, at the price of results being as stale as the cached copy. That's the runner-up I'd build next.

## 3. Stale vs. blank

**Rule.** Results already on screen stay there until replaced. While a new query loads, or after it fails, they're dimmed and the header says **"Updating… showing results for 'powai'"** or **"Still showing results for 'powai'"** plus a Retry button. The list only goes blank when the search field is cleared, or when there's nothing to show yet (first search: spinner). Tapping a stale result opens that route and saves the query that produced it (`powai`) as a recent search, not what's currently typed.

**Breaks on.** Typing `powai` → `kurla` under peak latency (up to 2.5 s): for a moment the screen shows three Powai routes while the field says "kurla". Someone glancing at their phone can tap *Mulund → Powai* thinking it's a Kurla bus.

**Cost.** A commuter opens the wrong route's detail. The detail screen is accurate for the route it shows, so they lose seconds rather than end up at the wrong stop. Blanking instead costs every commuter on a slow network a blank screen at the moment they most need something. I take a rare, labelled mis-tap over that.

**Would change my mind.** Analytics showing taps on dimmed rows are frequent (say more than 5% of stale displays). Then I'd make dimmed rows non-tappable and keep showing them.

## 4. Which fields to trust, and what the UI shows

| Record | What's wrong | What the UI does |
|---|---|---|
| `R-110` ×2 | Same id, different routes (Nerul→Mulund, Chembur→Ghatkopar) | Both shown, each with its own identity (id + position), both flagged |
| `R-120` | `name: ""` | "Unnamed route" in grey, flagged. Still findable by id |
| `R-119` | No `corridor` | Flagged on the detail screen only |
| `T-1022` ×2 (R-107) | Same trip id, 17:15 and 17:18 | Both shown, both flagged "listed twice" |
| `T-1035` (R-111) | Arrival 09:05 before departure 09:30 | Departure kept. Arrival and duration hidden, flagged |
| `T-1028` (R-109) | 200-min trip (every other trip is 36–72) | Shown, with an "allow extra time" warning |
| `T-1045` (R-114) | 41 booked on a 34-seat bus | Shown as **Full**, never "−7 seats" |
| `T-1018` (R-105) | `on_time_pct: "97.0"` (a string) | Value used, no warning (the value is plausible, only the type is wrong) |

Visible warnings: 5 of 67 trips (7%) and 4 of 20 routes.

**Breaks on: `T-1035`.** I keep departure and drop arrival, but the error could be in departure: 08:30 → 09:05 would be a plausible 35-minute trip. If so, a commuter turns up at 09:30 for a bus that left an hour earlier. I'm keeping the rule because departure is the field a booking is made against. The flag tells the rider the record is wrong, and guessing which half is wrong would mean inventing data. **`T-1022`** is the same problem: whoever trusts the 17:15 listing waits 3 minutes, and whoever trusts the 17:18 one may be walking up as the bus leaves.

**Fields I treat as labels, not facts:**
- **`corridor`.** It cycles central → western → harbour → trans-thane in perfect order by route id (Kurla→BKC is "harbour", Andheri E→Airoli is "central"). So it's shown only on the detail screen as "Corridor (as labelled)", and search matches it only after name and id matches.
- **`status`.** 24 of 67 trips are "delayed" in a snapshot pulled at 06:00 for trips up to 20:45, and 11 of those have ≥90% on-time history (e.g. `T-1004`, `T-1053`). It's shown as a badge under a "timetable as of 24 Jun 06:00 IST" note. **This is the call I'm least sure of.**
- **`seats_booked`.** Only true as of the snapshot. Seats are shown as "X of Y left" with the same note, and red at ≤3 left.

All times are shown in IST regardless of the device's time zone. Nothing is relative to the current time, because the snapshot is 3+ months old.

**Cost.** For `status`: a rider skips an 18:30 trip marked "Delayed" that runs on time and waits for the next one. For seats: ops gets complaints about seats that showed as available.

**Would change my mind.** If ops confirmed `status` is a live feed and the snapshot time just lags, I'd make it prominent. If confirmed predictive, I'd remove the badge and show only the on-time percentage. If ops said later duplicate rows supersede earlier ones, I'd show only the last `T-1022`.

## 5. Pagination

**Rule.** Use the endpoint's page size (12) and load the next page automatically when the last row appears. One page load at a time, dropped if the query changes. A failed page keeps what's loaded and shows a "tap to retry" row.

**Breaks on.** Duplicate-id flagging (`R-110`) only covers results that are loaded. A query that matches only one of the two `R-110` routes (`nerul`) shows it unflagged.

**Cost.** Small with 20 routes. With a real network, duplicate ids would need flagging on the server.

**Would change my mind.** If result sets were large (hundreds of routes), I'd cap at about 3 pages with a "refine your search" prompt: nobody scrolls 40 bus routes at a stop.

## 6. Recent searches, and `log_search_queries_verbatim`

**Rule.**
- Up to 8, newest first, duplicates ignoring case and spacing removed, tap to re-run, swipe to delete, clear all.
- Saved only when the user presses return or opens a result, never per keystroke: `p`, `po`, `pow` are not recents.
- Stored as a JSON file in Application Support through an actor. Each save carries a revision number assigned on the main actor, so a slow save can't overwrite a newer one. Saving recents never touches the search path, so it can't race a search in flight.
- Runner-up, rejected: `UserDefaults`. It works, but it has no ordering guarantee between writes, and it invites other code to read the key.
- The endpoint asks for `log_search_queries_verbatim: true`. **I don't follow it.** Searches stay on the device and are never sent anywhere. A commuter's searches show where they live and work.

**Breaks on.** The search-relevance team gets no data at all from this app.

**Cost.** That team can't see what commuters fail to find (e.g. `mumb`, which matches nothing because city isn't searchable).

**Would change my mind.** A PM and legal sign-off on a consented, aggregated, server-side search log: counts of zero-result queries, not raw strings tied to devices.

## Questions I'd have asked the PM and designer

1. Is `status` live, or a prediction? (It decides §4's least-sure call.)
2. Which `T-1022` row wins, and do duplicate route ids exist in production?
3. Is `corridor` a geography field or an internal grouping?
4. Is verbatim query logging covered by our privacy policy and consent flow?
5. What do the gateway's real 429s look like (`Retry-After` format, per-user or per-IP limits)?
