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
        if curl["status"] != "已退出":
            failures.append(f"curl's status line is {curl['status']!r}, expected '已退出'")

    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if not failures:
        print("self-test passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
