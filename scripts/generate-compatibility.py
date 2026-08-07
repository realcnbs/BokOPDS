#!/usr/bin/env python3
"""Validate compatibility data and generate public/build representations."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEVICES_PATH = ROOT / "compatibility" / "devices.json"
PROFILES_PATH = ROOT / "compatibility" / "hook-profiles.json"
REPORTS_PATH = ROOT / "compatibility" / "reports.json"
PUBLIC_JSON_PATH = ROOT / "compatibility.json"
PUBLIC_MARKDOWN_PATH = ROOT / "COMPATIBILITY.md"
HEADER_PATH = ROOT / "device-hook" / "generated" / "compatibility_profiles.h"
IDENTIFIER = re.compile(r"^[a-z0-9][a-z0-9.-]*$")
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
SYMBOL_KEYS = (
    "main_nav_constructor",
    "main_nav_set_pixmap",
    "main_nav_set_active_pixmap",
    "main_nav_set_text",
    "library_refresh_shared_instance",
    "library_refresh_sync",
)


def load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read {path.relative_to(ROOT)}: {error}") from error
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise ValueError(f"{path.relative_to(ROOT)} must use schema_version 1")
    return value


def require_identifier(value: object, label: str) -> str:
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
        raise ValueError(f"{label} is not a valid stable identifier")
    return value


def require_string_list(value: object, label: str, allow_empty: bool = False) -> list[str]:
    if not isinstance(value, list) or (not value and not allow_empty):
        raise ValueError(f"{label} must be a {'possibly empty ' if allow_empty else ''}list")
    result: list[str] = []
    for item in value:
        if not isinstance(item, str) or not item or item in result:
            raise ValueError(f"{label} contains an invalid or duplicate value")
        result.append(item)
    return result


def cpp_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def runtime_version() -> str:
    lock = (ROOT / "reader-shell" / "runtime.lock").read_text(encoding="utf-8")
    match = re.search(r"^RUNTIME_VERSION=([^\n]+)$", lock, re.MULTILINE)
    if not match:
        raise ValueError("reader-shell/runtime.lock has no RUNTIME_VERSION")
    return match.group(1)


def validate() -> tuple[dict, dict, dict, dict[str, dict], dict[str, dict], dict[str, list[dict]]]:
    devices_doc = load_json(DEVICES_PATH)
    profiles_doc = load_json(PROFILES_PATH)
    reports_doc = load_json(REPORTS_PATH)
    if devices_doc.get("runtime_version") != runtime_version():
        raise ValueError("devices.json runtime_version does not match runtime.lock")

    devices: dict[str, dict] = {}
    runtime_models: set[str] = set()
    for index, device in enumerate(devices_doc.get("devices", [])):
        if not isinstance(device, dict):
            raise ValueError(f"devices[{index}] must be an object")
        device_id = require_identifier(device.get("id"), f"devices[{index}].id")
        if device_id in devices:
            raise ValueError(f"duplicate device id {device_id}")
        if not isinstance(device.get("name"), str) or not device["name"].strip():
            raise ValueError(f"device {device_id} has no name")
        require_string_list(device.get("codenames"), f"device {device_id} codenames")
        hardware_ids = require_string_list(
            device.get("hardware_ids"), f"device {device_id} hardware_ids", allow_empty=True
        )
        if any(not item.isdigit() for item in hardware_ids):
            raise ValueError(f"device {device_id} has a non-numeric hardware id")
        runtime_model = device.get("runtime_model")
        if not isinstance(runtime_model, str) or not runtime_model.startswith("Kobo_"):
            raise ValueError(f"device {device_id} has an invalid runtime_model")
        if runtime_model in runtime_models:
            raise ValueError(f"duplicate runtime_model {runtime_model}")
        runtime_models.add(runtime_model)
        devices[device_id] = device
    if not devices:
        raise ValueError("devices.json contains no devices")

    abi_profiles: dict[str, dict] = {}
    for index, profile in enumerate(profiles_doc.get("abi_profiles", [])):
        if not isinstance(profile, dict):
            raise ValueError(f"abi_profiles[{index}] must be an object")
        profile_id = require_identifier(profile.get("id"), f"abi_profiles[{index}].id")
        if profile_id in abi_profiles:
            raise ValueError(f"duplicate ABI profile id {profile_id}")
        size = profile.get("widget_storage_bytes")
        if not isinstance(size, int) or size < 128 or size > 4096 or size % 8:
            raise ValueError(f"ABI profile {profile_id} has an unsafe widget size")
        symbols = profile.get("symbols")
        if not isinstance(symbols, dict) or set(symbols) != set(SYMBOL_KEYS):
            raise ValueError(f"ABI profile {profile_id} has an incomplete symbol set")
        if any(not isinstance(symbols[key], str) or not symbols[key].startswith("_Z") for key in SYMBOL_KEYS):
            raise ValueError(f"ABI profile {profile_id} has an invalid C++ symbol")
        abi_profiles[profile_id] = profile
    if not abi_profiles:
        raise ValueError("hook-profiles.json contains no ABI profiles")

    targets: dict[str, dict] = {}
    pairs: set[tuple[str, str]] = set()
    for index, target in enumerate(profiles_doc.get("targets", [])):
        if not isinstance(target, dict):
            raise ValueError(f"targets[{index}] must be an object")
        target_id = require_identifier(target.get("id"), f"targets[{index}].id")
        if target_id in targets:
            raise ValueError(f"duplicate target id {target_id}")
        device_id = target.get("device_id")
        if device_id not in devices:
            raise ValueError(f"target {target_id} references unknown device {device_id}")
        profile_id = target.get("abi_profile")
        if profile_id not in abi_profiles:
            raise ValueError(f"target {target_id} references unknown ABI profile {profile_id}")
        firmware = target.get("firmware")
        if not isinstance(firmware, str) or not VERSION.fullmatch(firmware):
            raise ValueError(f"target {target_id} has an invalid firmware version")
        hardware_ids = require_string_list(target.get("hardware_ids"), f"target {target_id} hardware_ids")
        if any(not item.isdigit() for item in hardware_ids):
            raise ValueError(f"target {target_id} has a non-numeric hardware id")
        for hardware_id in hardware_ids:
            pair = (hardware_id.lstrip("0") or "0", firmware)
            if pair in pairs:
                raise ValueError(f"duplicate active hardware/firmware pair {pair[0]} {pair[1]}")
            pairs.add(pair)
        if not isinstance(target.get("enabled"), bool):
            raise ValueError(f"target {target_id} must declare enabled as a boolean")
        targets[target_id] = target
    if not targets:
        raise ValueError("hook-profiles.json contains no targets")

    reports_by_target: dict[str, list[dict]] = {target_id: [] for target_id in targets}
    report_ids: set[str] = set()
    for index, report in enumerate(reports_doc.get("reports", [])):
        if not isinstance(report, dict):
            raise ValueError(f"reports[{index}] must be an object")
        report_id = require_identifier(report.get("id"), f"reports[{index}].id")
        if report_id in report_ids:
            raise ValueError(f"duplicate report id {report_id}")
        report_ids.add(report_id)
        target_id = report.get("target_id")
        if target_id not in targets:
            raise ValueError(f"report {report_id} references unknown target {target_id}")
        if report.get("kind") not in ("maintainer", "community"):
            raise ValueError(f"report {report_id} has an invalid kind")
        if report.get("result") not in ("passed", "failed"):
            raise ValueError(f"report {report_id} has an invalid result")
        if not isinstance(report.get("bokopds_version"), str) or not VERSION.fullmatch(report["bokopds_version"]):
            raise ValueError(f"report {report_id} has an invalid BokOPDS version")
        if not isinstance(report.get("tested_on"), str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", report["tested_on"]):
            raise ValueError(f"report {report_id} has an invalid date")
        if report.get("evidence_url") is not None and not str(report["evidence_url"]).startswith("https://"):
            raise ValueError(f"report {report_id} has an invalid evidence URL")
        reports_by_target[target_id].append(report)

    for target_id, target_reports in reports_by_target.items():
        if any(report["result"] == "failed" for report in target_reports) and targets[target_id]["enabled"]:
            raise ValueError(f"known-failing target {target_id} must be disabled")
    return devices_doc, profiles_doc, reports_doc, devices, abi_profiles, reports_by_target


def target_state(target: dict, reports: list[dict]) -> tuple[str, str]:
    if any(report["result"] == "failed" for report in reports):
        return "known-issue", "Known issue"
    passed = [report for report in reports if report["result"] == "passed"]
    if any(report["kind"] == "maintainer" for report in passed):
        return "device-tested", "Device tested"
    community_count = sum(report["kind"] == "community" for report in passed)
    if community_count:
        return "community-tested", f"Community tested ({community_count})"
    if target["enabled"]:
        return "untested", "Untested"
    return "not-available", "Not available"


def public_document(devices_doc: dict, profiles_doc: dict, devices: dict[str, dict], reports: dict[str, list[dict]]) -> dict:
    targets_by_device: dict[str, list[dict]] = {device_id: [] for device_id in devices}
    for target in profiles_doc["targets"]:
        state, state_label = target_state(target, reports[target["id"]])
        passed = [item for item in reports[target["id"]] if item["result"] == "passed"]
        targets_by_device[target["device_id"]].append({
            "id": target["id"],
            "hardware_ids": target["hardware_ids"],
            "firmware": target["firmware"],
            "state": state,
            "state_label": state_label,
            "enabled": target["enabled"],
            "report_count": len(passed),
            "last_tested_version": max((item["bokopds_version"] for item in passed), default=None),
            "last_tested_on": max((item["tested_on"] for item in passed), default=None),
            "evidence_urls": [item["evidence_url"] for item in passed if item.get("evidence_url")],
        })
    public_devices = []
    for device in devices_doc["devices"]:
        entries = sorted(targets_by_device[device["id"]], key=lambda item: item["firmware"])
        public_devices.append({
            "id": device["id"],
            "name": device["name"],
            "codenames": device["codenames"],
            "hardware_ids": device["hardware_ids"],
            "runtime_model": device["runtime_model"],
            "runtime_recognized": True,
            "targets": entries,
        })
    return {
        "schema_version": 1,
        "runtime_version": devices_doc["runtime_version"],
        "report_url": "https://github.com/realcnbs/BokOPDS/issues/new?template=compatibility-report.yml",
        "states": {
            "device-tested": "The maintainer completed the full device checklist.",
            "community-tested": "A user completed the checklist and the report was reviewed.",
            "untested": "Support is prepared, but no complete device report is available yet.",
            "not-available": "BokOPDS is not available for this model and firmware.",
            "known-issue": "A reported problem currently prevents support."
        },
        "devices": public_devices,
    }


def render_markdown(document: dict) -> str:
    lines = [
        "# Device compatibility",
        "",
        "Install BokOPDS only when your exact model and firmware are marked",
        "**Device tested** or **Community tested**. Other combinations are not ready",
        "for ordinary installation.",
        "",
        "| Device | Firmware | Status | Last tested |",
        "|---|---|---|---|",
    ]
    for device in document["devices"]:
        if device["targets"]:
            for index, target in enumerate(device["targets"]):
                lines.append("| {name} | `{firmware}` | {state} | {last} |".format(
                    name=device["name"] if index == 0 else "↳ same device",
                    firmware=target["firmware"],
                    state=target["state_label"],
                    last=(f"{target['last_tested_on']} / {target['last_tested_version']}" if target["last_tested_on"] else "—"),
                ))
        else:
            lines.append(f"| {device['name']} | — | Not available | — |")
    lines.extend([
        "",
        "## State meanings",
        "",
        "- **Device tested:** the maintainer completed the full device checklist.",
        "- **Community tested:** a user completed the checklist and the report was reviewed.",
        "- **Untested:** support is prepared, but no complete device report is available yet.",
        "- **Not available:** BokOPDS is not available for this model and firmware.",
        "- **Known issue:** a reported problem currently prevents support.",
        "",
        "## Help test a device",
        "",
        "If your exact combination is marked **Untested**, complete the",
        "[device checklist](docs/DEVICE_TESTING.md) and then",
        "[open a compatibility report](https://github.com/realcnbs/BokOPDS/issues/new?template=compatibility-report.yml).",
        "Do not post the device serial number, catalog credentials, private catalog addresses, or other personal information.",
        "",
    ])
    return "\n".join(lines)


def render_header(profiles_doc: dict, reports: dict[str, list[dict]]) -> str:
    lines = [
        "// Generated by scripts/generate-compatibility.py. Do not edit.",
        "#ifndef BOKOPDS_GENERATED_COMPATIBILITY_PROFILES_H",
        "#define BOKOPDS_GENERATED_COMPATIBILITY_PROFILES_H",
        "",
        "struct BokOPDSAbiProfile {",
        "    const char* id;",
        "    std::size_t widget_storage_bytes;",
        "    void (*main_nav_construct)(MainNavButton*, QWidget*);",
        "    void (*main_nav_set_pixmap)(MainNavButton*, const QString&);",
        "    void (*main_nav_set_active_pixmap)(MainNavButton*, const QString&);",
        "    void (*main_nav_set_text)(MainNavButton*, const QString&);",
        "    PlugWorkflowManager* (*library_refresh_shared_instance)();",
        "    void (*library_refresh_sync)(PlugWorkflowManager*);",
        "};",
        "",
        "struct BokOPDSCompatibilityTarget {",
        "    const char* id;",
        "    const char* device_id;",
        "    const char* firmware;",
        "    const char* state;",
        "    const char* const* hardware_ids;",
        "    std::size_t hardware_id_count;",
        "    bool enabled;",
        "    BokOPDSAbiProfile* abi;",
        "};",
        "",
    ]
    for index, profile in enumerate(profiles_doc["abi_profiles"]):
        prefix = f"BokOPDSAbi{index}"
        lines.extend([
            f"static void (*{prefix}Construct)(MainNavButton*, QWidget*) = nullptr;",
            f"static void (*{prefix}SetPixmap)(MainNavButton*, const QString&) = nullptr;",
            f"static void (*{prefix}SetActivePixmap)(MainNavButton*, const QString&) = nullptr;",
            f"static void (*{prefix}SetText)(MainNavButton*, const QString&) = nullptr;",
            f"static PlugWorkflowManager* (*{prefix}RefreshSharedInstance)() = nullptr;",
            f"static void (*{prefix}RefreshSync)(PlugWorkflowManager*) = nullptr;",
            "",
        ])
    lines.append("static BokOPDSAbiProfile BokOPDSAbiProfiles[] = {")
    for index, profile in enumerate(profiles_doc["abi_profiles"]):
        prefix = f"BokOPDSAbi{index}"
        lines.append(
            "    {%s, %d, %sConstruct, %sSetPixmap, %sSetActivePixmap, %sSetText, %sRefreshSharedInstance, %sRefreshSync},"
            % (cpp_string(profile["id"]), profile["widget_storage_bytes"], prefix, prefix, prefix, prefix, prefix, prefix)
        )
    lines.extend(["};", ""])
    abi_index = {profile["id"]: index for index, profile in enumerate(profiles_doc["abi_profiles"])}
    for index, target in enumerate(profiles_doc["targets"]):
        values = ", ".join(cpp_string(value) for value in target["hardware_ids"])
        lines.append(f"static const char* const BokOPDSTarget{index}HardwareIds[] = {{{values}}};")
    lines.extend(["", "static BokOPDSCompatibilityTarget BokOPDSTargets[] = {"])
    for index, target in enumerate(profiles_doc["targets"]):
        state, _ = target_state(target, reports[target["id"]])
        lines.append(
            "    {%s, %s, %s, %s, BokOPDSTarget%dHardwareIds, %d, %s, &BokOPDSAbiProfiles[%d]},"
            % (
                cpp_string(target["id"]), cpp_string(target["device_id"]), cpp_string(target["firmware"]),
                cpp_string(state), index, len(target["hardware_ids"]),
                "true" if target["enabled"] else "false", abi_index[target["abi_profile"]],
            )
        )
    lines.extend([
        "};",
        "static const std::size_t BokOPDSTargetCount = sizeof(BokOPDSTargets) / sizeof(BokOPDSTargets[0]);",
        "",
        "static void BokOPDSRefreshResolvedSymbols() {",
    ])
    for index, _ in enumerate(profiles_doc["abi_profiles"]):
        prefix = f"BokOPDSAbi{index}"
        lines.extend([
            f"    BokOPDSAbiProfiles[{index}].main_nav_construct = {prefix}Construct;",
            f"    BokOPDSAbiProfiles[{index}].main_nav_set_pixmap = {prefix}SetPixmap;",
            f"    BokOPDSAbiProfiles[{index}].main_nav_set_active_pixmap = {prefix}SetActivePixmap;",
            f"    BokOPDSAbiProfiles[{index}].main_nav_set_text = {prefix}SetText;",
            f"    BokOPDSAbiProfiles[{index}].library_refresh_shared_instance = {prefix}RefreshSharedInstance;",
            f"    BokOPDSAbiProfiles[{index}].library_refresh_sync = {prefix}RefreshSync;",
        ])
    lines.extend([
        "}",
        "",
        "static struct nh_dlsym BokOPDSSymbols[] = {",
    ])
    field_names = {
        "main_nav_constructor": "Construct",
        "main_nav_set_pixmap": "SetPixmap",
        "main_nav_set_active_pixmap": "SetActivePixmap",
        "main_nav_set_text": "SetText",
        "library_refresh_shared_instance": "RefreshSharedInstance",
        "library_refresh_sync": "RefreshSync",
    }
    descriptions = {
        "main_nav_constructor": "main navigation button constructor",
        "main_nav_set_pixmap": "main navigation icon setter",
        "main_nav_set_active_pixmap": "active main navigation icon setter",
        "main_nav_set_text": "main navigation label setter",
        "library_refresh_shared_instance": "library refresh manager",
        "library_refresh_sync": "library refresh action",
    }
    for index, profile in enumerate(profiles_doc["abi_profiles"]):
        for key in SYMBOL_KEYS:
            lines.append(
                "    {.name = %s, .out = nh_symoutptr(BokOPDSAbi%d%s), .desc = %s, .optional = true},"
                % (cpp_string(profile["symbols"][key]), index, field_names[key], cpp_string(descriptions[key]))
            )
    lines.extend(["    {0},", "};", "", "#endif", ""])
    return "\n".join(lines)


def write_or_check(path: Path, content: str, check: bool) -> bool:
    if check:
        if not path.exists() or path.read_text(encoding="utf-8") != content:
            print(f"generated file is stale: {path.relative_to(ROOT)}", file=sys.stderr)
            return False
        return True
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if generated files are stale")
    parser.add_argument("--runtime-device-lua", type=Path,
                        help="also verify the generated catalog against KOReader device.lua")
    args = parser.parse_args()
    try:
        devices_doc, profiles_doc, _, devices, _, reports = validate()
        if args.runtime_device_lua:
            source = args.runtime_device_lua.read_text(encoding="utf-8")
            actual_models = set(re.findall(r'^\s*model\s*=\s*"(Kobo_[^"]+)"', source, re.MULTILINE))
            expected_models = {device["runtime_model"] for device in devices.values()}
            if actual_models != expected_models:
                missing = sorted(actual_models - expected_models)
                stale = sorted(expected_models - actual_models)
                raise ValueError(
                    "device catalog differs from pinned KOReader runtime "
                    f"(missing={missing}, stale={stale})"
                )
        public = public_document(devices_doc, profiles_doc, devices, reports)
        outputs = (
            (PUBLIC_JSON_PATH, json.dumps(public, ensure_ascii=False, indent=2, sort_keys=True) + "\n"),
            (PUBLIC_MARKDOWN_PATH, render_markdown(public)),
            (HEADER_PATH, render_header(profiles_doc, reports)),
        )
        return 0 if all(write_or_check(path, content, args.check) for path, content in outputs) else 1
    except ValueError as error:
        print(f"compatibility data error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
