#!/usr/bin/env python3
"""Verify scenario-specific negative acceptance evidence after the general audit.

Usage: python3 Scripts/audit_phase1_negative.py RUN_DIRECTORY
Live process cleanup and recorded video require separate OS/media checks.
"""
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
project = json.loads((root / "project.json").read_text())
report = json.loads((root / "run.json").read_text())
events = [json.loads(line)["event"] for line in (root / "events.jsonl").read_text().splitlines()]
scenario = project["name"].removeprefix("Negative acceptance: ")
expected = {"RetryExhaustion": "failed", "WaitTimeout": "failed", "Breakpoint": "needsReview",
            "InvalidSimulator": "blocked", "Cancellation": "cancelled"}
assert scenario in expected, scenario
assert report["outcome"] == expected[scenario], report
def values(name):
    return [event[name] for event in events if name in event]

actions = values("action")
dispatches = values("actionStarted")
attempts = values("attempt")
assert values("finished") == [{"_0": report}]
states = [v["_0"] for v in values("state")]
assert states[0] == "preparing" and states[-2:] == ["stopping", "finished"]
if scenario == "RetryExhaustion":
    assert [a["_1"] for a in attempts] == [1, 2, 3], attempts
    assert len(values("capture")) == 3
    assert not dispatches and not actions
    assert len([d for d in values("diagnostic") if "Retry before dispatch" in d["_0"]]) == 2
    assert values("blockFinished")[-1]["_1"] == "failed"
elif scenario == "WaitTimeout":
    assert len(attempts) == 1 and not dispatches and not actions
    assertions = values("assertion")
    assert assertions and all(a["_1"] is False for a in assertions)
    assert values("blockFinished")[-1]["_1"] == "failed"
elif scenario == "Breakpoint":
    assert not attempts and not dispatches and not actions
    assert any("Breakpoint requires review" in d["_0"] for d in values("diagnostic"))
elif scenario == "InvalidSimulator":
    assert states == ["preparing", "stopping", "finished"]
    assert not report["tests"] and not values("testStarted") and not dispatches
    assert values("diagnostic"), "Missing preparation failure diagnostic"
elif scenario == "Cancellation":
    assert "running" in states and actions, "Cancellation must exercise an active live session"
    assert report["tests"] and report["tests"][-1]["outcome"] == "cancelled"
    first_action = next(i for i, event in enumerate(events) if "action" in event)
    assert any("capture" in event for event in events[first_action + 1:]), "Successful mutation needs after-evidence"

result = {"verified": True, "scenario": scenario, "outcome": report["outcome"],
          "attempts": len(attempts), "successfulActions": len(actions)}
(root / "negative-audit.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result))
