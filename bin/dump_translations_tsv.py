#!/usr/bin/env python3
"""Dumps every entry of GSApp/Localizable.xcstrings as a TSV for
the Android port to ingest.

Columns: iosKey<TAB>en<TAB>fr<TAB>pl<TAB>section

Section is inferred from where the key is used in the source
tree (greps GSApp/ + Packages/). Strings with no usage site
land in `Misc`. Sorted by section then iosKey.

Footer comment lines list total entries, fully-translated count,
and the keys still missing fr or pl translations.

Idempotent — overwrite-safe.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
XCSTRINGS = REPO_ROOT / "GSApp" / "Localizable.xcstrings"
OUT = REPO_ROOT / "exports" / "translations" / "all-strings.tsv"

# Order in which sections appear in the output TSV. Matches the
# user's documented section list verbatim.
SECTION_ORDER = [
    "Tabs",
    "Login",
    "Scan",
    "Reference",
    "Stock",
    "Batches",
    "Register",
    "Photo",
    "OCR",
    "Measures",
    "History",
    "Settings",
    "Errors",
    "Misc",
]

# File-path patterns → section. Checked in priority order so a
# more specific pattern wins over a generic one. Each pattern is
# a substring match against the relative path (Unix slashes).
SECTION_PATTERNS = [
    # Login/Auth first — there's no Login/ folder so we rely on
    # file basenames.
    ("LoginView.swift", "Login"),
    ("OAuthSignInButton.swift", "Login"),
    ("AuthDeepLinkHandler.swift", "Login"),
    # Tabs — `TabView { ... .tabItem { Label("Scan", …) } }` only
    # lives in GSApp.swift.
    ("GSApp/GSApp.swift", "Tabs"),
    # Photo / OCR — both under GSApp/Photo and Settings/Photo.
    # OCR keys are picked out explicitly below; everything else
    # in Photo/ is treated as Photo.
    ("OCRObservationEditor.swift", "OCR"),
    ("TechViewsOCR.swift", "OCR"),
    ("TechViewsPictoDetection.swift", "OCR"),
    ("PictoLabelPicker.swift", "OCR"),
    ("LearnedPictogram.swift", "OCR"),
    ("TechViewCategory.swift", "OCR"),
    ("TechViewsAnnotationView.swift", "OCR"),
    ("TechViewsCaptureView.swift", "Photo"),
    ("TechViewsFlow.swift", "Photo"),
    ("PhotoTab.swift", "Photo"),
    ("SettingsPhotoView.swift", "Photo"),
    ("CaptureMode+UI.swift", "Photo"),
    ("TechViewEditorShell.swift", "OCR"),
    # Measures — both the standalone tab and any Measure/* file.
    ("MeasureTab.swift", "Measures"),
    ("/Measure/", "Measures"),
    ("MeasureCategory.swift", "Measures"),
    # Reference detail screen — wins over generic Scan/.
    ("ReferenceDetailView.swift", "Reference"),
    ("ReferenceSearchView.swift", "Scan"),
    ("ScanProductFlow.swift", "Scan"),
    ("BarcodeScannerView.swift", "Scan"),
    ("ScanTab.swift", "Scan"),
    # Register flow (post-scan, when the EAN isn't yet in catalog).
    ("RegisterProduct", "Register"),
    # Batches — anything Batch* in the Scan area.
    ("BatchDetailView.swift", "Batches"),
    ("BatchScanView.swift", "Batches"),
    ("BatchPickerView.swift", "Batches"),
    ("BatchListView.swift", "Batches"),
    # Stock — StockItemStatus + stock-related domain files.
    ("StockItemStatus.swift", "Stock"),
    # History.
    ("HistoryTab.swift", "History"),
    ("/History/", "History"),
    # Settings sub-screens (all four).
    ("SettingsTab.swift", "Settings"),
    ("SettingsScannerView.swift", "Settings"),
    ("SettingsGrandShootingView.swift", "Settings"),
    ("SettingsProfileView.swift", "Settings"),
    # Errors — networking layer and any banner-rendering helper.
    ("GSHTTPClient.swift", "Errors"),
    ("OAuthSignInService.swift", "Errors"),
    ("BackendStatusBanner.swift", "Errors"),
    # Catch-all fallbacks.
    ("/Scan/", "Scan"),
    ("/Settings/", "Settings"),
    ("/Photo/", "Photo"),
]


def load_source_index() -> list[tuple[str, str]]:
    """Walks GSApp/ + Packages/ once, returns a list of
    (relative_path, file_contents) tuples. Skips build artefacts
    and binary blobs.
    """
    out: list[tuple[str, str]] = []
    for base in ["GSApp", "Packages"]:
        base_path = REPO_ROOT / base
        for path in base_path.rglob("*.swift"):
            rel = str(path.relative_to(REPO_ROOT))
            if ".build/" in rel or "/DerivedSources/" in rel:
                continue
            try:
                out.append((rel, path.read_text(encoding="utf-8", errors="replace")))
            except OSError:
                continue
    return out


def infer_section(key: str, source_index: list[tuple[str, str]]) -> str:
    """Searches the in-memory source index for the literal
    `"key"` (Swift string literal). First file whose path matches
    a SECTION_PATTERNS entry wins. `Misc` when no file matches.
    """
    # Wrap the key in double quotes so we hit Swift string literals
    # and not stray substrings. Some keys contain `"` themselves —
    # the wrapped form will simply not match those, falling to Misc.
    needle = f'"{key}"'
    hits: list[str] = []
    for rel, contents in source_index:
        if needle in contents:
            hits.append(rel)
    if not hits:
        return "Misc"
    for pattern, section in SECTION_PATTERNS:
        if any(pattern in rel for rel in hits):
            return section
    return "Misc"


def value_for(entry: dict, locale: str) -> str:
    """Pulls the translation for `locale` from an xcstrings entry.
    Returns `""` when absent.
    """
    loc = entry.get("localizations", {}).get(locale)
    if loc is None:
        return ""
    unit = loc.get("stringUnit", {})
    return unit.get("value", "")


def tsv_escape(value: str) -> str:
    """Escapes TAB / NL / CR so each entry stays on a single
    TSV line. Keeps every other character verbatim (including
    Unicode — output is UTF-8).
    """
    return (value
            .replace("\\", "\\\\")
            .replace("\t", "\\t")
            .replace("\n", "\\n")
            .replace("\r", "\\r"))


def main() -> None:
    with XCSTRINGS.open() as f:
        catalog = json.load(f)
    strings: dict = catalog.get("strings", {})

    rows: list[tuple[str, str, str, str, str]] = []
    missing_fr: list[str] = []
    missing_pl: list[str] = []
    fully_translated = 0

    # Include EVERY key — Xcode's `extractionState: stale` flag
    # is unreliable (lots of false positives on string catalogs).
    # We let the Android port decide what to keep.
    keys = list(strings.keys())

    print(f"Indexing source tree…", file=sys.stderr)
    source_index = load_source_index()
    print(f"  indexed {len(source_index)} swift files", file=sys.stderr)
    print(f"Processing {len(keys)} keys…", file=sys.stderr)

    for i, key in enumerate(sorted(keys)):
        if i % 50 == 0:
            print(f"  {i}/{len(keys)}", file=sys.stderr)
        entry = strings[key]
        # iOS xcstrings convention: the entry's en value defaults
        # to the key when no explicit `en` localization is set.
        en = value_for(entry, "en") or key
        fr = value_for(entry, "fr")
        pl = value_for(entry, "pl")
        section = infer_section(key, source_index)

        if not fr:
            missing_fr.append(key)
        if not pl:
            missing_pl.append(key)
        if fr and pl:
            fully_translated += 1

        rows.append((key, en, fr, pl, section))

    # Sort: section (by SECTION_ORDER index), then iosKey.
    section_rank = {s: i for i, s in enumerate(SECTION_ORDER)}
    rows.sort(key=lambda r: (section_rank.get(r[4], len(SECTION_ORDER)), r[0]))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w") as f:
        f.write("iosKey\ten\tfr\tpl\tsection\n")
        for row in rows:
            f.write("\t".join(tsv_escape(v) for v in row) + "\n")
        f.write("\n")
        f.write(f"# Total entries: {len(rows)}\n")
        f.write(f"# Entries with all 3 locales: {fully_translated}\n")
        f.write(f"# Missing fr ({len(missing_fr)}): ")
        f.write(", ".join(missing_fr) if missing_fr else "none")
        f.write("\n")
        f.write(f"# Missing pl ({len(missing_pl)}): ")
        f.write(", ".join(missing_pl) if missing_pl else "none")
        f.write("\n")
        f.write("# Note: no `.one`/`.other` rows emitted — the iOS catalog\n")
        f.write("# uses inline `point(s)` pseudo-plurals, not Apple variations.\n")
        f.write("# Every key from the catalog is included (no exclusion of\n")
        f.write("# `extractionState: stale` since Xcode's auto-extractor is\n")
        f.write("# unreliable — many flagged-stale entries are still live).\n")

    print(f"\nWrote {OUT.relative_to(REPO_ROOT)}", file=sys.stderr)
    print(f"  rows: {len(rows)}", file=sys.stderr)
    print(f"  fully translated: {fully_translated}", file=sys.stderr)
    print(f"  missing fr: {len(missing_fr)}", file=sys.stderr)
    print(f"  missing pl: {len(missing_pl)}", file=sys.stderr)


if __name__ == "__main__":
    main()
