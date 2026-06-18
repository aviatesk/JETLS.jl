#!/usr/bin/env python3

import argparse
import html
import posixpath
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

RAW_BASE_URL = (
    "https://raw.githubusercontent.com/"
    "microsoft/language-server-protocol/gh-pages/"
)
PUBLIC_BASE_URL = (
    "https://microsoft.github.io/language-server-protocol/specifications/lsp"
)
SPEC_ROOT = "_specifications/lsp"
INCLUDE_ROOT = "_includes"

FRONT_MATTER_RE = re.compile(r"\A---\n(.*?)\n---\n?", re.DOTALL)
INCLUDE_RE = re.compile(r"\{%\s*(include_relative|include)\s+([^\s%]+)[^%]*%\}")
TABLE_CLASS_RE = re.compile(r"^\{:\s+[^}]+\}\s*$")
TABLE_SEPARATOR_RE = re.compile(
    r"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$"
)
BULLET_RE = re.compile(r"^(\s*)\*\s+")
HEADING_ANCHOR_RE = re.compile(
    r'^(#{1,6})\s+<a\s+href="#[^"]*"\s+name="([^"]+)"'
    r'\s+class="anchor">(.*?)</a>\s*$'
)
TEXT_ANCHOR_RE = re.compile(
    r'^<a\s+href="#[^"]*"\s+name="([^"]+)"\s+class="anchor">(.*?)</a>\s*$'
)
ANCHOR_HOLDER_RE = re.compile(
    r'^<div\s+class="anchorHolder"><a\s+href="#[^"]*"\s+'
    r'name="([^"]+)"\s+class="linkableAnchor"></a></div>\s*$'
)
EMOJI_MARKER_RE = re.compile(
    r"\s*\(:[A-Za-z0-9_+-]+:(?:\s+:[A-Za-z0-9_+-]+:)*\)\s*$"
)


def fetch_text(url: str) -> str:
    try:
        with urllib.request.urlopen(url) as response:
            return response.read().decode("utf-8")
    except urllib.error.URLError as error:
        raise RuntimeError(f"failed to fetch {url}: {error}") from error


def parse_front_matter(text: str) -> tuple[dict[str, str], str]:
    match = FRONT_MATTER_RE.match(text)
    if match is None:
        return {}, text

    data: dict[str, str] = {}
    for line in match.group(1).splitlines():
        if not line or line.startswith(" ") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        data[key.strip()] = value.strip().strip('"')
    return data, text[match.end():]


class SourceExpander:
    def __init__(self, version: str) -> None:
        self.version = version
        self.cache: dict[str, str] = {}
        self.stack: list[str] = []

    def root_path(self) -> str:
        return f"{SPEC_ROOT}/{self.version}/specification.md"

    def fetch_path(self, path: str) -> str:
        if path not in self.cache:
            self.cache[path] = fetch_text(RAW_BASE_URL + path)
        return self.cache[path]

    def expand_path(
        self, path: str, *, strip_front_matter: bool
    ) -> tuple[dict[str, str], str]:
        if path in self.stack:
            cycle = " -> ".join([*self.stack, path])
            raise RuntimeError(f"recursive include cycle: {cycle}")

        self.stack.append(path)
        text = self.fetch_path(path)
        metadata: dict[str, str] = {}
        if strip_front_matter:
            metadata, text = parse_front_matter(text)
        expanded = self.expand_includes(text, path)
        self.stack.pop()
        return metadata, expanded

    def expand_includes(self, text: str, current_path: str) -> str:
        current_dir = posixpath.dirname(current_path)

        def replace(match: re.Match[str]) -> str:
            kind, include_path = match.groups()
            if kind == "include_relative":
                path = posixpath.normpath(posixpath.join(current_dir, include_path))
            else:
                path = posixpath.normpath(posixpath.join(INCLUDE_ROOT, include_path))
            _, expanded = self.expand_path(path, strip_front_matter=False)
            return expanded

        return INCLUDE_RE.sub(replace, text)


def clean_heading_title(title: str) -> str:
    return EMOJI_MARKER_RE.sub("", html.unescape(title)).strip()


def slugify_heading(title: str) -> str:
    slug = title.lower()
    slug = re.sub(r"[^\w\s-]", "", slug)
    slug = re.sub(r"\s+", "-", slug.strip())
    slug = re.sub(r"-+", "-", slug)
    return slug or "section"


