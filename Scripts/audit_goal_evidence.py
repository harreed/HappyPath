"""Independent validation of durable goal evidence, not model truth evaluation."""
import math
import json
import uuid
import hashlib


def identity(value):
    if isinstance(value, dict):
        value = value["rawValue"]
    return str(uuid.UUID(value))


def number(value):
    assert type(value) in (int, float) and math.isfinite(value), "Invalid goal evidence number"
    return value


def semantic_items(snapshot):
    return [{"id": f"semantic-{index}", "text":
             f"role={node['role']}; identifier={node.get('identifier') or ''}; "
             f"label={node.get('label') or ''}; value={node.get('value') or ''}"}
            for index, node in enumerate(snapshot["elements"])]


def audit_goal_assessment(record, *, test_id, goal, snapshot, event_timestamp,
                          last_mutation_timestamp=None, expected_mode=None, perception=None,
                          screenshot=None):
    """Dates use durable v2 milliseconds. Invalid responses must remain review.

    The caller supplies the current final capture, not an arbitrary matching old
    capture. This checks provenance and local validation, never infers whether
    an arbitrary natural-language goal is true from model confidence alone.
    """
    assert identity(record["testID"]) == identity(test_id), "Goal belongs to another test"
    assert record["goal"] == goal and goal.strip(), "Goal differs from saved definition"
    assert isinstance(record["provider"], str) and record["provider"], "Missing goal provider"
    assert isinstance(record["reason"], str) and record["reason"].strip(), "Missing goal reason"
    completed = number(record["completedAt"])
    assert completed <= number(event_timestamp), "Goal event precedes completion"
    threshold = number(record["minimumConfidence"])
    invalid_numbers = record.get("invalidNumericValues") or {}
    assert isinstance(invalid_numbers, dict) and all(isinstance(k, str) and isinstance(v, str) for k, v in invalid_numbers.items())
    request, response = record.get("request"), record.get("assessment")
    image = record.get("imageAssessment")
    if request is None:
        assert response is None and image is None and record["outcome"] == "needsReview", "Missing goal evidence produced a result"
        return {"outcome": "needsReview", "requestID": None, "references": 0}
    assert snapshot is not None, "Goal request has no captured evidence"
    assert identity(request["captureID"]) == identity(snapshot["captureID"]), "Goal uses an old/noncurrent capture"
    assert request["goal"] == goal, "Provider assessed a different goal"
    request_id = identity(request["requestID"])
    captured = number(request["capturedAt"])
    assert abs(captured - number(snapshot["capturedAt"])) < 0.01, "Goal retimestamped captured evidence"
    if last_mutation_timestamp is not None:
        assert captured >= number(last_mutation_timestamp), "Goal evidence predates final mutation"
    requested, deadline = number(request["requestedAt"]), number(request["deadline"])
    mode = request["mode"]
    if expected_mode is not None:
        assert mode == expected_mode or (mode == "imageObserved" and image is not None), "Goal evidence requirement changed"
    assert mode in ("semanticText", "ocrText", "imageUnavailable", "imageObserved"), "Unknown goal evidence mode"
    if mode == "ocrText":
        assert perception is not None, "OCR goal lacks retained perception"
        assert identity(perception["captureID"]) == identity(request["captureID"]), "OCR goal uses another capture"
        assert number(perception["recognitionCompletedAt"]) <= requested, "Goal request precedes OCR completion"
        expected_items = [{"id": f"ocr-{index}", "text": region["text"]}
                          for index, region in enumerate(perception["regions"])
                          if number(region["confidence"]) >= threshold]
        assert request["evidence"] == expected_items, "Goal evidence differs from retained OCR regions"
    else:
        assert request["evidence"] == semantic_items(snapshot), "Goal evidence differs from captured semantic nodes"
    expected = "needsReview"
    references = []
    if mode == "imageObserved":
        assert response is None and image is not None, "Screenshot assessment mixed with text verdict"
        assert screenshot is not None and screenshot[:8] == b"\x89PNG\r\n\x1a\n", "Screenshot bytes unavailable"
        assert identity(image["captureID"]) == identity(request["captureID"]), "Screenshot assessment uses another capture"
        assert image["imageSHA256"] == hashlib.sha256(screenshot).hexdigest(), "Screenshot assessment hash differs from retained image"
        assert image["providerID"] == record["provider"] and image["processingLocation"] in ("remote", "onDevice")
        assert image["purpose"] == "liveActionSupport", "Archived analysis cannot establish a live result"
        if record["provider"] == "anthropic.claude-haiku-5-5.vision":
            raw = json.loads(image["rawResponse"])
            for key in ("verdict", "confidence", "reason"):
                assert raw[key] == image[key], "Typed screenshot assessment differs from raw response"
        elif record["provider"] == "cloudflare.clef-flash.vision":
            raw = json.loads(image["rawResponse"])
            content = json.loads(raw["content"])
            assert content["verdict"] == image["verdict"], "Typed screenshot assessment differs from raw Clef response"
            assert raw["confidence"] == image["confidence"], "Typed confidence differs from raw Clef response"
        confidence = number(image["confidence"])
        assert image["verdict"] in ("satisfied", "notSatisfied", "insufficient")
        assert isinstance(image["reason"], str) and image["reason"].strip() and len(image["reason"]) <= 4000
        assert image["reason"] == record["reason"], "Screenshot result reason changed"
        if (captured <= requested <= completed < deadline and requested - captured < 8000
                and 0 <= confidence <= 1 and 0 <= threshold <= 1 and confidence >= threshold
                and not invalid_numbers and image["verdict"] != "insufficient"):
            expected = "passed" if image["verdict"] == "satisfied" else "failed"
        assert record["outcome"] == expected, "Goal outcome contradicts screenshot evidence"
        return {"outcome": expected, "requestID": request_id, "references": 1}
    assert image is None, "Screenshot verdict attached to text-only goal"
    if response is not None:
        if record["provider"] == "apple.foundationmodels.semantic-text":
            raw = json.loads(response["rawResponse"])
            for key in ("verdict", "requiresImage", "evidenceIDs", "reason"):
                assert raw[key] == response[key], "Typed assessment differs from raw Apple response"
            if "assessment.confidence" not in invalid_numbers:
                assert raw["confidence"] == response["confidence"], "Typed confidence differs from raw Apple response"
        confidence = number(response["confidence"])
        references = response["evidenceIDs"]
        assert isinstance(references, list) and all(isinstance(item, str) for item in references)
        assert type(response["requiresImage"]) is bool
        assert response["verdict"] in ("satisfied", "notSatisfied", "insufficient")
        known = {item["id"] for item in request["evidence"]}
        valid = (
            captured <= requested <= completed < deadline and requested - captured < 8000
            and identity(response["requestID"]) == request_id
            and identity(response["captureID"]) == identity(request["captureID"])
            and 0 <= confidence <= 1 and 0 <= threshold <= 1
            and not invalid_numbers
            and mode != "imageUnavailable" and not response["requiresImage"]
            and len(known) == len(request["evidence"])
            and len(set(references)) == len(references) and set(references) <= known
            and bool(references) and bool(response["reason"].strip())
            and response["verdict"] != "insufficient" and confidence >= threshold)
        if valid:
            expected = "passed" if response["verdict"] == "satisfied" else "failed"
    assert record["outcome"] == expected, "Goal outcome contradicts evidence validation"
    return {"outcome": expected, "requestID": request_id, "references": len(references)}


def audit_failure_summary(record, *, test_id, outcome, assessment_request_id):
    source = record["source"]
    assert identity(source["testID"]) == identity(test_id)
    assert source["outcome"] == outcome, "Summary changed established outcome"
    actual = source.get("assessmentRequestID")
    assert (identity(actual) if actual is not None else None) == assessment_request_id, "Summary refers to another assessment"
    assert source["reason"].strip() and record["provider"].strip() and record["text"].strip()
    if record["provider"] == "apple.foundationmodels.text-summary":
        assert json.loads(record["rawResponse"])["explanation"] == record["text"], "Summary differs from raw Apple response"
