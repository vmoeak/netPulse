#!/usr/bin/env python3
"""Checks the report NetPulse prints in self-test mode.

CI launches the packaged app with NETPULSE_SELFTEST_SECONDS set, runs a
throttled `curl` download while it samples, lets curl exit, and then reads
what the app reported. That exercises the real nettop/lsof pipeline on a
real Mac: the download has to be counted, and once curl is gone its rate
and hosts have to be gone too while its total stays.

Usage: scripts/check-selftest.py report.json
"""
import json
import sys


def main(path: str) -> int:
    with open(path) as f:
        report = json.load(f)
    print(json.dumps(report, indent=2, ensure_ascii=False))

    failures = []
    if report["status"] != "ok":
        failures.append(f"monitoring status is {report['status']!r}, expected 'ok'")

    curl = next((a for a in report["apps"] if a["id"] == "proc.curl"), None)
    if curl is None:
        failures.append("curl's download never showed up as an app")
    else:
        if curl["todayDownKB"] < 256:
            failures.append(f"curl downloaded only {curl['todayDownKB']:.0f} KB by NetPulse's count")
        if curl["rateDownKBps"] != 0 or curl["rateUpKBps"] != 0:
            failures.append("curl has exited but still shows a live rate")
        if curl["hosts"]:
            failures.append(f"curl has exited but still lists hosts: {curl['hosts']}")
        if curl["status"] != "未运行":
            failures.append(f"curl's status line is {curl['status']!r}, expected '未运行'")

    ui = report.get("ui")
    if ui is not None:
        failures += check_ui(ui)

    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if not failures:
        print("self-test passed")
    return 1 if failures else 0


def check_ui(ui: dict) -> list:
    """The UI self-test's findings (NETPULSE_SELFTEST_SNAPSHOTS). (d) and (e)
    depend on the machine's history and traffic, so they are printed for a
    person to read against the snapshots rather than asserted."""
    failures = []
    b = ui.get("b", {})
    if "error" in b:
        failures.append(f"(b) {b['error']}")
    elif b.get("windowsAfter", 0) > max(1, b.get("windowsBefore", 0)):
        failures.append(f"(b) 打开主窗口 twice left {b['windowsAfter']} main windows "
                        f"(started with {b['windowsBefore']})")
    c = ui.get("c", {})
    if not c.get("curlRowsDuring"):
        failures.append("(c) curl never showed up in 活跃连接 while it was downloading")
    if c.get("curlRowsAfter"):
        failures.append(f"(c) curl still listed in 活跃连接 after exiting: {c['curlRowsAfter']}")
    a = ui.get("a", {})
    # A lone "▲ 12 KB/s" line is about 40pt wide; two lines plus the bars
    # are wider, but the real check is looking at a-chip.png.
    if a.get("chipHeight", 0) < 14:
        failures.append(f"(a) the menu bar chip image is only {a.get('chipHeight')}pt tall")
    print("(d) not-running apps under 累计流量:", ui.get("d", {}).get("notRunning"))
    print("(e) host order:", json.dumps(ui.get("e"), ensure_ascii=False))
    print("snapshots:", ui.get("snapshots"))
    return failures


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
