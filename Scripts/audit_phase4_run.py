#!/usr/bin/env python3
"""Independently check a deterministic runner's retained definition and evidence.

Usage: python3 Scripts/audit_phase4_run.py RUN_DIRECTORY [EXPECTED_OUTCOME]
The audit checks actual saved data, not just the acceptance executable's exit code.
For complete native schema-2 runs only; crash-prefix recovery and legacy imports
require separate provenance audits. Historical Phase 3 auditing is unchanged.
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
import hashlib
from audit_perception_evidence import audit_perception, audit_capture_provenance
from audit_goal_evidence import audit_goal_assessment, audit_failure_summary
from audit_candidate_evidence import audit_candidate_decision


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
audit_output = root / "independent-audit-phase4.json"
audit_output.unlink(missing_ok=True)
format_info = json.loads((root / "artifact-format.json").read_text())
assert format_info == {"eventFormatVersion": 2, "dateEncoding": "millisecondsSince1970"}, "Unsupported artifact format"
project = json.loads((root / "project.json").read_text())
selection = json.loads((root / "selection.json").read_text())
report = json.loads((root / "run.json").read_text())
events = [json.loads(line) for line in (root / "events.jsonl").read_text().splitlines()]
assert project["schemaVersion"] == 2, "Phase 4 complete-run audit requires project schema 2"
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
raw_captures = {}
snapshots_by_id = {}
perceptions = {}
recoveries = []
provenance_ids = set()
recovery_dispatch_count = 0
uncertain_recovery_blocks = set()
pending_recovery_dispatch = None
goal_assessments = {}
goal_records = {}
failure_summaries = {}
test_started_at = None
last_action_at = None
candidate_decisions = {}
candidate_decision_tests = {}
candidate_decision_captures = {}
paired_candidate_decisions = set()
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
        recovery_dispatch_count = 0
        test_started_at = envelope["timestamp"]
        last_action_at = None
    elif name == "testFinished":
        assert current_test == uid(payload["_0"])
        if definitions[current_test].get("goal", "").strip():
            assert current_test in goal_assessments, "Nonempty final goal was not assessed"
        if current_test in goal_assessments:
            assessment = goal_assessments[current_test]
            if assessment["outcome"] == "needsReview":
                assert payload["_1"] != "passed", "Uncertain goal became passed"
            if assessment["outcome"] == "failed":
                assert payload["_1"] in ("failed", "cancelled"), "Failed goal was overridden"
            if payload["_1"] != "passed":
                assert current_test in failure_summaries, "Goal failure/review lacks explanatory summary"
        if current_test in failure_summaries:
            audit_failure_summary(failure_summaries[current_test], test_id=current_test,
                                  outcome=payload["_1"],
                                  assessment_request_id=goal_assessments.get(current_test, {}).get("requestID"))
        if payload["_1"] == "passed":
            required = definitions[current_test]["assertions"]
            recorded = test_assertions[current_test]
            if required:
                assert len(recorded) >= len(required), "Passed test omitted required assertions"
                assert [a["_0"] for a in recorded[-len(required):]] == required, "Passed test omitted required assertions"
                assert all(a["_1"] is True for a in recorded[-len(required):]), "Passed test contradicts required deterministic assertions"
        finishes.append((current_test, payload["_1"]))
        current_test = None
    elif name == "suiteFinished":
        suites.append(payload["_1"])
    elif name == "goalAssessment":
        assert current_test is not None and current_test not in goal_assessments, "Duplicate or unscoped goal assessment"
        record = payload["_0"]
        definition = definitions[current_test]
        policy = definition.get("goalAssessmentPolicy") or {}
        assert record["minimumConfidence"] == policy.get("minimumConfidence", 0.9), "Goal confidence policy changed"
        expected_mode = {"semantic": "semanticText", "ocr": "ocrText", "image": "imageUnavailable"}[policy.get("requirement", "semantic")]
        final_snapshot = snapshots_by_id[last_capture[0]] if last_capture else None
        if record.get("request") is not None:
            assert record["request"]["capturedAt"] >= test_started_at, "Goal borrowed an earlier test capture"
        goal_assessments[current_test] = audit_goal_assessment(record, test_id=current_test,
            goal=definition["goal"], snapshot=final_snapshot, event_timestamp=envelope["timestamp"],
            last_mutation_timestamp=last_action_at, expected_mode=expected_mode,
            perception=perceptions.get(last_capture[0]) if last_capture else None,
            screenshot=(root / "captures" / (last_capture[0] + ".png")).read_bytes() if last_capture else None)
        if record.get("request") is not None:
            request = record["request"]
            assert request["deadline"] - request["requestedAt"] <= policy.get("timeoutSeconds", 45) * 1000 + 0.01, "Goal exceeded configured assessment time budget"
        goal_records[current_test] = record
    elif name == "failureSummary":
        assert current_test is not None and current_test not in failure_summaries, "Duplicate or unscoped failure summary"
        record = payload["_0"]
        if current_test in goal_records:
            assert record["source"]["reason"] == goal_records[current_test]["reason"], "Summary changed assessment reason"
        failure_summaries[current_test] = record
    elif name == "candidateDecision":
        assert current_test is not None and last_capture is not None, "Unscoped candidate decision"
        policy = definitions[current_test]["recoveryPolicy"]
        if definitions[current_test].get("useProjectRecoveryPolicy") is True:
            policy = project.get("defaultRecoveryPolicy") or policy
        assert policy.get("candidateProvider", "local") == "jev", "Hosted chooser was not explicitly enabled"
        record = payload["_0"]
        checked = audit_candidate_decision(record, capture_id=last_capture[0])
        assert checked["requestID"] not in candidate_decisions, "Duplicate provider decision request"
        candidate_decisions[checked["requestID"]] = record
        candidate_decision_tests[checked["requestID"]] = current_test
        candidate_decision_captures[checked["requestID"]] = last_capture[0]
    elif name == "capture":
        snapshot = payload["_0"]
        capture_id = uid(snapshot["captureID"]["rawValue"])
        assert capture_id not in capture_ids, "Capture reused in event stream"
        capture_ids.add(capture_id)
        path = root / "captures" / capture_id
        raw = json.loads(path.with_suffix(".json").read_text())
        raw_captures[capture_id] = raw
        snapshots_by_id[capture_id] = snapshot
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
    elif name == "captureProvenance":
        bound = payload["_0"]
        cid = uid(bound["snapshot"]["captureID"]["rawValue"])
        assert cid not in provenance_ids, "Duplicate capture provenance"
        raw_source = json.loads((root / "captures" / (cid + ".json")).read_text())
        assert audit_capture_provenance(bound, raw_source), "New live capture lacks timing provenance"
        provenance_ids.add(cid)
    elif name == "perception":
        record = payload["_0"]
        cid = uid(record["captureID"]["rawValue"])
        assert cid in provenance_ids, "OCR lacks capture timing provenance"
        assert cid == last_capture[0], "OCR emitted for superseded capture"
        assert cid not in perceptions, "Repeated OCR evidence for capture"
        audit_perception(record, raw_captures[cid], (root / "captures" / (cid + ".png")).read_bytes())
        assert instant(record["recognitionCompletedAt"]) <= instant(envelope["timestamp"]), "OCR completed after persistence"
        perceptions[cid] = record
    elif name == "perceptionWarmup":
        warmup = payload["_0"]
        assert instant(warmup["startedAt"]) <= instant(warmup["completedAt"]) <= instant(envelope["timestamp"])
        assert math.isfinite(warmup["milliseconds"]) and warmup["milliseconds"] >= 0
        assert not capture_ids, "Prewarm occurred after action-bearing captures"
    elif name == "recovery":
        record = payload["_0"]
        cid = uid(record["captureID"]["rawValue"])
        assert cid in raw_captures, "Recovery lacks original capture"
        assert uid(record["blockID"]) in blocks
        assert record["status"] in ("proposed", "dispatched", "verified", "refused", "recapture", "waiting")
        assert record["reason"] and record["provider"]
        assert type(record["actionCount"]) is int and 0 <= record["actionCount"] <= record["maximumActions"]
        assert record["actionCount"] == recovery_dispatch_count, "Recovery action budget differs from actual dispatch attempts"
        assert type(record["recaptureCount"]) is int and record["recaptureCount"] >= 0
        if current_test is not None:
            configured_test = definitions[current_test]
            configured_policy = configured_test["recoveryPolicy"]
            if configured_test.get("useProjectRecoveryPolicy") is True:
                configured_policy = project.get("defaultRecoveryPolicy") or configured_policy
            assert record["maximumActions"] == configured_policy["maximumActions"]
            assert record["minimumConfidence"] == configured_policy["minimumConfidence"]
            assert record["maximumCaptureAge"] == configured_policy["maximumCaptureAge"]
            assert record["recaptureCount"] <= configured_policy["maximumRecaptures"], "Recapture budget exceeded"
        assert math.isfinite(record["minimumConfidence"]) and 0 <= record["minimumConfidence"] <= 1
        assert math.isfinite(record["maximumCaptureAge"]) and 0 < record["maximumCaptureAge"] <= 10
        assert instant(record["recoveryStartedAt"]) <= instant(record["deadline"])
        candidates = record["candidates"]
        assert len({uid(c["id"]) for c in candidates}) == len(candidates), "Duplicate candidate IDs"
        assert all(uid(c["captureID"]["rawValue"]) == cid for c in candidates), "Mixed candidate captures"
        if record.get("geometry") is not None:
            raw = raw_captures[cid]
            assert record["geometry"] == {"pixels": {"width": raw["pixelWidth"], "height": raw["pixelHeight"]}, "screenFrame": raw["screenFrame"]}
        choice = record.get("choice")
        if choice is not None:
            assert uid(choice["captureID"]["rawValue"]) == cid
            assert math.isfinite(choice["confidence"]) and 0 <= choice["confidence"] <= 1
            chosen = [c for c in candidates if uid(c["id"]) == uid(choice["candidateID"])]
            assert len(chosen) == 1, "Unknown chosen candidate"
            if record["status"] in ("dispatched", "verified"):
                assert chosen[0]["isSafeForAutomaticExecution"] is True
                assert choice["confidence"] >= record["minimumConfidence"]
        if record["status"] == "dispatched":
            assert choice is not None and cid == last_capture[0]
        if record["status"] == "verified":
            after = uid(record["verificationCaptureID"]["rawValue"])
            assert after in raw_captures and after != cid and after == last_capture[0], "Recovery lacks fresh verification capture"
            assert any(r["status"] == "dispatched" and r["captureID"] == record["captureID"] and r.get("choice") == choice for r in recoveries), "Verified recovery lacks matching dispatched decision"
            if record["interruption"]["kind"] in ("knownReminder", "alert", "permissionPrompt"):
                old_contexts = {n["containingAlertContext"] for n in record["interruption"]["elements"] if n.get("containingAlertContext") is not None}
                assert old_contexts, "Dismissal verification lacks original alert context"
                assert not any(n.get("containingAlertContext") in old_contexts for n in snapshots_by_id[after]["elements"]), "Dismissed prompt still present"
            else:
                assert snapshots_by_id[cid]["elements"] != snapshots_by_id[after]["elements"], "Recovery claimed progress without semantic change"
        for request_id, provider_record in candidate_decisions.items():
            if request_id not in paired_candidate_decisions and candidate_decision_tests[request_id] == current_test and candidate_decision_captures[request_id] == cid:
                audit_candidate_decision(provider_record, capture_id=cid, candidates=candidates)
                if not provider_record["accepted"]:
                    assert record["status"] == "refused" and choice is None, "Rejected provider metadata lacks a local refusal"
                paired_candidate_decisions.add(request_id)
        if choice is not None and choice.get("providerEvidence") is not None:
            provider_record = choice["providerEvidence"]
            request_id = uid(provider_record["requestID"])
            assert candidate_decisions.get(request_id) == provider_record, "Recovery provider evidence was not durably recorded"
            assert provider_record["accepted"] is True, "Refused provider response became a recovery choice"
            assert uid(provider_record["selectedID"]) == uid(choice["candidateID"])
            assert provider_record["confidence"] == choice["confidence"]
            assert record["provider"] == provider_record["provider"]
        recoveries.append(record)
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
        action_kind, action_data = variant(payload["_1"])
        if action_kind in ("recoveryTap", "textTap"):
            assert block_id not in uncertain_recovery_blocks, "Uncertain recovery mutation retried"
            assert pending_recovery_dispatch is None, "Recovery retried without resolving prior dispatch"
            assert recoveries and recoveries[-1]["status"] == "proposed", "Recovery mutation lacks proposed decision"
            decision = recoveries[-1]
            cid = uid(decision["captureID"]["rawValue"])
            assert cid == last_capture[0] and uid(decision["blockID"]) == block_id
            choice = decision["choice"]
            chosen = next(c for c in decision["candidates"] if uid(c["id"]) == uid(choice["candidateID"]))
            assert chosen["isSafeForAutomaticExecution"] is True
            assert choice["confidence"] >= decision["minimumConfidence"]
            capture_age_at_event = instant(envelope["timestamp"]) - instant(raw_captures[cid]["snapshot"]["capturedAt"], True)
            assert 0 <= capture_age_at_event < decision["maximumCaptureAge"], "Recovery action event bound to stale/future capture"
            assert current_test is not None, "Recovery mutation outside configured test"
            test_definition = definitions[current_test]
            policy = test_definition["recoveryPolicy"]
            if test_definition.get("useProjectRecoveryPolicy") is True:
                policy = project.get("defaultRecoveryPolicy") or policy
            system_prompt = any(n.get("originBundleIdentifier") == "com.apple.springboard" for n in decision["interruption"]["elements"])
            action_limit = max(5, policy["maximumActions"]) if system_prompt else policy["maximumActions"]
            assert decision["maximumActions"] == action_limit
            assert decision["minimumConfidence"] == policy["minimumConfidence"]
            assert decision["maximumCaptureAge"] == policy["maximumCaptureAge"]
            if system_prompt:
                assert choice.get("providerEvidence") is None, "System prompt choice was not local"
                assert policy.get("allowSystemDismiss", True) is True, "System prompt acceptance disabled"
            elif policy.get("candidateProvider", "local") == "jev":
                assert choice.get("providerEvidence") is not None, "Hosted recovery lacks validated provider evidence"
            else:
                assert choice.get("providerEvidence") is None, "Hosted recovery used without opt-in"
            assert recovery_dispatch_count < action_limit, "Recovery action budget exhausted"
            recovery_dispatch_count += 1
            pending_recovery_dispatch = block_id
            candidate_kind, candidate_data = variant(chosen["action"])
            if action_kind == "recoveryTap":
                element = action_data["element"]
                observed = decision["interruption"]
                if system_prompt:
                    assert element.get("originBundleIdentifier") == "com.apple.springboard", "System prompt selected foreign button"
                    assert element.get("isEnabled") is True and element.get("isHittable") is True, "System prompt target not actionable"
                    assert element.get("buttonRole") != "destructive", "System prompt selected destructive button"
                    safe = [c for c in decision["candidates"] if c.get("isSafeForAutomaticExecution") is True]
                    assert len(safe) == 1, "Ambiguous system prompt candidates"
                else:
                    assert element.get("originBundleIdentifier") in (None, project["app"]["bundleIdentifier"]), "Automatic action targeted a foreign application alert"
                assert uid(action_data["captureID"]["rawValue"]) == cid
                assert candidate_kind == "tapAlertButton"
                assert candidate_data["_0"] == element, "Executed different semantic alert candidate"
                assert element in raw_captures[cid]["snapshot"]["elements"]
                assert element.get("isEnabled") is True and element.get("isHittable") is True
                assert element.get("label") and element.get("containingAlertContext") and element.get("containingAlertIdentifier"), "Incomplete semantic alert target"
                assert system_prompt or policy["mode"] in ("knownAutomatic", "safeInferred"), "Automatic dismissal in ask/fail mode"
                observed_nodes = decision["interruption"]["elements"]
                if system_prompt:
                    assert all(node.get("originBundleIdentifier") == "com.apple.springboard" for node in observed_nodes), "Mixed-origin system prompt"
                    assert all(node in snapshots_by_id[cid]["elements"] for node in observed_nodes), "Invented interruption evidence"
                    buttons = [node for node in observed_nodes if node["role"] == "button"]
                    candidate_nodes = []
                    for candidate in decision["candidates"]:
                        kind, data = variant(candidate["action"])
                        assert kind == "tapAlertButton", "Unreviewed action in alert candidate table"
                        candidate_nodes.append(data["_0"])
                    assert sorted(json.dumps(n, sort_keys=True) for n in candidate_nodes) == sorted(json.dumps(n, sort_keys=True) for n in buttons), "Incomplete or invented alert candidate table"
                else:
                    observed = observed_nodes
                    assert all(node.get("originBundleIdentifier") in (None, project["app"]["bundleIdentifier"]) for node in observed), "Automatic action used foreign application interruption evidence"
                    assert all(node in snapshots_by_id[cid]["elements"] for node in observed), "Invented interruption evidence"
                    contexts = {node["containingAlertContext"] for node in observed if node.get("containingAlertContext") is not None}
                    identities = {node["containingAlertIdentifier"] for node in observed if node.get("containingAlertIdentifier") is not None}
                    buttons = [node for node in observed if node["role"] == "button"]
                    candidate_nodes = []
                    for candidate in decision["candidates"]:
                        kind, data = variant(candidate["action"])
                        assert kind == "tapAlertButton", "Unreviewed action in alert candidate table"
                        candidate_nodes.append(data["_0"])
                    assert sorted(json.dumps(n, sort_keys=True) for n in candidate_nodes) == sorted(json.dumps(n, sort_keys=True) for n in buttons), "Incomplete or invented alert candidate table"
                    expected_assertions = test_definition["preconditions"] + test_definition["assertions"]
                    for block in test_definition["blocks"]:
                        kind, data = variant(block["action"])
                        if block["enabled"] and kind == "assertion":
                            expected_assertions.append(data["_0"])
                    for assertion in expected_assertions:
                        if variant(assertion)[0] != "doesNotExist":
                            assert not evaluate(assertion, {"elements": observed}), "Automatic dismissal interfered with an expected prompt assertion"
                    approved = []
                    for reviewed in project.get("reviewedAlertPolicies") or []:
                        if reviewed["bundleIdentifier"] != project["app"]["bundleIdentifier"]:
                            continue
                        if contexts != {reviewed["exactContext"]} or identities != {reviewed["alertIdentifier"]}:
                            continue
                        if len(buttons) != len(reviewed["buttons"]):
                            continue
                        if all(sum(node.get("identifier") == b.get("identifier") and node.get("label") == b["label"] for node in buttons) == 1 for b in reviewed["buttons"]):
                            approved.append(reviewed)
                    assert len(approved) == 1, "No unique exact project-reviewed alert policy"
                    reviewed = approved[0]
                    assert reviewed["id"] in policy["knownInterruptionPolicies"], "Alert policy disabled"
                    assert all(b["risk"] != "destructive" for b in reviewed["buttons"])
                    selected_risks = [b["risk"] for b in reviewed["buttons"] if b.get("identifier") == element.get("identifier") and b["label"] == element["label"]]
                    assert selected_risks == ["nonDestructiveDismissal"], "Selected dismissal not reviewed as non-destructive"
                    assert all(node.get("buttonRole") != "destructive" for node in buttons)
                    if policy["mode"] == "knownAutomatic":
                        assert reviewed.get("automaticButtonIdentifier") == element.get("identifier")
                        assert reviewed.get("automaticButtonLabel") == element["label"]
                    else:
                        assert sum(b["risk"] == "nonDestructiveDismissal" for b in reviewed["buttons"]) == 1, "Ambiguous inferred dismissals"
            else:
                assert policy["allowTextFallback"] is True, "OCR action not enabled by saved policy"
                assert candidate_kind == "tapPoint"
                assert cid in perceptions and action_data["perception"] == perceptions[cid], "Executed different OCR evidence"
                assert instant(perceptions[cid]["recognitionCompletedAt"]) <= instant(envelope["timestamp"]), "Action preceded OCR completion"
                capture = action_data["capture"]
                assert uid(capture["id"]["rawValue"]) == cid
                assert capture["pixelSize"] == perceptions[cid]["geometry"]["pixels"]
                assert capture["createdAt"] == perceptions[cid]["screenshotStartedAt"]
                assert action_data["minimumConfidence"] == decision["minimumConfidence"]
                assert action_data["maximumAge"] == decision["maximumCaptureAge"]
                block_action, block_config = variant(blocks[block_id]["action"])
                assert block_action == "tap", "OCR action outside authored tap"
                assert any(variant(t) == ("text", {"_0": action_data["text"]}) for t in block_config["targets"]), "OCR text not in authored target strategies"
                regions = [r for r in perceptions[cid]["regions"] if r["text"].strip().casefold() == action_data["text"].strip().casefold()]
                assert len(regions) == 1, "Ambiguous executed OCR target"
                region = regions[0]
                assert region["confidence"] >= decision["minimumConfidence"]
                box = region["pixelBox"]
                point = candidate_data["_0"]
                assert abs(point["x"] - box["x"] - box["width"] / 2) < 0.00001
                assert abs(point["y"] - box["y"] - box["height"] / 2) < 0.00001
        used_before_captures.add(last_capture[0])
        pending_dispatch = (block_id, payload["_1"])
        dispatches.append((block_id, last_capture[0], envelope["sequence"]))
    elif name == "action":
        last_action_at = envelope["timestamp"]
        block_id = uid(payload["_0"])
        assert blocks[block_id]["enabled"]
        assert last_capture is not None, "Mutation lacks before-capture"
        assert pending_success is None, "Mutation lacks previous after-capture"
        assert pending_dispatch == (block_id, payload["_1"]), "Success lacks matching action attempt"
        pending_dispatch = None
        if pending_recovery_dispatch is not None:
            assert pending_recovery_dispatch == block_id
            pending_recovery_dispatch = None
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
        if pending_recovery_dispatch is not None:
            assert uid(payload["_0"]) == pending_recovery_dispatch
            assert payload["_1"] in ("needsReview", "cancelled") and payload.get("reason"), "Uncertain recovery lacks explicit outcome"
            uncertain_recovery_blocks.add(pending_recovery_dispatch)
            pending_recovery_dispatch = None
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
assert pending_recovery_dispatch is None, "Recovery dispatch has no terminal block outcome"
assert paired_candidate_decisions == set(candidate_decisions), "Provider decision lacks its complete local candidate table"
assert provenance_ids <= capture_ids, "Provenance never followed by capture event"
if provenance_ids != capture_ids:
    audit_output.write_text(json.dumps({"verified": False, "reason": "Production Phase 3 captures lack provenance events", "missingCaptureIDs": sorted(capture_ids - provenance_ids)}, indent=2) + "\n")
    raise AssertionError("Production Phase 3 captures lack provenance events")
assert starts == expected_ids[:len(starts)], "Tests ran out of project selection order"
assert [test_id for test_id, _ in finishes] == starts
assert [(uid(r["testID"]), r["outcome"]) for r in report["tests"]] == finishes
if report["outcome"] == "passed":
    assert not missing_after, "Passed run has unverified post-action state"
    assert starts == expected_ids, "Passed run omitted selected tests"
    assert all(outcome == "passed" for _, outcome in finishes)
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
audit["phase4"] = {"perceptions": len(perceptions), "provenanceCaptures": len(provenance_ids), "recoveryEvents": len(recoveries), "uncertainRecoveryBlocks": sorted(uncertain_recovery_blocks)}
audit["phase4"]["goalAssessments"] = len(goal_assessments)
audit["phase4"]["failureSummaries"] = len(failure_summaries)
audit["phase4"]["candidateDecisions"] = len(candidate_decisions)
audit["auditorSHA256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
audit["auditorDependenciesSHA256"] = {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                                      for name in ("audit_perception_evidence.py", "audit_goal_evidence.py", "audit_candidate_evidence.py")}
audit_output.write_text(json.dumps(audit, indent=2) + "\n")
print(json.dumps(audit))
