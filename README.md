# NetPulse

A native macOS menu-bar + window app for monitoring per-app network activity,
implemented from a Claude Design mockup (see `chats/` / `README-design.md`
in the original handoff for the design conversation).

## What's real vs. approximated

- **Per-app rates & totals**: real, sampled every second from `nettop -P`.
- **Week/month/all-time rollups**: real, persisted to
  `~/Library/Application Support/NetPulse/history.json` day-by-day.
- **Domain / host breakdown**: which hosts an app is connected to is real;
  how many bytes went to each is an **estimate**. See
  [How per-host numbers are estimated](#how-per-host-numbers-are-estimated).
- **暂停该 App**: freezes that app's counters in the UI; it does not (and
  cannot, without NE) actually throttle its traffic.
- **导出报告**: exports the selected app's current domain breakdown as CSV
  via a save panel.

## How per-host numbers are estimated

macOS only reports network bytes **per process**. Per-connection or per-host
byte counts need Apple's Network Extension entitlement, which requires
Apple's approval, and NetPulse doesn't have it. So the host table is built
from two separate sources and a split:

1. **Bytes per app** (`Monitoring/NettopSampler.swift`): `nettop -P` streams
   each process's cumulative bytes in/out once a second. The engine turns
   that into a per-second delta and sums the processes that belong to the
   same app. These rates and the persisted totals are real.
2. **Sockets per app** (`Monitoring/ConnectionSampler.swift`): `lsof -i`
   runs every 3 seconds and counts each process's open TCP and UDP sockets
   by remote IP. Sockets to `127.0.0.1`/`::1` are counted by port instead,
   and labelled with the process listening on that port. Remote IPs are
   reverse-DNS resolved in the background (cached for 10 minutes) and shown
   as the raw IP when there's no PTR record. This step sees no byte counts
   at all.
3. **The split** (`NetworkMonitorEngine.buildUsage`): every second, each
   host gets `(sockets to that host ÷ all of the app's sockets)` of the
   app's measured rate, applied the same way to bytes in and bytes out.

What that means in practice:

- A host with 3 of an app's 4 sockets is shown with 75% of its traffic,
  even if those 3 are idle keep-alives and the 4th is a large download.
  Treat the numbers as "what is this app mostly talking to", not as a
  measurement.
- With a local proxy (Shadowrocket, Clash, Surge…), a browser's sockets
  mostly go to `127.0.0.1`, so its traffic lands on a row like
  "本机 · Shadowrocket". The real destinations only appear under the
  proxy's own app row, split by the proxy's upstream sockets.
- Per-host totals are kept in memory since launch and aren't saved. A row
  is dropped once the app has no sockets to that host, and an IP shown
  before its hostname resolves starts again from zero under the hostname.
- The socket list refreshes every 3 seconds and the rate every second, so
  short-lived connections between two `lsof` runs are missed and their
  bytes are attributed to whatever sockets were seen.

The app also has to run **outside the App Sandbox**: `nettop` and `lsof`
inspect sockets that belong to other processes, which the sandbox blocks.
`Sources/NetPulse/Resources/NetPulse.entitlements` turns the sandbox off,
which rules out the Mac App Store (see [Building](#building)).

## Building

Requires Xcode 15+ / macOS 13+ SDK.

```sh
swift build -c release
scripts/build-app.sh release   # produces dist/NetPulse.app, ad-hoc signed
```

Or open `Package.swift` directly in Xcode and run the `NetPulse` scheme.

The app needs to run **outside the App Sandbox** — it shells out to
`nettop`/`lsof` to read other processes' network activity, which the
sandbox blocks. `Sources/NetPulse/Resources/NetPulse.entitlements` already
disables it; this means Mac App Store distribution isn't an option as-is
(same constraint tools like Stats/iStat Menus have), but Developer ID /
local distribution works fine.

## CI

`.github/workflows/build.yml` builds on a `macos-14` GitHub Actions runner
on every push and uploads `NetPulse.app` as a build artifact — useful for
catching compile errors even without a local Mac.

The bundle is zipped with `ditto` before upload so it survives the trip
with its permissions and ad-hoc signature intact. GitHub wraps artifacts in
a zip of their own, so a downloaded `NetPulse-app.zip` unpacks to
`NetPulse.zip`, which in turn unpacks to a double-clickable `NetPulse.app`:

```sh
cd ~/Downloads && unzip NetPulse-app.zip && unzip NetPulse.zip
xattr -dr com.apple.quarantine NetPulse.app   # ad-hoc signed, not notarized
open NetPulse.app
```

## Known rough edges / things to check on a real Mac

- `NettopSampler`'s text parser was the least-verified part of this project
  (see the comment at the top of `Monitoring/NettopSampler.swift`) — it was
  written against documented `nettop` behavior, not tested against live
  output. The sidebar status distinguishes the failure modes: nettop exiting
  (its own stderr is quoted), producing nothing at all, or producing rows
  none of which parse (the first lines are quoted, so the real format can be
  read straight off the UI). Compare against `nettop -P -x -l 2 -J
  bytes_in,bytes_out` in Terminal and adjust `parse(line:)` to match.
- `nettop` may prompt for permission the first time it runs, or require the
  app to be run as an admin user, depending on macOS version.
- The app icon is drawn by `scripts/make-icon.py` into
  `Sources/NetPulse/Resources/AppIcon.png`; `build-app.sh` turns that into
  `NetPulse.icns` with `sips`/`iconutil` at package time. Edit the script,
  not the PNG. macOS caches Dock icons aggressively — `killall Dock` if a
  rebuilt bundle still shows the old one.
