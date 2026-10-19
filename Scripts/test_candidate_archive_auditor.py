#!/usr/bin/env python3
"""Verify rejected metadata stays non-authoritative in a real refusal archive."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).resolve()
auditor = Path(__file__).with_name("audit_phase3_run.py")
with tempfile.TemporaryDirectory(prefix="candidate-archive-audit-") as temporary:
    for mode in ("pristine", "raw-refusal", "promoted", "non-refusal"):
        path = Path(temporary) / mode
        shutil.copytree(source, path)
        rows = [json.loads(line) for line in (path / "events.jsonl").read_text().splitlines()]
        decision = next(row["event"]["candidateDecision"]["_0"] for row in rows
                        if "candidateDecision" in row["event"])
        if mode != "pristine":
            decision.update(captureID={"rawValue": "00000000-0000-0000-0000-000000000001"},
                            optionIDs=["invalid", "invalid"],
                            provider="configured.candidate-chooser", originalAccepted=True)
        if mode == "promoted":
            decision["accepted"] = True
        if mode == "non-refusal":
            next(row["event"]["recovery"]["_0"] for row in rows
                 if "recovery" in row["event"])["status"] = "proposed"
        (path / "events.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
        result = subprocess.run([sys.executable, str(auditor), str(path)], capture_output=True, text=True)
        assert (result.returncode == 0) == (mode in ("pristine", "raw-refusal")), (mode, result.stderr)
        if mode == "promoted":
            assert "Provider decision used another capture" in result.stderr
        if mode == "non-refusal":
            assert "Rejected provider metadata lacks a local refusal" in result.stderr
        print(mode + ": verified expected audit result")
print("Original archive untouched.")
