# NetPulse

A native macOS menu-bar + window app for monitoring per-app network activity,
implemented from a Claude Design mockup (see `chats/` / `README-design.md`
in the original handoff for the design conversation).

## What's real vs. approximated

- **Per-app rates & totals**: real, sampled every second from `nettop -P`.
- **Week/month/all-time rollups**: real, persisted to
  `~/Library/Application Support/NetPulse/history.json` day-by-day.
- **Domain / host breakdown**: connections are real (via `lsof -i`, reverse-
  DNS resolved and cached). Per-domain **byte counts are an estimate** —
  macOS doesn't expose per-connection throughput without the Network
  Extension entitlement (which requires Apple approval), so an app's
  measured rate is split across its currently-open remote hosts weighted by
  connection count. Good for "what's this app mostly talking to," not
  exact.
- **暂停该 App**: freezes that app's counters in the UI; it does not (and
  cannot, without NE) actually throttle its traffic.
- **导出报告**: exports the selected app's current domain breakdown as CSV
  via a save panel.

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

## Known rough edges / things to check on a real Mac

- `NettopSampler`'s text parser is the least-verified part of this project
  (see the comment at the top of `Monitoring/NettopSampler.swift`) — it was
  written against documented `nettop` behavior, not tested against live
  output. If the sidebar shows "nettop 未返回数据…", check `nettop -P -x -l 2
  -J bytes_in,bytes_out` in Terminal and adjust `parse(line:)` to match.
- `nettop` may prompt for permission the first time it runs, or require the
  app to be run as an admin user, depending on macOS version.
- App icon / Dock icon aren't set (no `.icns` provided).
