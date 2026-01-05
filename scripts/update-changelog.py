#!/usr/bin/env python3
"""
Update CHANGELOG.md after a release PR is merged.

Usage:
    python scripts/update-changelog.py <version> <commit> <prev_commit>
    python scripts/update-changelog.py --extract-section <version>

Example:
    python scripts/update-changelog.py 2025-11-26 6bc34f1 2be0cff
    python scripts/update-changelog.py --extract-section 2025-11-26

This script:
1. Creates a new dated release section with the content from "Unreleased"
2. Updates the "Unreleased" diff link to start from the new release commit
3. Links the version header to the GitHub Release page
4. Can extract a specific version's section for use in release notes
"""

import re
import sys


def split_announcement_and_entries(text: str) -> tuple[str, str]:
    """Split content into Announcement section and changelog entries.

    Returns (announcement, entries) tuple.
    The Announcement section spans from ### Announcement to the first
    changelog entry header (### Added, ### Changed, ### Fixed, etc.).
    """
    # Standard changelog entry headers
    entry_headers = r'### (?:Added|Changed|Fixed|Removed|Deprecated|Security|Internal)'

    # Find the Announcement section
    announcement_match = re.search(r'(### Announcement.*?)(' + entry_headers + r')', text, re.DOTALL)

    if announcement_match:
        announcement = announcement_match.group(1).strip()
        # Get everything from the first entry header onwards
        entries_start = announcement_match.start(2)
        entries = text[entries_start:].strip()
        return announcement, entries

    # No Announcement section found, treat everything as entries
    return "", text.strip()


def extract_unreleased_content(version: str = "", commit: str = "", prev_commit: str = "") -> str:
    """Extract full content from the Unreleased section for GitHub Release notes.

    This includes the Announcement section and all changelog entries.
    If version, commit and prev_commit are provided, a metadata header is prepended.
    """
    with open('CHANGELOG.md', 'r') as f:
        content = f.read()

    # Pattern to match the Unreleased section header and metadata
    unreleased_header = r'## Unreleased\n\n- Commit: \[`HEAD`\]\(https://github\.com/aviatesk/JETLS\.jl/commit/HEAD\)\n- Diff: \[`[a-f0-9]+\.\.\.HEAD`\]\(https://github\.com/aviatesk/JETLS\.jl/compare/[a-f0-9]+\.\.\.HEAD\)\n'

    # Find everything between the Unreleased header and the next release section
    pattern = f'({unreleased_header})(.*?)(## \\d{{4}}-\\d{{2}}-\\d{{2}})'
    match = re.search(pattern, content, re.DOTALL)

    if not match:
        return ""

    unreleased_content = match.group(2).strip()

    # Prepend metadata header if release info is provided
    if version and commit and prev_commit:
        header = f"""- Commit: [`{commit}`](https://github.com/aviatesk/JETLS.jl/commit/{commit})
- Diff: [`{prev_commit}...{commit}`](https://github.com/aviatesk/JETLS.jl/compare/{prev_commit}...{commit})
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="{version}")'
  ```

"""
        return header + unreleased_content

    return unreleased_content


