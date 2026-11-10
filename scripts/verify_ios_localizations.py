#!/usr/bin/env python3
"""Verify iPhone extraction parity and release localization coverage."""

from __future__ import annotations

from collections import Counter
import json
import pathlib
import plistlib
import re
import sys
from typing import Any


if len(sys.argv) != 2:
    raise SystemExit("Usage: scripts/verify_ios_localizations.py DERIVED_DATA_PATH")

ROOT = pathlib.Path(__file__).resolve().parents[1]
DERIVED_DATA = pathlib.Path(sys.argv[1])
RESOURCES = ROOT / "MileageTracker/Resources"
LOCALIZABLE_PATH = RESOURCES / "Localizable.xcstrings"
SHORTCUTS_PATH = RESOURCES / "AppShortcuts.xcstrings"
INFO_PLIST_PATH = RESOURCES / "InfoPlist.xcstrings"
APPCORE_LOCALIZABLE_PATH = (
    ROOT / "AppCorePackage/Sources/AppCoreModels/Resources/Localizable.xcstrings"
)
# Recursive root: AppCore is being split into multiple package targets, and
# moved files must never silently exit this script's coverage.
APPCORE_SOURCE_ROOT = ROOT / "AppCorePackage/Sources"
PROJECT_PATH = ROOT / "project.yml"
DRIVE_CAPTURE_RUNTIME_PATH = (
    ROOT / "AppCorePackage/Sources/AppCore/DriveCaptureRuntime.swift"
)
MILEAGE_RATE_SCHEDULE_PATH = (
    ROOT / "AppCorePackage/Sources/AppCoreModels/MileageRateSchedule.swift"
)
LEGAL_VIEW_PATH = ROOT / "MileageTracker/Views/LegalView.swift"
TARGET_LANGUAGES = ("de", "es", "fr")

PRINTF_PLACEHOLDER = re.compile(
    r"%(?!%)(?:\d+\$)?[-+ #0']*\d*(?:\.\d+)?"
    r"(?:hh|h|ll|l|L|z|j|t)?[@diuoxXfFeEgGaAcCsSp]"
)
NAMED_PLACEHOLDER = re.compile(r"\$\{[^}]+\}")
PUBLIC_LOCALIZED_ERROR_ENUM = re.compile(
    r"\bpublic\s+enum\s+(?P<name>\w+)[^{]*\bLocalizedError\b[^{]*\{"
)
ERROR_DESCRIPTION_PROPERTY = re.compile(
    r"\bpublic\s+var\s+errorDescription\s*:\s*String\?\s*\{"
)
# `.module` is per-target; a call site that uses it directly stops resolving
# the shared catalog the moment its file moves to another package target.
FORBIDDEN_MODULE_BUNDLE = re.compile(r"bundle\s*:\s*\.module\b")


