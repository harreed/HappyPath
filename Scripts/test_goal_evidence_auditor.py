#!/usr/bin/env python3
"""Exercise goal-auditor evidence corruption and honest refusal handling."""
import copy
import hashlib
import json
import unittest
from audit_goal_evidence import audit_goal_assessment, audit_failure_summary

TEST = "00000000-0000-0000-0000-000000000001"
CAPTURE = "00000000-0000-0000-0000-000000000002"
REQUEST = "00000000-0000-0000-0000-000000000003"
OTHER = "00000000-0000-0000-0000-000000000004"
STAMP = 1800000000000
GOAL = "Welcome Ada is visible"
SNAPSHOT = {"captureID": {"rawValue": CAPTURE}, "capturedAt": STAMP,
            "elements": [{"role": "staticText", "label": "Welcome Ada"}]}
RECORD = {"testID": TEST, "goal": GOAL, "provider": "test.typed-text",
          "completedAt": STAMP + 200, "minimumConfidence": 0.9,
          "outcome": "passed", "reason": "Cited visible text",
          "request": {"requestID": REQUEST, "goal": GOAL,
                      "captureID": {"rawValue": CAPTURE}, "capturedAt": STAMP,
                      "requestedAt": STAMP + 100, "deadline": STAMP + 5000,
                      "mode": "semanticText", "evidence": [{"id": "semantic-0",
                      "text": "role=staticText; identifier=; label=Welcome Ada; value="}]},
          "assessment": {"requestID": REQUEST, "captureID": {"rawValue": CAPTURE},
                         "verdict": "satisfied", "requiresImage": False, "confidence": 0.95,
                         "evidenceIDs": ["semantic-0"], "reason": "Cited visible text"}}


def audit(record, **changes):
    arguments = dict(test_id=TEST, goal=GOAL, snapshot=SNAPSHOT,
                     event_timestamp=STAMP + 201, last_mutation_timestamp=STAMP - 1)
    arguments.update(changes)
    return audit_goal_assessment(record, **arguments)


