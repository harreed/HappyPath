"""Independent artifact checks shared by the Phase 3 run auditor.

Perception event dates use durable v2 milliseconds since 1970. Raw companion
captures use Swift's reference-date seconds. The retained 3A probe also uses
reference-date seconds and must explicitly select that encoding.
"""
import hashlib
import math
import struct
import uuid


def timestamp(value, encoding):
    assert type(value) in (int, float) and math.isfinite(value), "Invalid timestamp"
    if encoding == "millisecondsSince1970":
        return value / 1000
    assert encoding == "secondsSince2001", "Unknown date encoding"
    return value + 978307200


def capture_id(value):
    return str(uuid.UUID(value["rawValue"]))


def audit_capture_provenance(event_capture, raw_capture):
    """Compare a durable v2 provenance event to the original companion file."""
    event = dict(event_capture)
    original = dict(raw_capture)
    event_snapshot = dict(event.pop("snapshot"))
    original_snapshot = dict(original.pop("snapshot"))
    event_time = timestamp(event_snapshot.pop("capturedAt"), "millisecondsSince1970")
    original_time = timestamp(original_snapshot.pop("capturedAt"), "secondsSince2001")
    assert abs(event_time - original_time) < 0.00001, "Capture event retimestamped"
    assert event_snapshot == original_snapshot, "Capture event snapshot differs from raw source"
    intervals = []
    for key in ("screenshotCompletedAt", "semanticStartedAt", "semanticCompletedAt"):
        a, b = event.pop(key, None), original.pop(key, None)
        assert (a is None) == (b is None), "Capture timing field invented or omitted"
        if a is not None:
            seconds = timestamp(a, "millisecondsSince1970")
            assert abs(seconds - timestamp(b, "secondsSince2001")) < 0.00001, "Capture timing field changed"
            intervals.append(seconds)
    assert event == original, "Capture event metadata differs from raw source"
    if intervals:
        assert len(intervals) == 3, "Incomplete capture timing provenance"
        assert [original_time] + intervals == sorted([original_time] + intervals), "Invalid capture timing order"
    return bool(intervals)


def audit_perception(record, raw_capture, png, *, encoding="millisecondsSince1970"):
    """Check immutable source provenance; this does not authorize an action."""
    assert capture_id(record["captureID"]) == capture_id(raw_capture["snapshot"]["captureID"]), "Capture mismatch"
    assert png[:8] == b"\x89PNG\r\n\x1a\n", "Invalid PNG"
    width, height = struct.unpack(">II", png[16:24])
    assert width > 0 and height > 0
    assert (width, height) == (raw_capture["pixelWidth"], raw_capture["pixelHeight"]), "Raw dimensions mismatch"
    assert record["geometry"]["pixels"] == {"width": width, "height": height}, "OCR dimensions mismatch"
    assert record["geometry"]["screenFrame"] == raw_capture["screenFrame"], "Transform mismatch"
    frame = raw_capture["screenFrame"]
    assert all(type(frame[k]) in (int, float) and math.isfinite(frame[k]) for k in ("x", "y", "width", "height"))
    assert frame["width"] > 0 and frame["height"] > 0
    assert hashlib.sha256(png).hexdigest() == record["imageSHA256"], "OCR image hash mismatch"
    acquired = timestamp(raw_capture["snapshot"]["capturedAt"], "secondsSince2001")
    started = timestamp(record["screenshotStartedAt"], encoding)
    assert abs(acquired - started) < 0.00001, "Screenshot retimestamped"
    recognition_start = timestamp(record["recognitionStartedAt"], encoding)
    recognition_end = timestamp(record["recognitionCompletedAt"], encoding)
    assert started <= recognition_start <= recognition_end, "Invalid recognition interval"
    elapsed = record["recognitionMilliseconds"]
    assert type(elapsed) in (int, float) and math.isfinite(elapsed) and elapsed >= 0
    assert record["provider"] == "apple.vision.ocr", "Unreviewed OCR provider"
    times = [raw_capture.get(k) for k in ("screenshotCompletedAt", "semanticStartedAt", "semanticCompletedAt")]
    provenance_known = any(t is not None for t in times)
    if provenance_known:
        assert all(t is not None for t in times), "Partial capture timing provenance"
        pixel_end, semantic_start, semantic_end = [timestamp(t, "secondsSince2001") for t in times]
        assert acquired <= pixel_end <= semantic_start <= semantic_end <= recognition_start, "Capture timing inconsistent with recognition"
    for region in record["regions"]:
        assert isinstance(region["text"], str) and region["text"].strip()
        confidence = region["confidence"]
        assert type(confidence) in (int, float) and math.isfinite(confidence) and 0 <= confidence <= 1
        box = region["pixelBox"]
        assert all(type(box[k]) in (int, float) and math.isfinite(box[k]) for k in ("x", "y", "width", "height"))
        assert box["x"] >= 0 and box["y"] >= 0 and box["width"] > 0 and box["height"] > 0
        assert box["x"] + box["width"] <= width and box["y"] + box["height"] <= height
    return {"captureID": capture_id(record["captureID"]), "regions": len(record["regions"]),
            "captureTimingKnown": provenance_known, "recognitionMilliseconds": elapsed,
            "ageAtRecognitionEndSeconds": recognition_end - acquired}