def load_catalog(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def normalize_printf(token: str) -> str:
    return re.sub(r"^%(\d+)\$", "%", token)


def placeholders(value: str) -> Counter[str]:
    tokens = [normalize_printf(match.group()) for match in PRINTF_PLACEHOLDER.finditer(value)]
    tokens.extend(match.group() for match in NAMED_PLACEHOLDER.finditer(value))
    return Counter(tokens)


def string_units(node: Any, path: tuple[str, ...] = ()) -> dict[tuple[str, ...], dict[str, Any]]:
    if not isinstance(node, dict):
        return {}
    units: dict[tuple[str, ...], dict[str, Any]] = {}
    unit = node.get("stringUnit")
    if isinstance(unit, dict):
        units[path] = unit
    for key, value in node.items():
        if key == "stringUnit":
            continue
        if isinstance(value, dict):
            units.update(string_units(value, path + (key,)))
    return units


def matching_brace(source: str, opening_brace: int) -> int | None:
    depth = 0
    for index in range(opening_brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    return None


def translated_units(
    *,
    catalog_name: str,
    key: str,
    entry: dict[str, Any],
    language: str,
    errors: list[str],
) -> dict[tuple[str, ...], dict[str, Any]]:
    localization = entry.get("localizations", {}).get(language)
    if not isinstance(localization, dict):
        errors.append(f"{catalog_name}: {key!r} is missing {language}")
        return {}
    units = string_units(localization)
    if not units:
        errors.append(f"{catalog_name}: {key!r} has no {language} string units")
        return {}
    for unit_path, unit in units.items():
        if unit.get("state") != "translated":
            rendered_path = ".".join(unit_path) or "stringUnit"
            errors.append(
                f"{catalog_name}: {key!r} {language}.{rendered_path} "
                f"state is {unit.get('state')!r}, expected 'translated'"
            )
        if not isinstance(unit.get("value"), str) or not unit["value"]:
            errors.append(f"{catalog_name}: {key!r} has an empty {language} translation")
    return units


def current_target_artifacts() -> tuple[list[pathlib.Path], pathlib.Path]:
    output_maps = list(
        DERIVED_DATA.rglob(
            "MileageTracker.build/Objects-normal/*/MileageTracker-OutputFileMap.json"
        )
    )
    if not output_maps:
        raise SystemExit(
            f"No MileageTracker target output file map found under {DERIVED_DATA}"
        )
    incomplete_reasons: list[str] = []
    selected: tuple[pathlib.Path, list[pathlib.Path]] | None = None
    for output_map_path in sorted(
        output_maps, key=lambda path: path.stat().st_mtime_ns, reverse=True
    ):
        output_map = json.loads(output_map_path.read_text(encoding="utf-8"))
        swift_file_list = output_map_path.with_name("MileageTracker.SwiftFileList")
        if not swift_file_list.is_file():
            incomplete_reasons.append(f"{output_map_path}: missing SwiftFileList")
            continue

        current_sources = {
            pathlib.Path(line)
            for line in swift_file_list.read_text(encoding="utf-8").splitlines()
            if line
        }
        paths: list[pathlib.Path] = []
        missing: list[str] = []
        for source in current_sources:
            outputs = output_map.get(str(source))
            if not isinstance(outputs, dict) or not isinstance(outputs.get("object"), str):
                missing.append(f"output-map entry for {source}")
                continue
            stringsdata = pathlib.Path(outputs["object"]).with_suffix(".stringsdata")
            if not stringsdata.is_file():
                missing.append(str(stringsdata))
                continue
            paths.append(stringsdata)

        generated_shortcuts = (
            output_map_path.parent / "ExtractedAppShortcutsMetadata.stringsdata"
        )
        if not generated_shortcuts.is_file():
            missing.append(str(generated_shortcuts))
        else:
            paths.append(generated_shortcuts)
        if missing:
            incomplete_reasons.append(
                f"{output_map_path}: missing {len(missing)} current artifacts"
            )
            continue
        selected = (output_map_path, paths)
        break

    if selected is None:
        raise SystemExit(
            "No complete current MileageTracker extraction set found:\n"
            + "\n".join(incomplete_reasons)
        )
    output_map_path, paths = selected

    tables: dict[str, list[dict[str, Any]]] = {}
    for path in paths:
        data = json.loads(path.read_text(encoding="utf-8"))
        for table, items in data.get("tables", {}).items():
            tables.setdefault(table, []).extend(items)

    configuration = output_map_path.parents[3].name
    info_plist = (
        DERIVED_DATA
        / "Build/Products"
        / configuration
        / "MileageTracker.app/Info.plist"
    )
    if not info_plist.is_file():
        raise SystemExit(f"Missing built iPhone Info.plist: {info_plist}")
    return tables, info_plist


def verify_localizable(
    extracted: dict[str, list[dict[str, Any]]],
    errors: list[str],
) -> tuple[int, int]:
    entries = load_catalog(LOCALIZABLE_PATH).get("strings", {})
    active = {
        key: entry
        for key, entry in entries.items()
        if entry.get("extractionState") != "stale"
    }
    extracted_keys = {
        item["key"]
        for item in extracted.get("Localizable", [])
        if isinstance(item.get("key"), str)
    }

    for key in sorted(extracted_keys - active.keys()):
        errors.append(f"Localizable: extracted key is missing from catalog: {key!r}")
    for key in sorted(active.keys() - extracted_keys):
        errors.append(f"Localizable: active catalog key was not extracted: {key!r}")

    for key, entry in active.items():
        if entry.get("shouldTranslate") is False:
            continue
        english_units = string_units(entry.get("localizations", {}).get("en", {}))
        source_placeholders = placeholders(key)
        for language in TARGET_LANGUAGES:
            units = translated_units(
                catalog_name="Localizable",
                key=key,
                entry=entry,
                language=language,
                errors=errors,
            )
            for unit_path, unit in units.items():
                source_unit = english_units.get(unit_path)
                expected = placeholders(source_unit["value"]) if source_unit else source_placeholders
                actual = placeholders(unit.get("value", ""))
                if actual != expected:
                    errors.append(
                        f"Localizable: {key!r} {language}.{'.'.join(unit_path)} "
                        f"placeholders {dict(actual)} != {dict(expected)}"
                    )

    return len(extracted_keys), len(active)


def verify_shortcuts(
    extracted: dict[str, list[dict[str, Any]]],
    errors: list[str],
) -> tuple[int, int]:
    entries = load_catalog(SHORTCUTS_PATH).get("strings", {})
    active = {
        key: entry
        for key, entry in entries.items()
        if entry.get("extractionState") != "stale"
    }
    extracted_entries = {
        item["key"]: item
        for item in extracted.get("AppShortcuts", [])
        if isinstance(item.get("key"), str)
    }

    for key in sorted(extracted_entries.keys() - active.keys()):
        errors.append(f"AppShortcuts: extracted set is missing from catalog: {key!r}")
    for key in sorted(active.keys() - extracted_entries.keys()):
        errors.append(f"AppShortcuts: active catalog set was not extracted: {key!r}")

    phrase_total = 0
    for key, extracted_entry in extracted_entries.items():
        entry = active.get(key)
        if not entry:
            continue
        english_values = extracted_entry.get("values", [])
        phrase_total += len(english_values)
        catalog_english = (
            entry.get("localizations", {}).get("en", {}).get("stringSet", {}).get("values")
        )
        if catalog_english != english_values:
            errors.append(f"AppShortcuts: English phrases do not match extraction for {key!r}")

        for language in TARGET_LANGUAGES:
            string_set = (
                entry.get("localizations", {}).get(language, {}).get("stringSet", {})
            )
            if string_set.get("state") != "translated":
                errors.append(
                    f"AppShortcuts: {key!r} {language} set state is "
                    f"{string_set.get('state')!r}, expected 'translated'"
                )
            values = string_set.get("values", [])
            if len(values) != len(english_values):
                errors.append(
                    f"AppShortcuts: {key!r} {language} has {len(values)} phrases; "
                    f"expected {len(english_values)}"
                )
                continue
            for index, (source, translation) in enumerate(zip(english_values, values)):
                expected = placeholders(source)
                actual = placeholders(translation)
                if actual != expected:
                    errors.append(
                        f"AppShortcuts: {key!r} {language}[{index}] placeholders "
                        f"{dict(actual)} != {dict(expected)}"
                    )
    return len(extracted_entries), phrase_total


def verify_info_plist(info_plist_path: pathlib.Path, errors: list[str]) -> int:
    entries = load_catalog(INFO_PLIST_PATH).get("strings", {})
    active = {
        key: entry
        for key, entry in entries.items()
        if entry.get("extractionState") != "stale"
    }
    for key, entry in active.items():
        if entry.get("shouldTranslate") is False:
            continue
        for language in TARGET_LANGUAGES:
            translated_units(
                catalog_name="InfoPlist",
                key=key,
                entry=entry,
                language=language,
                errors=errors,
            )

    for proper_name in ("CFBundleDisplayName", "CFBundleName"):
        if active.get(proper_name, {}).get("shouldTranslate") is not False:
            errors.append(f"InfoPlist: {proper_name} must be marked shouldTranslate=false")

    with info_plist_path.open("rb") as file:
        built_info = plistlib.load(file)
    localizable_info_keys = {
        key
        for key, value in built_info.items()
        if isinstance(value, str)
        and (
            key in {"CFBundleDisplayName", "CFBundleName", "CFBundleSpokenName"}
            or key.endswith("UsageDescription")
        )
    }
    expected_direct_keys = set(active) - {
        "MILEAGER_ALTERNATIVE_APP_NAME_1",
        "MileageTripCapture",
    }
    for key in sorted(expected_direct_keys - localizable_info_keys):
        errors.append(f"InfoPlist: active catalog key is absent from built app: {key}")
    for key in sorted(localizable_info_keys - expected_direct_keys):
        errors.append(f"InfoPlist: built localizable key is absent from catalog: {key}")
    for key in sorted(expected_direct_keys & localizable_info_keys):
        english = (
            active[key].get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")
        )
        if english != built_info[key]:
            errors.append(
                f"InfoPlist: {key} English value {english!r} != "
                f"built value {built_info[key]!r}"
            )

    alternative_names = built_info.get("INAlternativeAppNames", [])
    alternative_tokens = {
        item.get("INAlternativeAppName")
        for item in alternative_names
        if isinstance(item, dict)
    }
    if "MILEAGER_ALTERNATIVE_APP_NAME_1" not in alternative_tokens:
        errors.append(
            "InfoPlist: built INAlternativeAppNames is missing "
            "MILEAGER_ALTERNATIVE_APP_NAME_1"
        )

    temporary_purposes = built_info.get(
        "NSLocationTemporaryUsageDescriptionDictionary", {}
    )
    english_temporary_purpose = (
        active.get("MileageTripCapture", {})
        .get("localizations", {})
        .get("en", {})
        .get("stringUnit", {})
        .get("value")
    )
    if temporary_purposes.get("MileageTripCapture") != english_temporary_purpose:
        errors.append(
            "InfoPlist: built MileageTripCapture purpose does not match "
            "the catalog English value"
        )
    if (
        "NSLocationTemporaryUsageDescriptionDictionary"
        not in PROJECT_PATH.read_text(encoding="utf-8")
    ):
        errors.append(
            "project.yml: full-accuracy purpose dictionary is required by "
            "DriveCaptureRuntime"
        )
    drive_capture_source = DRIVE_CAPTURE_RUNTIME_PATH.read_text(encoding="utf-8")
    if (
        'locationServiceSessionPurposeKey = "MileageTripCapture"'
        not in drive_capture_source
        or (
            "startAlways("
            "fullAccuracyPurposeKey: Self.locationServiceSessionPurposeKey"
        )
        not in drive_capture_source
    ):
        errors.append(
            "DriveCaptureRuntime: expected MileageTripCapture "
            "full-accuracy purpose key is missing"
        )
    return len(active)


def verify_appcore_localizable(errors: list[str]) -> int:
    entries = load_catalog(APPCORE_LOCALIZABLE_PATH).get("strings", {})
    active = {
        key: entry
        for key, entry in entries.items()
        if entry.get("extractionState") != "stale"
    }
    for key, entry in active.items():
        if entry.get("shouldTranslate") is False:
            continue
        english_units = string_units(entry.get("localizations", {}).get("en", {}))
        source_placeholders = placeholders(key)
        for language in TARGET_LANGUAGES:
            units = translated_units(
                catalog_name="AppCore Localizable",
                key=key,
                entry=entry,
                language=language,
                errors=errors,
            )
            for unit_path, unit in units.items():
                source_unit = english_units.get(unit_path)
                expected = (
                    placeholders(source_unit["value"])
                    if source_unit
                    else source_placeholders
                )
                actual = placeholders(unit.get("value", ""))
                if actual != expected:
                    errors.append(
                        f"AppCore Localizable: {key!r} "
                        f"{language}.{'.'.join(unit_path)} placeholders "
                        f"{dict(actual)} != {dict(expected)}"
                    )

    schedule_source = MILEAGE_RATE_SCHEDULE_PATH.read_text(encoding="utf-8")
    for key in (
        "Only one mileage rate can begin on the same date.",
        "Choose a valid effective date.",
        "The mileage rate no longer exists.",
    ):
        invocation = re.compile(
            r"String\s*\(\s*localized:\s*"
            + re.escape(json.dumps(key))
            + r"\s*,\s*bundle:\s*\.appCoreStrings\s*\)",
            re.DOTALL,
        )
        if not invocation.search(schedule_source):
            errors.append(
                "MileageRateSchedule: AppCore-localized error is missing "
                f"bundle: .appCoreStrings for {key!r}"
            )

    for source_path in sorted(APPCORE_SOURCE_ROOT.rglob("*.swift")):
        source = source_path.read_text(encoding="utf-8")
        if FORBIDDEN_MODULE_BUNDLE.search(source):
            errors.append(
                f"{source_path.name}: passes bundle: .module; AppCore strings "
                "must resolve through Bundle.appCoreStrings so files can move "
                "between package targets without orphaning catalog keys"
            )
        for enum_match in PUBLIC_LOCALIZED_ERROR_ENUM.finditer(source):
            enum_name = enum_match.group("name")
            enum_open = source.find("{", enum_match.start(), enum_match.end())
            enum_close = matching_brace(source, enum_open)
            if enum_close is None:
                errors.append(
                    f"{source_path.name}: could not inspect {enum_name} localization"
                )
                continue
            enum_body = source[enum_open + 1 : enum_close]
            property_match = ERROR_DESCRIPTION_PROPERTY.search(enum_body)
            if not property_match:
                errors.append(
                    f"{source_path.name}: {enum_name} is missing errorDescription"
                )
                continue
            property_open = enum_body.find(
                "{", property_match.start(), property_match.end()
            )
            property_close = matching_brace(enum_body, property_open)
            if property_close is None:
                errors.append(
                    f"{source_path.name}: could not inspect "
                    f"{enum_name}.errorDescription"
                )
                continue
            property_body = enum_body[property_open + 1 : property_close]
            for case_body in re.split(r"(?=\bcase\s+\.)", property_body):
                if not re.match(r"\bcase\s+\.", case_body):
                    continue
                case_name_match = re.match(r"\bcase\s+(\.[^:(\\s]+)", case_body)
                case_name = case_name_match.group(1) if case_name_match else "case"
                if re.match(
                    r"\bcase\s+\.[^\n]+:\s*(?:return\s+)?\"",
                    case_body,
                ):
                    errors.append(
                        f"{source_path.name}: {enum_name}{case_name} returns "
                        "an unlocalized error description"
                    )
                if (
                    "String(localized:" in case_body
                    or re.search(r"String\s*\(\s*localized:", case_body)
                ) and not re.search(r"bundle\s*:\s*\.appCoreStrings", case_body):
                    errors.append(
                        f"{source_path.name}: {enum_name}{case_name} must use "
                        "bundle: .appCoreStrings"
                    )
    return len(active)


def verify_english_only_legal_surface(errors: list[str]) -> int:
    source = LEGAL_VIEW_PATH.read_text(encoding="utf-8")
    legal_copy_source = source.split("private struct LegalDocumentView", 1)[0]
    legal_literals = re.findall(r'"(?:[^"\\]|\\.)*"', legal_copy_source)
    expected_literal_count = 50
    if len(legal_literals) != expected_literal_count:
        errors.append(
            "LegalView: expected "
            f"{expected_literal_count} reviewed English-only legal literals, "
            f"found {len(legal_literals)}; update the explicit release policy"
        )
    for required_rendering in (
        "Text(verbatim: section.title)",
        "Text(verbatim: paragraph)",
        ".navigationTitle(Text(verbatim: title))",
    ):
        if required_rendering not in source:
            errors.append(
                "LegalView: English-only legal copy must render verbatim; "
                f"missing {required_rendering!r}"
            )
    notice_key = "Legal documents are currently provided in English."
    if f'String(localized: "{notice_key}")' not in source:
        errors.append(
            "LegalView: non-English locales need the localized "
            "English-only legal notice"
        )
    return len(legal_literals)


def swift_source_blob() -> str:
    """Every Swift source line the shipping app and its package compile."""
    chunks: list[str] = []
    for root in (
        ROOT / "MileageTracker",
        ROOT / "MileageTrackerWidgets",
        APPCORE_SOURCE_ROOT,
    ):
        for path in root.rglob("*.swift"):
            chunks.append(path.read_text(encoding="utf-8", errors="ignore"))
    return "\n".join(chunks)


def key_appears_in_source(key: str, blob: str) -> bool:
    """Whether a catalog key is still written somewhere in Swift.

    Two spellings differ between a catalog and its call site and MUST both be
    tolerated, or this reports live strings as dead:

    * printf tokens — the catalog stores `%@` / `%lld` where Swift may
      interpolate, e.g. "Row %lld" written as "Row \\(index)".
    * App Shortcuts placeholders — the catalog stores `${month}` and
      `${applicationName}` where Swift writes `\\(\\.$month)` and
      `\\(.applicationName)`. A literal compare marks every shipping Siri
      phrase dead; six of them were nearly deleted this way.
    """
    if key in blob:
        return True
    parts = [
        re.escape(part)
        for part in re.split(r"%(?:lld|@|\d+\$@|\d+\$lld|f|d|s)|\$\{\w+\}", key)
        if len(part.strip()) >= 4
    ]
    if not parts:
        # Too short to match on fragments; assume live rather than report a
        # false positive on something like "%@ · %@".
        return True
    return re.search(r".{0,60}?".join(parts), blob, re.DOTALL) is not None


def report_orphaned_keys() -> int:
    """Report catalog keys that no longer correspond to any source string.

    This exists because neither parity check can see them: `verify_localizable`
    and `verify_appcore_localizable` both filter out `extractionState == "stale"`
    before comparing, so a key Xcode has stopped extracting silently drops out
    of every check while keeping its de/es/fr translations forever.

    The two catalogs need different evidence:

    * The app catalog is authoritative through extraction, so an orphan is a key
      that is BOTH marked stale AND absent from the extracted set.
    * The AppCore catalog is built by SwiftPM, which Xcode's extractor never
      sees, so nearly every key there is marked stale and `extractionState`
      carries no signal at all. It can only be cross-referenced against source.

    Reported, not fatal: source cross-referencing is a heuristic, and a false
    positive must never be able to block a release.
    """
    blob = swift_source_blob()
    orphans: list[str] = []

    app_entries = load_catalog(LOCALIZABLE_PATH).get("strings", {})
    extracted_keys = {
        item["key"]
        for item in tables.get("Localizable", [])
        if isinstance(item.get("key"), str)
    }
    for key, entry in app_entries.items():
        if not key.strip() or key in extracted_keys:
            continue
        if entry.get("extractionState") == "stale" and not key_appears_in_source(key, blob):
            orphans.append(f"Localizable: {key!r}")

    appcore_entries = load_catalog(APPCORE_LOCALIZABLE_PATH).get("strings", {})
    for key in appcore_entries:
        if key.strip() and not key_appears_in_source(key, blob):
            orphans.append(f"AppCore Localizable: {key!r}")

    if orphans:
        print(
            f"NOTE: {len(orphans)} catalog key(s) match no string in Swift source "
            "and are carrying translations for screens that no longer exist. "
            "Splice them out textually — never round-trip the JSON."
        )
        for line in sorted(orphans):
            print(f"  orphan {line}")
    return len(orphans)


tables, built_info_plist = current_target_artifacts()
failures: list[str] = []
localizable_extracted_count, localizable_active_count = verify_localizable(tables, failures)
shortcut_count, shortcut_phrase_count = verify_shortcuts(tables, failures)
info_count = verify_info_plist(built_info_plist, failures)
appcore_count = verify_appcore_localizable(failures)
english_only_legal_count = verify_english_only_legal_surface(failures)
orphan_count = report_orphaned_keys()

if failures:
    raise SystemExit("\n".join(failures))

print(
    "iPhone localization verified: "
    f"{localizable_extracted_count} extracted/{localizable_active_count} active "
    f"Localizable keys, {shortcut_count} App Shortcut sets/"
    f"{shortcut_phrase_count} phrases, {info_count} active InfoPlist keys, "
    f"{appcore_count} active AppCore Localizable keys, "
    f"{len(TARGET_LANGUAGES)} translated languages; "
    f"{english_only_legal_count} intentionally English-only legal strings; "
    f"{orphan_count} orphaned catalog keys"
)
