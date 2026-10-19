#!/usr/bin/env python3
import copy
import unittest
from audit_candidate_evidence import audit_candidate_decision

CAPTURE = "00000000-0000-0000-0000-000000000001"
OPTION = "00000000-0000-0000-0000-000000000002"
REQUEST = "00000000-0000-0000-0000-000000000003"
RECORD = {"requestID": REQUEST, "captureID": {"rawValue": CAPTURE}, "provider": "jev",
          "optionIDs": [OPTION, "abstain"], "selectedID": OPTION,
          "probabilities": {OPTION: 0.98, "abstain": 0.02}, "confidence": 0.95,
          "reason": "Host-bound response", "accepted": True}
CANDIDATES = [{"id": OPTION, "captureID": {"rawValue": CAPTURE}, "isSafeForAutomaticExecution": True}]


def audit(record, candidates=CANDIDATES):
    return audit_candidate_decision(record, capture_id=CAPTURE, candidates=candidates)


class CandidateAuditTests(unittest.TestCase):
    def test_valid_provider_choice_is_not_action_permission(self):
        self.assertTrue(audit(RECORD)["accepted"])
        record = copy.deepcopy(RECORD)
        record["confidence"] = 0.1
        self.assertTrue(audit(record)["accepted"])

    def test_invalid_accepted_records(self):
        for kind in ("unknown", "abstain", "incomplete", "sum", "nonmax", "confidence", "sanitized", "stale", "tie"):
            with self.subTest(kind=kind):
                record = copy.deepcopy(RECORD)
                if kind == "unknown": record["selectedID"] = REQUEST
                if kind == "abstain": record["selectedID"] = "abstain"
                if kind == "incomplete": del record["probabilities"]["abstain"]
                if kind == "sum": record["probabilities"][OPTION] = 0.1
                if kind == "nonmax": record["probabilities"] = {OPTION: 0.02, "abstain": 0.98}
                if kind == "confidence": record["confidence"] = 2
                if kind == "sanitized": record["invalidNumericValues"] = {"confidence": "nan"}
                if kind == "stale": record["responseCaptureID"] = {"rawValue": REQUEST}
                if kind == "tie": record["probabilities"] = {OPTION: 0.5, "abstain": 0.5}
                with self.assertRaises(AssertionError): audit(record)

    def test_refused_invalid_response_is_retained(self):
        record = copy.deepcopy(RECORD)
        record.update(accepted=False, selectedID="unknown", probabilities={"unknown": 2})
        self.assertFalse(audit(record)["accepted"])

    def test_rejected_raw_metadata_is_not_request_authority(self):
        record = copy.deepcopy(RECORD)
        record.update(accepted=False, originalAccepted=True, provider="configured.candidate-chooser",
                      captureID={"rawValue": REQUEST}, optionIDs=["bad", "bad"])
        self.assertFalse(audit(record)["accepted"])
        record["accepted"] = True
        with self.assertRaises(AssertionError): audit(record)

    def test_foreign_candidate_table(self):
        with self.assertRaisesRegex(AssertionError, "locally safe"):
            audit(RECORD, candidates=[dict(CANDIDATES[0], isSafeForAutomaticExecution=False)])


if __name__ == "__main__":
    unittest.main()
