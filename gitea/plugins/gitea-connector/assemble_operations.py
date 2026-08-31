#!/usr/bin/env python3
"""Assemble and verify the canonical Gitea operation catalog."""

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PARTS_DIR = ROOT / "operations.parts"
TARGET = ROOT / "operations.json"
EXPECTED_PARTS = 39
EXPECTED_SIZE = 417210
EXPECTED_GIT_BLOB_SHA = "a224689f8e90d0c7b1a6e284be3bd99c85e51594"
EXPECTED_OPERATION_COUNT = 221


def main() -> None:
    parts = sorted(PARTS_DIR.glob("*.part"))
    if len(parts) != EXPECTED_PARTS:
        raise SystemExit(
            f"operations catalog is incomplete: expected {EXPECTED_PARTS} parts, found {len(parts)}"
        )

    data = b"".join(part.read_bytes() for part in parts)
    if len(data) != EXPECTED_SIZE:
        raise SystemExit(
            f"operations catalog size mismatch: expected {EXPECTED_SIZE}, got {len(data)}"
        )

    git_blob_sha = hashlib.sha1(
        b"blob " + str(len(data)).encode("ascii") + b"\0" + data
    ).hexdigest()
    if git_blob_sha != EXPECTED_GIT_BLOB_SHA:
        raise SystemExit(
            "operations catalog checksum mismatch: "
            f"expected {EXPECTED_GIT_BLOB_SHA}, got {git_blob_sha}"
        )

    try:
        catalog = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SystemExit(f"operations catalog is not valid UTF-8 JSON: {exc}") from exc

    if catalog.get("operationCount") != EXPECTED_OPERATION_COUNT:
        raise SystemExit(
            "operations catalog operationCount mismatch: "
            f"expected {EXPECTED_OPERATION_COUNT}, got {catalog.get('operationCount')!r}"
        )

    operations = catalog.get("operations")
    if not isinstance(operations, dict) or len(operations) != EXPECTED_OPERATION_COUNT:
        count = len(operations) if isinstance(operations, dict) else None
        raise SystemExit(
            "operations catalog operations mismatch: "
            f"expected {EXPECTED_OPERATION_COUNT}, got {count!r}"
        )

    TARGET.write_bytes(data)
    print(
        f"operations.json assembled: {len(data)} bytes; "
        f"git blob {git_blob_sha}; operations {len(operations)}"
    )


if __name__ == "__main__":
    main()
