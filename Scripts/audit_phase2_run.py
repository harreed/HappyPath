#!/usr/bin/env python3
"""Independently check a deterministic runner's retained definition and evidence.

Usage: python3 Scripts/audit_phase2_run.py RUN_DIRECTORY [EXPECTED_OUTCOME]
The audit checks actual saved data, not just the acceptance executable's exit code.
"""
import datetime
import json
import math
import re
from urllib.parse import unquote, urlsplit
from pathlib import Path
import struct
import sys
import uuid


def uid(value):
    return str(uuid.UUID(value))


def variant(value):
    assert isinstance(value, dict) and len(value) == 1, f"Invalid enum: {value}"
    return next(iter(value.items()))


def instant(value, reference_epoch=False):
    if isinstance(value, (float, int)):
        assert math.isfinite(value), "Non-finite timestamp"
        return value + 978307200 if reference_epoch else value / 1000
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def matches(target, element):
    kind, config = variant(target)
    if kind == "identifier":
        return element.get("identifier") == config["_0"]
    if kind == "text":
        return config["_0"] in (element.get("label"), element.get("value"))
    if kind == "semantic":
        return all(element.get(key) == value for key, value in config.items() if value is not None)
    raise AssertionError(f"Unknown target {kind}")


def evaluate(definition, snapshot):
    kind, config = variant(definition)
    elements = snapshot["elements"]
    if kind == "textVisible":
        return any(config["_0"] in (element.get(key) or "")
                   for element in elements for key in ("label", "value"))
    found = [element for element in elements if matches(config["_0"], element)]
    if kind == "exists":
        return bool(found)
    if kind == "doesNotExist":
        return not found
    if kind == "valueEquals":
        return len(found) == 1 and found[0].get("value") == config["_1"]
    if kind == "valueContains":
        return len(found) == 1 and config["_1"] in (found[0].get("value") or "")
    raise AssertionError(f"Unknown assertion {kind}")


root = Path(sys.argv[1])
format_info = json.loads((root / "artifact-format.json").read_text())
assert format_info == {"eventFormatVersion": 2, "dateEncoding": "millisecondsSince1970"}, "Unsupported artifact format"
project = json.loads((root / "project.json").read_text())
selection = json.loads((root / "selection.json").read_text())
report = json.loads((root / "run.json").read_text())
events = [json.loads(line) for line in (root / "events.jsonl").read_text().splitlines()]
assert project["schemaVersion"] == 1, "Unsupported project format for this auditor"
assert [e["sequence"] for e in events] == list(range(1, len(events) + 1))
assert all(type(e["timestamp"]) in (int, float) for e in events), "v2 envelope timestamp must be milliseconds"
assert all(instant(a["timestamp"]) <= instant(b["timestamp"]) for a, b in zip(events, events[1:]))
if len(sys.argv) > 2:
    assert report["outcome"] == sys.argv[2], f"Unexpected outcome: {report['outcome']}"

ordered = [(category, suite, test) for category in project["categories"]
           for suite in category["suites"] for test in suite["tests"]]
kind, value = variant(selection)
if kind == "all":
    selected = ordered
elif kind in ("test", "suite", "category"):
    index = {"category": 0, "suite": 1, "test": 2}[kind]
    selected = [row for row in ordered if uid(row[index]["id"]) == uid(value["_0"])]
elif kind == "selection":
    wanted = {uid(v) for v in value["_0"]}
    selected = [row for row in ordered if uid(row[2]["id"]) in wanted]
    assert wanted == {uid(row[2]["id"]) for row in selected}
else:
    raise AssertionError(f"Unknown selection {kind}")
expected_ids = [uid(row[2]["id"]) for row in selected]
definitions = {uid(row[2]["id"]): row[2] for row in selected}
blocks = {uid(block["id"]): block for _, suite, test in ordered
          for block in suite["setup"] + test["blocks"] + suite["teardown"]}