def update_changelog(version: str, commit: str, prev_commit: str) -> bool:
    with open('CHANGELOG.md', 'r') as f:
        content = f.read()

    # Check if the release section already exists
    if re.search(rf'^## {re.escape(version)}$', content, re.MULTILINE):
        print(f"Release {version} already exists in CHANGELOG.md, skipping update")
        return False

    # Pattern to match the Unreleased section header and metadata
    unreleased_header = r'## Unreleased\n\n- Commit: \[`HEAD`\]\(https://github\.com/aviatesk/JETLS\.jl/commit/HEAD\)\n- Diff: \[`[a-f0-9]+\.\.\.HEAD`\]\(https://github\.com/aviatesk/JETLS\.jl/compare/[a-f0-9]+\.\.\.HEAD\)\n'

    # Find everything between the Unreleased header and the next release section
    pattern = f'({unreleased_header})(.*?)(## \\d{{4}}-\\d{{2}}-\\d{{2}})'
    match = re.search(pattern, content, re.DOTALL)

    if not match:
        print("Could not find Unreleased section pattern")
        return False

    # Extract the content between Unreleased metadata and next release section
    unreleased_content = match.group(2).strip()

    # Split into Announcement (stays in Unreleased) and entries (moves to release)
    announcement, entries = split_announcement_and_entries(unreleased_content)

    # Build the new Unreleased header with updated commit
    new_unreleased_header = f"""## Unreleased

- Commit: [`HEAD`](https://github.com/aviatesk/JETLS.jl/commit/HEAD)
- Diff: [`{commit}...HEAD`](https://github.com/aviatesk/JETLS.jl/compare/{commit}...HEAD)

"""

    # Add the Announcement section back to Unreleased if present
    if announcement:
        new_unreleased_header += announcement + '\n\n'

    # Build the new release section
    new_release_section = f"""## {version}

- Commit: [`{commit}`](https://github.com/aviatesk/JETLS.jl/commit/{commit})
- Diff: [`{prev_commit}...{commit}`](https://github.com/aviatesk/JETLS.jl/compare/{prev_commit}...{commit})
- Installation:
  ```bash
  julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", rev="{version}")'
  ```

"""

    # Add the changelog entries to the new release section if there were any
    if entries:
        new_release_section += entries + '\n\n'

    # Build the replacement
    replacement = new_unreleased_header + new_release_section + match.group(3)
    new_content = content[:match.start()] + replacement + content[match.end():]

    with open('CHANGELOG.md', 'w') as f:
        f.write(new_content)

    print(f"CHANGELOG.md updated for release {version}")
    return True


def strip_announcement(text: str) -> str:
    """Remove the Announcement section from release notes.

    Returns the text with only the metadata header and changelog entries.
    """
    lines = text.split('\n')
    result_lines = []
    in_announcement = False

    # Standard changelog entry headers that end the Announcement section
    entry_header_pattern = re.compile(r'^### (?:Added|Changed|Fixed|Removed|Deprecated|Security|Internal)')

    for line in lines:
        if line.startswith('### Announcement'):
            in_announcement = True
            continue
        if in_announcement and entry_header_pattern.match(line):
            in_announcement = False
        if not in_announcement:
            result_lines.append(line)

    # Clean up extra blank lines
    result = '\n'.join(result_lines)
    result = re.sub(r'\n{3,}', '\n\n', result)
    return result.strip()


def main() -> int:
    if len(sys.argv) >= 2 and sys.argv[1] == '--strip-announcement':
        # Read from stdin and strip announcement section
        text = sys.stdin.read()
        print(strip_announcement(text))
        return 0

    if len(sys.argv) >= 2 and sys.argv[1] == '--extract-unreleased':
        # Optional: --extract-unreleased <version> <commit> <prev_commit>
        version = sys.argv[2] if len(sys.argv) > 2 else ""
        commit = sys.argv[3] if len(sys.argv) > 3 else ""
        prev_commit = sys.argv[4] if len(sys.argv) > 4 else ""
        content = extract_unreleased_content(version, commit, prev_commit)
        if content:
            print(content)
            return 0
        return 1

    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <version> <commit> <prev_commit>")
        print(f"       {sys.argv[0]} --extract-unreleased [<version> <commit> <prev_commit>]")
        print(f"       {sys.argv[0]} --strip-announcement < input.md")
        print(f"Example: {sys.argv[0]} 2025-11-26 6bc34f1 2be0cff")
        return 1

    version = sys.argv[1]
    commit = sys.argv[2]
    prev_commit = sys.argv[3]

    if update_changelog(version, commit, prev_commit):
        return 0
    return 1


if __name__ == '__main__':
    sys.exit(main())
