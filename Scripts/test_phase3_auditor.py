#!/usr/bin/env python3
"""Corrupt disposable copies of a known-alert archive to test audit refusals."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).resolve()
auditor = Path(__file__).with_name("audit_phase3_run.py").resolve()


def run(path, expected="passed"):
    return subprocess.run([sys.executable, str(auditor), str(path), expected], capture_output=True, text=True)


def event_rows(path):
    return [json.loads(line) for line in (path / "events.jsonl").read_text().splitlines()]


def save_events(path, rows):
    (path / "events.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))


def omit_candidate(path):
    rows = event_rows(path)
    for row in rows:
        record = row["event"].get("recovery", {}).get("_0")
        if record and record["status"] == "proposed":
            record["candidates"] = [c for c in record["candidates"] if c["id"] == record["choice"]["candidateID"]]
            break
    save_events(path, rows)


def age_action(path):
    rows = event_rows(path)
    shifted = False
    for row in rows:
        if "actionStarted" in row["event"]:
            shifted = True
        if shifted:
            row["timestamp"] += 9000
    save_events(path, rows)


def expect_prompt(path):
    file = path / "project.json"
    project = json.loads(file.read_text())
    project["categories"][0]["suites"][0]["tests"][0]["assertions"].append({"textVisible": {"_0": "Not Now"}})
    file.write_text(json.dumps(project))


def foreign_alert(path):
    def rewrite(value):
        if isinstance(value, dict):
            if value.get("containingAlertContext") is not None:
                value["originBundleIdentifier"] = "com.apple.springboard"
            for item in value.values():
                rewrite(item)
        elif isinstance(value, list):
            for item in value:
                rewrite(item)
    rows = event_rows(path)
    rewrite(rows)
    save_events(path, rows)
    for file in (path / "captures").rglob("*.json"):
        value = json.loads(file.read_text())
        rewrite(value)
        file.write_text(json.dumps(value))


checks = [("candidate-omission", omit_candidate, "Incomplete or invented alert candidate table"),
          ("aged-action", age_action, "Recovery action event bound to stale/future capture"),
          ("expected-prompt", expect_prompt, "Automatic dismissal interfered with an expected prompt assertion"),
          ("foreign-alert", foreign_alert, "Automatic action targeted a foreign application alert")]
with tempfile.TemporaryDirectory(prefix="phase3-audit-negatives-") as temporary:
    base = Path(temporary)
    pristine = base / "pristine"
    shutil.copytree(source, pristine)
    result = run(pristine)
    assert result.returncode == 0, result.stderr
    for name, mutate, expected in checks:
        path = base / name
        shutil.copytree(source, path)
        mutate(path)
        result = run(path)
        assert result.returncode != 0 and expected in result.stderr, (name, result.stdout, result.stderr)
        print(name + ": rejected at intended check")
    if len(sys.argv) > 2:
        failed = base / "failed-test-masked-by-aggregate"
        shutil.copytree(Path(sys.argv[2]).resolve(), failed)
        baseline = run(failed, "failed")
        assert baseline.returncode == 0, baseline.stderr
        report_file = failed / "run.json"
        report = json.loads(report_file.read_text())
        assert len(report["tests"]) == 1 and report["tests"][0]["outcome"] == "failed"
        report["tests"][0]["outcome"] = "passed"
        report_file.write_text(json.dumps(report))
        rows = event_rows(failed)
        for row in rows:
            if "testFinished" in row["event"]:
                row["event"]["testFinished"]["_1"] = "passed"
            if "finished" in row["event"]:
                row["event"]["finished"]["_0"] = report
        save_events(failed, rows)
        result = run(failed, "failed")
        assert result.returncode != 0 and "Passed test contradicts required deterministic assertions" in result.stderr, result.stderr
        print("failed-test-masked-by-aggregate: rejected at intended check")
print(f"Pristine archives accepted; {len(checks) + (1 if len(sys.argv) > 2 else 0)} independent corruptions rejected. Original archives untouched.")
