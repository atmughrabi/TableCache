#!/usr/bin/env python3
"""Validate local documentation links and publication figures."""

from __future__ import annotations

import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
PUBLIC_FIGURES = ROOT / "doc/fig/wiki"
FIGURE_SOURCES = ROOT / "doc/fig/wiki_src"
LINK_RE = re.compile(r"!?\[[^\]]*]\(([^)]+)\)")
NESTED_LINK_RE = re.compile(r"\[!\[[^\]]*]\(([^)]+)\)]\(([^)]+)\)")
REFERENCE_RE = re.compile(r"^\s*\[[^\]]+]:\s*(\S+)", re.MULTILINE)
HTML_LINK_RE = re.compile(r"\b(?:src|href)\s*=\s*[\"']([^\"']+)[\"']", re.IGNORECASE)
BOX_DRAWING_RE = re.compile(r"[\u2500-\u257f]")
COLOR_RE = re.compile(r"#[0-9A-Fa-f]{3,8}")
FUNCTION_COLOR_RE = re.compile(r"\brgba?\s*\(", re.IGNORECASE)
NAMED_ATTRIBUTE_COLOR_RE = re.compile(
    r"\b(?:fill|stroke)\s*=\s*[\"']([A-Za-z]+)[\"']", re.IGNORECASE
)
ALLOWED_COLORS = {
    "#000000", "#008A0E", "#1071E5", "#24282B", "#28392C", "#29363B",
    "#332F39", "#3A414A", "#3D3526", "#402B2D", "#635DFF", "#92C89A",
    "#979EA8", "#9CB8E8", "#A7A6FF", "#A8ADB0", "#B5A8C0", "#C1E4F7",
    "#C92D39", "#CC4E00", "#D6A071", "#D7FAF5", "#E39AA0", "#E7E2D9",
    "#F7F4E4", "#FFBBB1", "#FFDDA6",
}


def tracked_markdown() -> list[Path]:
    output = subprocess.check_output(
        ["git", "ls-files", "*.md"], cwd=ROOT, text=True
    )
    return [ROOT / line for line in output.splitlines() if line]


def link_path(raw_target: str) -> str:
    target = raw_target.strip()
    if target.startswith("<") and ">" in target:
        target = target[1:target.index(">")]
    elif ' "' in target:
        target = target.split(' "', 1)[0]
    return unquote(target.split("#", 1)[0].split("?", 1)[0])


def check_target(path: Path, raw_target: str, errors: list[str]) -> None:
    target = link_path(raw_target)
    if not target or target.startswith(
        ("http://", "https://", "mailto:", "tel:", "data:")
    ):
        return
    if target.startswith("/"):
        resolved = (ROOT / target.lstrip("/")).resolve()
    else:
        resolved = (path.parent / target).resolve()
    if not resolved.exists():
        errors.append(
            f"{path.relative_to(ROOT)}: broken local link {raw_target!r}"
        )


def check_markdown(errors: list[str]) -> str:
    combined = []
    for path in tracked_markdown():
        text = path.read_text(encoding="utf-8")
        combined.append(text)
        if BOX_DRAWING_RE.search(text):
            errors.append(f"{path.relative_to(ROOT)}: box-drawing flow art is not allowed")
        for match in LINK_RE.finditer(text):
            check_target(path, match.group(1), errors)
        for match in NESTED_LINK_RE.finditer(text):
            check_target(path, match.group(1), errors)
            check_target(path, match.group(2), errors)
        for match in REFERENCE_RE.finditer(text):
            check_target(path, match.group(1), errors)
        for match in HTML_LINK_RE.finditer(text):
            check_target(path, match.group(1), errors)
    return "\n".join(combined)


def check_figures(errors: list[str], markdown_text: str) -> None:
    svg_paths = sorted(PUBLIC_FIGURES.rglob("*.svg"))
    source_paths = sorted(FIGURE_SOURCES.rglob("*.drawio"))
    svg_keys = {path.relative_to(PUBLIC_FIGURES).with_suffix("") for path in svg_paths}
    source_keys = {
        path.relative_to(FIGURE_SOURCES).with_suffix("") for path in source_paths
    }
    for key in sorted(svg_keys - source_keys):
        errors.append(f"missing Draw.io source for {key}.svg")
    for key in sorted(source_keys - svg_keys):
        errors.append(f"missing publication SVG for {key}.drawio")

    for path in svg_paths:
        rel = path.relative_to(ROOT)
        text = path.read_text(encoding="utf-8")
        try:
            root = ET.fromstring(text)
        except ET.ParseError as exc:
            errors.append(f"{rel}: invalid SVG XML: {exc}")
            continue
        namespace = {"svg": "http://www.w3.org/2000/svg"}
        title = root.find("svg:title", namespace)
        desc = root.find("svg:desc", namespace)
        if root.get("role") != "img" or not root.get("aria-labelledby"):
            errors.append(f"{rel}: missing image accessibility attributes")
        if title is None or not (title.text or "").strip():
            errors.append(f"{rel}: missing nonempty title")
        if desc is None or not (desc.text or "").strip():
            errors.append(f"{rel}: missing nonempty description")
        if "prefers-color-scheme" not in text:
            errors.append(f"{rel}: missing dark-mode palette")
        color_tokens = COLOR_RE.findall(text)
        malformed_hex = sorted({
            color for color in color_tokens if len(color) != 7
        })
        unexpected = {
            color.upper() for color in color_tokens if len(color) == 7
        } - ALLOWED_COLORS
        named_colors = sorted({
            match.group(1)
            for match in NAMED_ATTRIBUTE_COLOR_RE.finditer(text)
            if match.group(1).lower() not in {"none", "transparent"}
        })
        if malformed_hex:
            errors.append(f"{rel}: noncanonical hex colors: {malformed_hex}")
        if FUNCTION_COLOR_RE.search(text):
            errors.append(f"{rel}: rgb()/rgba() colors are outside the figure palette")
        if named_colors:
            errors.append(f"{rel}: named colors are outside the figure palette: {named_colors}")
        if unexpected:
            errors.append(f"{rel}: colors outside the figure palette: {sorted(unexpected)}")
        if path.name not in markdown_text:
            errors.append(f"{rel}: publication figure is not embedded in Markdown")

    for path in source_paths:
        rel = path.relative_to(ROOT)
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as exc:
            errors.append(f"{rel}: invalid Draw.io XML: {exc}")
            continue
        if not root.tag.endswith("mxfile") or root.find("diagram") is None:
            errors.append(f"{rel}: missing Draw.io mxfile/diagram structure")


def main() -> int:
    errors: list[str] = []
    markdown_text = check_markdown(errors)
    check_figures(errors, markdown_text)
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    if 'width="180"' not in readme:
        errors.append("README.md: logo width must remain 180 px")
    if errors:
        print("\n".join(f"ERROR: {error}" for error in errors), file=sys.stderr)
        return 1
    print("documentation: links and figures clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
