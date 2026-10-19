#!/usr/bin/env python3
"""Audit retained bridge evidence independently of the experiment's summary."""
import json
import math
from pathlib import Path
import struct
import sys

root = Path(sys.argv[1])
events = [json.loads(line) for line in (root / "events.jsonl").read_text().splitlines()]
summary = json.loads((root / "summary.json").read_text())
assert [e["sequence"] for e in events] == list(range(1, len(events) + 1))
assert all(a["timestamp"] <= b["timestamp"] for a, b in zip(events, events[1:]))
captures = {}
for event in events:
    if event["kind"] != "capture":
        continue
    capture_id = event["captureID"]
    assert capture_id not in captures, "Capture identity reused"
    path = root / "screenshots" / event["screenshot"]
    assert path.parent == root / "screenshots"
    capture = json.loads(path.with_suffix(".json").read_text())
    assert capture["snapshot"]["captureID"]["rawValue"].lower() == capture_id
    assert capture["screenshotName"] == capture_id + ".png"
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    assert struct.unpack(">II", data[16:24]) == (capture["pixelWidth"], capture["pixelHeight"])
    captures[capture_id] = capture

passed = [e for e in events if e["kind"] == "trialPassed"]
assert [e["trial"] for e in passed] == list(range(1, summary["requestedRuns"] + 1))
assert len(passed) == summary["passedRuns"]
assert len(captures) == summary["screenshots"]
required_states = {"launch", "focused", "typed", "alert", "ocr-source", "complete"}
for trial in range(1, summary["requestedRuns"] + 1):
    subset = [e for e in events if e.get("trial") == trial]
    assert required_states <= {e.get("state") for e in subset}
    assert sum(e["kind"] == "staleCaptureRejected" for e in subset) == 1
    final_events = [e for e in subset if e.get("state") == "complete"]
    assert len(final_events) == 1
    elements = captures[final_events[0]["captureID"]]["snapshot"]["elements"]
    for identifier, expected in [("onboarding.complete", "Setup complete"),
                                 ("onboarding.finalName", f"Welcome, Ada {trial}")]:
        matches = [e for e in elements if e.get("identifier") == identifier]
        assert len(matches) == 1 and matches[0]["label"] == expected
    decisions = [e for e in subset if e["kind"] == "pointDecision"]
    assert len(decisions) == 1
    decision = decisions[0]
    capture = captures[decision["captureID"]]
    frame = capture["screenFrame"]
    x, y = decision["pixelPoint"]
    assert 0 <= x < capture["pixelWidth"] and 0 <= y < capture["pixelHeight"]
    expected = [frame["x"] + x * frame["width"] / capture["pixelWidth"],
                frame["y"] + y * frame["height"] / capture["pixelHeight"]]
    assert all(math.isfinite(v) for v in expected + decision["screenPoint"])
    assert all(math.isclose(a, b, abs_tol=1e-6) for a, b in zip(expected, decision["screenPoint"]))
    recognition = [e for e in subset if e["kind"] == "ocr" and e["captureID"] == decision["captureID"]]
    assert recognition and recognition[-1]["confidence"] >= .8

failures = [e for e in events if e["kind"] in ("operationFailure", "experimentFailed")]
assert len(failures) == len(passed)
assert all(e["kind"] == "operationFailure" and e["operation"] == "pointTap"
           and e["error"] == "staleCapture" for e in failures)
report = {"passed": True, "verifiedTrials": len(passed), "verifiedCaptures": len(captures),
          "orderedEvents": len(events), "expectedStaleRejections": len(failures),
          "scope": "Retained capture IDs, PNG dimensions, final semantic names, OCR confidence and point transforms. Live actuation and video playback require separate evidence."}
(root / "independent-audit.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report))
