# NetPulse

A native macOS menu-bar + window app for monitoring per-app network activity,
implemented from a Claude Design mockup (see `chats/` / `README-design.md`
in the original handoff for the design conversation).

## What's real vs. approximated

- **Per-app rates & totals**: real, sampled every second from `nettop -P`.
- **Week/month/all-time rollups**: real, persisted to
  `~/Library/Application Support/NetPulse/history.json` day-by-day.
  Per-host bytes are kept the same way, one file per day under
  `~/Library/Application Support/NetPulse/hosts/`, so the detail pane's
  域名明细 and 域名总览 follow the selected range like the app totals.
- **Domain / host breakdown**: connections are real (via `lsof -i`, reverse-
  DNS resolved and cached). On a Mac running a local proxy most of a
  browser's sockets terminate at 127.0.0.1 and the real destination is known
  only to the proxy, so those rows are labelled with the process holding the
  listening port ("本机 · Shadowrocket") instead of an anonymous "localhost";
  the destinations themselves show up under the proxy's own row. Per-domain **byte counts are an estimate** —
  macOS doesn't expose per-connection throughput without the Network
  Extension entitlement (which requires Apple approval), so an app's
  measured rate is split across its currently-open remote hosts weighted by
  connection count. Good for "what's this app mostly talking to," not
  exact.
- **暂停该 App**: freezes that app's counters in the UI; it does not (and
  cannot, without NE) actually throttle its traffic.
- **导出报告**: exports the selected app's current domain breakdown as CSV
  via a save panel.

## 上传检查 (upload inspector)

Byte counts and destinations don't say *what* an app sent — the content is
TLS-encrypted. 上传检查 answers that for apps you choose: it runs an HTTP
proxy on `127.0.0.1:9696` (the next free port if taken), answers each
`CONNECT` with a certificate for that site signed by a CA generated on this
Mac, opens its own verified TLS connection to the real site (through the
system's HTTPS proxy when one is set, e.g. Shadowrocket), and relays the
bytes. On the way it reads the app's side as HTTP/1.1 requests and lists
each one with its headers and body (gzip/deflate decoded, JSON
pretty-printed). Responses are passed through unread.

Each body is scanned for git information — remote URLs, branch and
`git status` text (including the `gitStatus:` block coding agents put in
their prompts), commit hashes, `.git/` file contents, and the name and
email from your `~/.gitconfig` — plus paths under your home directory, and
the matches are highlighted.

- Each app's detail has a 检查上传内容 switch. Turning it on (after asking)
  starts the inspector, quits the app and opens it again with Chromium's
  `--proxy-server` flag plus the proxy and CA in its environment, so only
  that app goes through the inspector; the detail then lists its requests
  under 上传内容. Turning it off opens the app again plainly. Native apps
  that only follow the system proxy ignore both, and command-line tools
  can't be relaunched (the detail shows the shell lines instead). Browsers
  and Electron apps also need the CA trusted once from 上传检查. While an
  app is routed, quitting NetPulse leaves it without a network until
  NetPulse is back.
- Only apps pointed at the proxy are inspected. The pane shows the shell
  lines to paste (`HTTPS_PROXY`, `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, …)
  before launching a CLI tool from that terminal; apps that only use the
  system trust store need the CA trusted in the login keychain (a button
  does it, and undoes it).
- The CA and its key live in
  `~/Library/Application Support/NetPulse/inspector` (0700). Delete the
  folder to retire it.
- Apps that pin certificates refuse the connection; they show as 未解密.
  HTTP/2-only clients and WebSocket frames aren't decoded.
- Requests are kept in memory only (the last 500), never written to disk
  unless exported.
- TLS is SecureTransport (deprecated, TLS 1.2), the one macOS stack that
  runs over an already-open socket on both sides of a proxy; per-site
  identities pair a certificate with an in-memory key through
  Security.framework's `SecIdentityCreate`, so nothing is added to the
  keychain.

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

`.github/workflows/build.yml` builds on `macos-26` and `macos-14` GitHub
Actions runners on every push. The `macos-26` build uses the Xcode 26 SDK and
so draws the interface in Liquid Glass on macOS 26; `macos-14` keeps the
frosted-material fallback for older macOS compiling. Each uploads
`NetPulse.app` as a build artifact (`NetPulse-app` is the macOS 26 one) — useful for
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
- The app icon is drawn on a canvas by `scripts/icon/netpulse-icon.js`;
  `node scripts/icon/make-icon.mjs` renders every size into
  `Sources/NetPulse/Resources/AppIcon.iconset`, and `build-app.sh` packs that
  into `NetPulse.icns` with `iconutil`. Edit the script, not the PNGs. macOS
  caches Dock icons aggressively — `killall Dock` if a
  rebuilt bundle still shows the old one.
