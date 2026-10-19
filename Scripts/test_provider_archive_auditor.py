#!/usr/bin/env python3
"""Corrupt disposable copies of the real six-case provider acceptance archive."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).resolve()
auditor = Path(__file__).with_name("audit_phase3_run.py")


def goal(rows, mode=None, outcome=None):
    return next(e["event"]["goalAssessment"]["_0"] for e in rows
                if "goalAssessment" in e["event"]
                and (mode is None or (e["event"]["goalAssessment"]["_0"].get("request") or {}).get("mode") == mode)
                and (outcome is None or e["event"]["goalAssessment"]["_0"]["outcome"] == outcome))


def missing_goal(rows):
    row = next(e for e in rows if "goalAssessment" in e["event"])
    rows.remove(row)


def invented_text(rows):
    goal(rows, "semanticText", "passed")["request"]["evidence"][0]["text"] = "Invented final state"


def raw_response_changed(rows):
    assessment = goal(rows, "semanticText", "passed")["assessment"]
    raw = json.loads(assessment["rawResponse"])
    raw["reason"] = "Changed raw provider explanation"
    assessment["rawResponse"] = json.dumps(raw)


def promote_review(rows):
    goal(rows, "semanticText", "needsReview")["outcome"] = "passed"


def summary_result_changed(rows):
    summary = next(e["event"]["failureSummary"]["_0"] for e in rows if "failureSummary" in e["event"])
    summary["source"]["outcome"] = "passed"


def retimestamp(rows):
    goal(rows, "semanticText", "passed")["request"]["capturedAt"] += 1


def downgrade_image(rows):
    goal(rows, "imageUnavailable")["request"]["mode"] = "semanticText"


def missing_final_ocr(rows):
    capture_id = goal(rows, "ocrText")["request"]["captureID"]
    row = next(e for e in rows if e["event"].get("perception", {}).get("_0", {}).get("captureID") == capture_id)
    rows.remove(row)


checks = [
    ("missing-goal", missing_goal, "Nonempty final goal was not assessed"),
    ("invented-evidence", invented_text, "Goal evidence differs from captured semantic nodes"),
    ("raw-response-drift", raw_response_changed, "Typed assessment differs from raw Apple response"),
    ("review-promoted", promote_review, "Goal outcome contradicts evidence validation"),
    ("summary-result-drift", summary_result_changed, "Summary changed established outcome"),
    ("retimestamped-final-capture", retimestamp, "Goal retimestamped captured evidence"),
    ("image-downgraded", downgrade_image, "Goal evidence requirement changed"),
    ("missing-final-ocr", missing_final_ocr, "OCR goal lacks retained perception"),
]

with tempfile.TemporaryDirectory(prefix="provider-archive-audit-") as temporary:
    base = Path(temporary)
    for name, mutate, expected in [("pristine", None, None)] + checks:
        path = base / name
        shutil.copytree(source, path)
        if mutate:
            rows = [json.loads(line) for line in (path / "events.jsonl").read_text().splitlines()]
            mutate(rows)
            for index, row in enumerate(rows, start=1):
                row["sequence"] = index
            (path / "events.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
        result = subprocess.run([sys.executable, str(auditor), str(path), "failed"], capture_output=True, text=True)
        if mutate:
            assert result.returncode != 0 and expected in result.stderr, (name, result.stdout, result.stderr)
            print(name + ": rejected at intended check")
        else:
            assert result.returncode == 0, result.stderr
        shutil.rmtree(path)
print("Pristine archive accepted; 8 corrupted copies rejected. Original archive untouched.")