def heading_anchor_map(text: str) -> dict[str, str]:
    anchors: dict[str, str] = {}
    used: dict[str, int] = {}
    for line in text.splitlines():
        heading = HEADING_ANCHOR_RE.match(line)
        if heading is None:
            continue
        _, anchor_id, title = heading.groups()
        slug = slugify_heading(clean_heading_title(title))
        count = used.get(slug, 0)
        used[slug] = count + 1
        anchors[anchor_id] = slug if count == 0 else f"{slug}-{count}"
    return anchors


def normalize_anchors(text: str) -> str:
    lines: list[str] = []
    for line in text.splitlines():
        if ANCHOR_HOLDER_RE.match(line) is not None:
            continue

        heading = HEADING_ANCHOR_RE.match(line)
        if heading is not None:
            level, _, title = heading.groups()
            lines.append(f"{level} {clean_heading_title(title)}")
            continue

        text_anchor = TEXT_ANCHOR_RE.match(line)
        if text_anchor is not None:
            _, title = text_anchor.groups()
            lines.append(html.unescape(title))
            continue

        lines.append(line)
    return "\n".join(lines)


def normalize_local_links(text: str, anchors: dict[str, str]) -> str:
    def replace(match: re.Match[str]) -> str:
        label, target = match.groups()
        if target in anchors:
            return f"[{label}](#{anchors[target]})"
        return label

    return re.sub(r"(?<!!)\[([^\]]+)\]\(#([A-Za-z0-9_.\[\]-]+)\)", replace, text)


def normalize_links(text: str, version: str) -> str:
    meta_model_base = f"{PUBLIC_BASE_URL}/{version}/metaModel"
    return re.sub(
        r"\]\(\.\./metaModel/([^\)]+)\)",
        lambda match: f"]({meta_model_base}/{match.group(1)})",
        text,
    )


def format_table_row(line: str) -> str:
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    return "| " + " | ".join(cells) + " |"


def normalize_tables(text: str) -> str:
    source = text.splitlines()
    lines: list[str] = []
    in_fence = False
    index = 0

    while index < len(source):
        line = source[index]
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            lines.append(line)
            index += 1
            continue

        has_table = (
            not in_fence
            and index + 1 < len(source)
            and "|" in line
            and TABLE_SEPARATOR_RE.match(source[index + 1]) is not None
        )
        if has_table:
            while index < len(source) and "|" in source[index]:
                lines.append(format_table_row(source[index]))
                index += 1
            continue

        lines.append(line)
        index += 1

    return "\n".join(lines)


def needs_leading_blank(line: str, in_fence: bool) -> bool:
    if in_fence or line == "":
        return False
    return (
        line.startswith("#")
        or line.startswith("<a id=")
        or line.startswith("```")
    )


def normalize_lines(text: str) -> str:
    lines: list[str] = []
    blank_count = 0
    in_fence = False

    for line in text.splitlines():
        stripped = line.strip()

        if not in_fence and TABLE_CLASS_RE.match(stripped):
            continue

        if not in_fence:
            line = BULLET_RE.sub(r"\1- ", line.rstrip())

        if needs_leading_blank(line, in_fence) and lines and lines[-1] != "":
            lines.append("")
            blank_count = 1

        if not in_fence and line == "":
            blank_count += 1
            if blank_count > 1:
                continue
        else:
            blank_count = 0

        lines.append(line)

        if stripped.startswith("```"):
            in_fence = not in_fence

    return "\n".join(lines).strip() + "\n"


def build_specification(version: str) -> str:
    expander = SourceExpander(version)
    metadata, body = expander.expand_path(
        expander.root_path(), strip_front_matter=True
    )
    title = metadata.get(
        "fullTitle", f"Language Server Protocol Specification - {version}"
    )
    body = body.lstrip()
    anchors = heading_anchor_map(body)
    body = normalize_anchors(body)
    body = normalize_local_links(body, anchors)
    body = normalize_links(body, version)
    body = normalize_tables(body)
    return normalize_lines(f"# {title}\n\n{body}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Regenerate LSP/specification.md from the upstream LSP spec."
    )
    parser.add_argument("--version", default="3.18", help="LSP version to fetch")
    parser.add_argument(
        "--output",
        default="LSP/specification.md",
        type=Path,
        help="output Markdown path",
    )
    args = parser.parse_args()

    try:
        text = build_specification(args.version)
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 1

    args.output.write_text(text, encoding="utf-8")
    print(f"wrote {args.output} for LSP {args.version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