starts, finishes, suites, states, capture_ids = [], [], [], [], set()
last_capture = None
pending_success = None
dispatches = []
used_before_captures = set()
pending_dispatch = None
successful_actions = 0
missing_after = []
assertions = []
current_test = None
test_assertions = {}
attempts = {}
for envelope in events:
    name, payload = variant(envelope["event"])
    if name == "state":
        states.append(payload["_0"])
    elif name == "phase":
        assert payload["_0"] in ("preparingSimulator", "building", "installing", "startingCompanion", "launching", "recording", "resolving", "performing", "verifying", "finalizing"), "Unknown execution phase"
    elif name == "testStarted":
        current_test = uid(payload["_0"])
        starts.append(current_test)
        test_assertions[current_test] = []
    elif name == "testFinished":
        assert current_test == uid(payload["_0"])
        finishes.append((current_test, payload["_1"]))
        current_test = None
    elif name == "suiteFinished":
        suites.append(payload["_1"])
    elif name == "capture":
        snapshot = payload["_0"]
        capture_id = uid(snapshot["captureID"]["rawValue"])
        assert capture_id not in capture_ids, "Capture reused in event stream"
        capture_ids.add(capture_id)
        path = root / "captures" / capture_id
        raw = json.loads(path.with_suffix(".json").read_text())
        assert uid(raw["snapshot"]["captureID"]["rawValue"]) == capture_id
        assert raw["screenshotName"] == capture_id + ".png"
        png = path.with_suffix(".png").read_bytes()
        assert png[:8] == b"\x89PNG\r\n\x1a\n"
        assert struct.unpack(">II", png[16:24]) == (raw["pixelWidth"], raw["pixelHeight"])
        assert raw["pixelWidth"] > 0 and raw["pixelHeight"] > 0
        frame = raw["screenFrame"]
        assert all(math.isfinite(frame[key]) for key in ("x", "y", "width", "height"))
        assert frame["width"] > 0 and frame["height"] > 0
        assert abs(instant(snapshot["capturedAt"]) - instant(raw["snapshot"]["capturedAt"], True)) < 1.01
        # The driver filters offscreen nodes. Every emitted node must still come
        # from the retained raw snapshot, rather than invented semantic evidence.
        raw_nodes = [json.dumps(e, sort_keys=True) for e in raw["snapshot"]["elements"]]
        assert all(json.dumps(e, sort_keys=True) in raw_nodes for e in snapshot["elements"])
        last_capture = (capture_id, envelope["sequence"])
        if pending_success is not None:
            assert last_capture[0] != pending_success[1]
            pending_success = None
    elif name == "actionStarted":
        assert pending_success is None, "Next mutation dispatched without explicit previous block completion"
        block_id = uid(payload["_0"])
        assert blocks[block_id]["enabled"]
        assert last_capture is not None, "Mutation lacks before-capture"
        if missing_after:
            assert all(item["outcome"] != "cancelled" for item in missing_after), "Mutation dispatched after cancellation"
            assert block_id not in {item["blockID"] for item in missing_after}, "Uncertain block mutation retried"
            assert last_capture[1] > missing_after[-1]["finishedSequence"], "Later block lacks fresh evidence after uncertain block finished"
        assert last_capture[0] not in used_before_captures, "Mutation reused an earlier before-capture"
        used_before_captures.add(last_capture[0])
        pending_dispatch = (block_id, payload["_1"])
        dispatches.append((block_id, last_capture[0], envelope["sequence"]))
    elif name == "action":
        block_id = uid(payload["_0"])
        assert blocks[block_id]["enabled"]
        assert last_capture is not None, "Mutation lacks before-capture"
        assert pending_success is None, "Mutation lacks previous after-capture"
        assert pending_dispatch == (block_id, payload["_1"]), "Success lacks matching action attempt"
        pending_dispatch = None
        pending_success = (block_id, last_capture[0])
        successful_actions += 1
    elif name == "blockStarted":
        attempts[uid(payload["_0"])] = 0
    elif name == "attempt":
        block_id = uid(payload["_0"])
        assert payload["_1"] == attempts[block_id] + 1
        attempts[block_id] = payload["_1"]
        assert attempts[block_id] <= blocks[block_id]["retryPolicy"]["maximumAttempts"]
    elif name == "blockFinished":
        assert uid(payload["_0"]) in blocks
        assert payload["_1"] in ("passed", "failed", "blocked", "needsReview", "cancelled")
        assert math.isfinite(payload["duration"]) and payload["duration"] >= 0
        if pending_success is not None:
            assert uid(payload["_0"]) == pending_success[0], "Missing after-capture attributed to another block"
            assert payload["_1"] in ("needsReview", "cancelled"), "Successful action lacks after-capture without explicit uncertainty"
            assert payload.get("reason"), "Missing after-capture requires a retained reason"
            missing_after.append({"blockID": pending_success[0], "beforeCaptureID": pending_success[1],
                                  "outcome": payload["_1"], "reason": payload["reason"], "finishedSequence": envelope["sequence"]})
            pending_success = None
    elif name == "assertion":
        assert last_capture is not None, "Assertion lacks captured evidence"
        assert evaluate(payload["_0"], snapshot) == payload["_1"], "Assertion result contradicts semantic evidence"
        assertions.append(payload)
        if current_test is not None:
            test_assertions[current_test].append(payload)
    elif name == "blockSkipped":
        assert not blocks[uid(payload["_0"])]["enabled"]
    elif name == "finished":
        assert payload["_0"] == report
    elif name not in ("suiteStarted", "blockStarted", "diagnostic"):
        raise AssertionError(f"Unknown event {name}; update auditor for the explicit schema")

