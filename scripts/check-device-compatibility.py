#!/usr/bin/env python3
"""Check a mounted reader identity against a generated compatibility manifest."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def read_identity(path: Path) -> tuple[str, str]:
    try:
        fields = path.read_text(encoding="utf-8").splitlines()[0].split(",")
    except (OSError, IndexError) as error:
        raise ValueError(f"could not read reader identity: {error}") from error
    if len(fields) < 4:
        raise ValueError("reader version file is malformed")
    firmware = fields[2].strip()
    hardware_id = fields[-1].strip().rsplit("-", 1)[-1].lstrip("0") or "0"
    if not firmware or not hardware_id.isdigit():
        raise ValueError("reader firmware or hardware id is invalid")
    return firmware, hardware_id


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("version_file", type=Path)
    args = parser.parse_args()
    try:
        document = json.loads(args.manifest.read_text(encoding="utf-8"))
        if document.get("schema_version") != 1 or not isinstance(document.get("devices"), list):
            raise ValueError("compatibility manifest has an unsupported schema")
        firmware, hardware_id = read_identity(args.version_file)
        matches = []
        for device in document["devices"]:
            for target in device.get("targets", []):
                normalized_ids = [(value.lstrip("0") or "0") for value in target.get("hardware_ids", [])]
                if target.get("firmware") == firmware and hardware_id in normalized_ids:
                    matches.append((device, target))
        if len(matches) != 1:
            print(
                f"BokOPDS has no active profile for hardware {hardware_id} "
                f"running firmware {firmware}; installation was not staged",
                file=sys.stderr,
            )
            return 1
        device, target = matches[0]
        if not target.get("enabled") or target.get("state") in ("known-issue", "not-available"):
            print(
                f"BokOPDS profile {target.get('id', 'unknown')} is disabled; "
                "installation was not staged",
                file=sys.stderr,
            )
            return 1
        print(
            f"compatible target: {device['name']}, hardware {hardware_id}, "
            f"firmware {firmware} ({target['state_label']})"
        )
        if target.get("state") == "untested":
            print(
                "WARNING: this exact model and firmware have not been physically tested; "
                "please report the result",
                file=sys.stderr,
            )
        return 0
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"compatibility check failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