class GoalAuditTests(unittest.TestCase):
    def test_valid_binding(self):
        self.assertEqual(audit(RECORD)["outcome"], "passed")

    def test_raw_apple_response_matches_typed_evidence(self):
        record = copy.deepcopy(RECORD)
        record["provider"] = "apple.foundationmodels.semantic-text"
        record["assessment"]["rawResponse"] = json.dumps({k: record["assessment"][k] for k in
            ("verdict", "requiresImage", "confidence", "evidenceIDs", "reason")})
        self.assertEqual(audit(record)["outcome"], "passed")
        record["assessment"]["reason"] = "Different explanation"
        with self.assertRaisesRegex(AssertionError, "raw Apple response"):
            audit(record)

    def test_corrupt_evidence(self):
        for field in ("capture", "timestamp", "text", "reference", "confidence", "image", "late"):
            with self.subTest(field=field):
                record = copy.deepcopy(RECORD)
                if field == "capture": record["request"]["captureID"]["rawValue"] = OTHER
                if field == "timestamp": record["request"]["capturedAt"] += 1
                if field == "text": record["request"]["evidence"][0]["text"] = "Invented evidence"
                if field == "reference": record["assessment"]["evidenceIDs"] = ["invented"]
                if field == "confidence": record["assessment"]["confidence"] = 0.1
                if field == "image": record["assessment"]["requiresImage"] = True
                if field == "late": record["request"]["deadline"] = STAMP + 150
                with self.assertRaises(AssertionError): audit(record)

    def test_invalid_response_retained_as_review(self):
        record = copy.deepcopy(RECORD)
        record["assessment"]["evidenceIDs"] = ["invented"]
        record["outcome"] = "needsReview"
        self.assertEqual(audit(record)["outcome"], "needsReview")

    def test_sanitized_nan_cannot_become_valid_zero(self):
        record = copy.deepcopy(RECORD)
        record["minimumConfidence"] = record["assessment"]["confidence"] = 0
        record["invalidNumericValues"] = {"assessment.confidence": "nan"}
        with self.assertRaisesRegex(AssertionError, "contradicts evidence validation"):
            audit(record)
        record["outcome"] = "needsReview"
        self.assertEqual(audit(record)["outcome"], "needsReview")

    def test_image_requirement_cannot_be_downgraded(self):
        with self.assertRaisesRegex(AssertionError, "requirement changed"):
            audit(RECORD, expected_mode="imageUnavailable")
        record = copy.deepcopy(RECORD)
        record["request"]["mode"] = "imageUnavailable"
        record["outcome"] = "needsReview"
        self.assertEqual(audit(record, expected_mode="imageUnavailable")["outcome"], "needsReview")

    def test_screenshot_fallback_requires_matching_retained_image(self):
        screenshot = b"\x89PNG\r\n\x1a\nfixture-pixels"
        record = copy.deepcopy(RECORD)
        record["provider"] = "fixture.screenshot"
        record["request"]["mode"] = "imageObserved"
        record["assessment"] = None
        record["reason"] = "Practice tab is highlighted"
        record["imageAssessment"] = {
            "captureID": {"rawValue": CAPTURE},
            "imageSHA256": hashlib.sha256(screenshot).hexdigest(),
            "verdict": "satisfied", "confidence": 0.95,
            "reason": record["reason"], "providerID": record["provider"],
            "processingLocation": "remote", "purpose": "liveActionSupport"}
        self.assertEqual(audit(record, expected_mode="semanticText", screenshot=screenshot)["outcome"], "passed")
        record["imageAssessment"]["imageSHA256"] = "0" * 64
        with self.assertRaisesRegex(AssertionError, "hash differs"):
            audit(record, expected_mode="semanticText", screenshot=screenshot)

    def test_hosted_screenshot_verdict_matches_raw_response(self):
        screenshot = b"\x89PNG\r\n\x1a\nfixture-pixels"
        record = copy.deepcopy(RECORD)
        record["provider"] = "anthropic.claude-haiku-5-5.vision"
        record["request"]["mode"] = "imageObserved"
        record["assessment"] = None
        record["imageAssessment"] = {
            "captureID": {"rawValue": CAPTURE},
            "imageSHA256": hashlib.sha256(screenshot).hexdigest(),
            "verdict": "satisfied", "confidence": 0.95,
            "reason": record["reason"], "providerID": record["provider"],
            "processingLocation": "remote", "purpose": "liveActionSupport",
            "rawResponse": json.dumps({"verdict": "satisfied", "confidence": 0.95,
                                       "reason": record["reason"]})}
        self.assertEqual(audit(record, screenshot=screenshot)["outcome"], "passed")
        record["imageAssessment"]["verdict"] = "notSatisfied"
        with self.assertRaisesRegex(AssertionError, "raw response"):
            audit(record, screenshot=screenshot)

    def test_clef_screenshot_verdict_matches_raw_response(self):
        screenshot = b"\x89PNG\r\n\x1a\nfixture-pixels"
        record = copy.deepcopy(RECORD)
        record["provider"] = "cloudflare.clef-flash.vision"
        record["minimumConfidence"] = 0.4
        record["request"]["mode"] = "imageObserved"
        record["assessment"] = None
        record["imageAssessment"] = {
            "captureID": {"rawValue": CAPTURE},
            "imageSHA256": hashlib.sha256(screenshot).hexdigest(),
            "verdict": "satisfied", "confidence": 0.72,
            "reason": record["reason"], "providerID": record["provider"],
            "processingLocation": "remote", "purpose": "liveActionSupport",
            "rawResponse": json.dumps({"content": json.dumps({"verdict": "satisfied"}),
                                       "confidence": 0.72, "probabilities": {"satisfied": 0.72}})}
        self.assertEqual(audit(record, screenshot=screenshot)["outcome"], "passed")
        record["imageAssessment"]["verdict"] = "notSatisfied"
        with self.assertRaisesRegex(AssertionError, "raw Clef response"):
            audit(record, screenshot=screenshot)

    def test_final_capture_after_mutation(self):
        with self.assertRaisesRegex(AssertionError, "predates final mutation"):
            audit(RECORD, last_mutation_timestamp=STAMP + 1)

    def test_ocr_uses_original_indices_and_same_capture(self):
        record = copy.deepcopy(RECORD)
        record["request"]["mode"] = "ocrText"
        record["request"]["evidence"] = [{"id": "ocr-1", "text": "Welcome Ada"}]
        record["assessment"]["evidenceIDs"] = ["ocr-1"]
        perception = {"captureID": {"rawValue": CAPTURE}, "recognitionCompletedAt": STAMP + 50,
                      "regions": [{"text": "Noise", "confidence": 0.1},
                                  {"text": "Welcome Ada", "confidence": 0.99}]}
        self.assertEqual(audit(record, perception=perception)["outcome"], "passed")
        perception["captureID"]["rawValue"] = OTHER
        with self.assertRaisesRegex(AssertionError, "another capture"):
            audit(record, perception=perception)

    def test_unavailable_is_not_pass(self):
        record = copy.deepcopy(RECORD)
        record["request"] = record["assessment"] = None
        with self.assertRaises(AssertionError): audit(record)
        record["outcome"] = "needsReview"
        self.assertEqual(audit(record)["outcome"], "needsReview")

    def test_summary_cannot_change_result(self):
        record = {"source": {"testID": TEST, "outcome": "failed", "reason": "Required assertion false",
                             "assessmentRequestID": REQUEST}, "provider": "test.summary", "text": "Failed"}
        audit_failure_summary(record, test_id=TEST, outcome="failed", assessment_request_id=REQUEST)
        with self.assertRaisesRegex(AssertionError, "changed established outcome"):
            audit_failure_summary(record, test_id=TEST, outcome="passed", assessment_request_id=REQUEST)


if __name__ == "__main__":
    unittest.main()