assert pending_success is None, "Last successful mutation has no retained after-capture"
assert starts == expected_ids[:len(starts)], "Tests ran out of project selection order"
assert [test_id for test_id, _ in finishes] == starts
assert [(uid(r["testID"]), r["outcome"]) for r in report["tests"]] == finishes
if report["outcome"] == "passed":
    assert not missing_after, "Passed run has unverified post-action state"
    assert starts == expected_ids, "Passed run omitted selected tests"
    assert all(outcome == "passed" for _, outcome in finishes)
    for test_id, _ in finishes:
        required = definitions[test_id]["assertions"]
        recorded = test_assertions[test_id]
        if required:
            assert len(recorded) >= len(required)
            assert [a["_0"] for a in recorded[-len(required):]] == required
            assert all(a["_1"] is True for a in recorded[-len(required):])
priority = ["passed", "needsReview", "blocked", "failed", "cancelled"]
worst_recorded = max(["passed"] + suites + [o for _, o in finishes], key=priority.index)
assert priority.index(report["outcome"]) >= priority.index(worst_recorded)
assert states[0] == "preparing" and states[-2:] == ["stopping", "finished"]
assert variant(events[-1]["event"])[0] == "finished"
# Validate local report links against the archive itself; never resolve via the
# source workspace. This also rejects escaping symlinks in a copied export.
report_text = (root / "report.md").read_text()
links = re.findall(r"(?<!!)\[[^\n]*?\]\(([^)]+)\)", report_text)
for link in links:
    parsed = urlsplit(link)
    assert not parsed.scheme and not parsed.netloc, f"Non-local evidence link: {link}"
    relative = Path(unquote(parsed.path))
    assert not relative.is_absolute(), f"Absolute evidence link: {link}"
    resolved = (root / relative).resolve()
    assert resolved.is_relative_to(root.resolve()), f"Escaping evidence link: {link}"
    assert resolved.is_file(), f"Missing evidence link: {link}"
anchor_path = root / "recording-anchor.json"
anchor = None
if (root / "video.mp4").exists():
    anchor = json.loads(anchor_path.read_text())
    spawned = instant(anchor["processStartedAt"])
    observed = instant(anchor["markerObservedAt"])
    assert spawned <= observed, "Recording anchor has negative observation uncertainty"
    assert spawned <= instant(events[-1]["timestamp"]), "Recording began after terminal event"
    assert observed <= instant(events[-1]["timestamp"]), "Recording marker observed after terminal event"
    assert (root / "video.mp4").stat().st_size > 0, "Empty video"
audit = {"verified": True, "artifactVersion": 2, "localEvidenceLinks": len(links),
         "recordingAnchor": anchor, "actionsMissingAfterEvidence": missing_after, "outcome": report["outcome"], "selectedTests": len(expected_ids),
         "finishedTests": len(finishes), "orderedEvents": len(events), "captures": len(capture_ids),
         "successfulMutations": successful_actions, "dispatchRecords": len(dispatches),
         "scope": "Saved selection/order, terminal results, required final assertions independently evaluated from captured semantic nodes, capture identity/dimensions and mutation before/after evidence. Video playback and live OS cleanup checked separately."}
(root / "independent-audit-v2.json").write_text(json.dumps(audit, indent=2) + "\n")
print(json.dumps(audit))
