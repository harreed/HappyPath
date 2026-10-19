"""Audit provider-choice records independently of their execution permission."""
import math
from audit_goal_evidence import identity


def audit_candidate_decision(record, *, capture_id, candidates=None):
    request_id = identity(record["requestID"])
    assert isinstance(record["reason"], str) and record["reason"].strip()
    assert type(record["accepted"]) is bool
    options = record["optionIDs"]
    assert isinstance(options, list) and all(isinstance(option, str) for option in options)
    assert isinstance(record["provider"], str) and record["provider"].strip()
    identity(record["captureID"])
    if record.get("originalAccepted") is not None:
        assert type(record["originalAccepted"]) is bool
    if not record["accepted"]:
        # Raw rejected metadata is not the local request authority. The event
        # auditor binds it to the current capture and requires a refusal.
        if candidates is not None:
            assert all(identity(c["captureID"]) == identity(capture_id) for c in candidates)
        return {"requestID": request_id, "accepted": False, "options": len(options)}
    assert identity(record["captureID"]) == identity(capture_id), "Provider decision used another capture"
    assert record["provider"] == "jev", "Unknown candidate provider"
    assert isinstance(options, list) and "abstain" in options
    assert len(options) == len(set(options)) and len(options) >= 2, "Invalid provider option table"
    normalized = [identity(option) for option in options if option != "abstain"]
    assert len(normalized) == len(set(normalized)), "Duplicate logical provider options"
    if candidates is not None:
        assert all(identity(c["captureID"]) == identity(capture_id) for c in candidates)
        expected = {identity(c["id"]) for c in candidates if c["isSafeForAutomaticExecution"]}
        assert set(normalized) == expected, "Provider options differ from locally safe candidates"
    if record["accepted"]:
        assert not record.get("invalidNumericValues"), "Sanitized invalid provider numbers were accepted"
        if record.get("responseCaptureID") is not None:
            assert identity(record["responseCaptureID"]) == identity(capture_id), "Stale provider response was accepted"
        selected = record.get("selectedID")
        assert selected in options and selected != "abstain", "Abstained or unknown provider choice accepted"
        confidence = record.get("confidence")
        assert type(confidence) in (int, float) and math.isfinite(confidence) and 0 <= confidence <= 1
        probabilities = record.get("probabilities")
        assert isinstance(probabilities, dict) and set(probabilities) == set(options), "Incomplete provider distribution"
        assert all(type(p) in (int, float) and math.isfinite(p) and 0 <= p <= 1 for p in probabilities.values())
        assert abs(sum(probabilities.values()) - 1) <= 0.001, "Provider probabilities do not sum to one"
        assert probabilities[selected] == max(probabilities.values()), "Provider selection contradicts distribution"
        assert sum(p == probabilities[selected] for p in probabilities.values()) == 1, "Tied provider choice was accepted"
    # Refused responses may contain unknown IDs or malformed distributions. They
    # are retained as evidence; they must never become execution permission.
    return {"requestID": request_id, "accepted": record["accepted"], "options": len(options)}
