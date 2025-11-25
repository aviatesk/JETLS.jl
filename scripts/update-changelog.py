#!/usr/bin/env python3
"""
Update CHANGELOG.md after a release PR is merged.

Usage:
    python scripts/update-changelog.py <version> <commit> <pr_number> <prev_commit>

Example:
    python scripts/update-changelog.py 2025-11-26 6bc34f1 326 2be0cff

This script:
1. Creates a new dated release section with the content from "Unreleased"
2. Updates the "Unreleased" diff link to start from the new release commit
"""

import re
import sys


def update_changelog(version: str, commit: str, pr_number: str, prev_commit: str) -> bool:
    with open('CHANGELOG.md', 'r') as f:
        content = f.read()

    # Check if the release section already exists
    if re.search(rf'^## \[{re.escape(version)}\]', content, re.MULTILINE):
        print(f"Release {version} already exists in CHANGELOG.md, skipping update")
        return False

    # Pattern to match the Unreleased section header and metadata
    unreleased_header = r'## Unreleased\n\n> \[!note\]\n>\n> - Commit: \[`HEAD`\]\(https://github\.com/aviatesk/JETLS\.jl/commit/HEAD\)\n> - Diff: \[`[a-f0-9]+\.\.\.HEAD`\]\(https://github\.com/aviatesk/JETLS\.jl/compare/[a-f0-9]+\.\.\.HEAD\)\n'

    # Find everything between the Unreleased header and the next release section
    pattern = f'({unreleased_header})(.*?)(## \\[\\d{{4}}-\\d{{2}}-\\d{{2}}\\])'
    match = re.search(pattern, content, re.DOTALL)

    if not match:
        print("Could not find Unreleased section pattern")
        return False

    # Extract the content between Unreleased metadata and next release section
    unreleased_content = match.group(2).strip()

    # Build the new Unreleased header with updated commit
    new_unreleased_header = f"""## Unreleased

> [!note]
>
> - Commit: [`HEAD`](https://github.com/aviatesk/JETLS.jl/commit/HEAD)
> - Diff: [`{commit}...HEAD`](https://github.com/aviatesk/JETLS.jl/compare/{commit}...HEAD)

"""

    # Build the new release section
    new_release_section = f"""## [{version}]

[{version}]: https://github.com/aviatesk/JETLS.jl/pull/{pr_number}

> [!note]
>
> - Commit: [`{commit}`](https://github.com/aviatesk/JETLS.jl/commit/{commit})
> - Diff: [`{prev_commit}...{commit}`](https://github.com/aviatesk/JETLS.jl/compare/{prev_commit}...{commit})

"""

    # Add the unreleased content to the new release section if there was any
    if unreleased_content:
        new_release_section += unreleased_content + '\n\n'

    # Build the replacement
    replacement = new_unreleased_header + new_release_section + match.group(3)
    new_content = content[:match.start()] + replacement + content[match.end():]

    with open('CHANGELOG.md', 'w') as f:
        f.write(new_content)

    print(f"CHANGELOG.md updated for release {version}")
    return True


def main() -> int:
    if len(sys.argv) != 5:
        print(f"Usage: {sys.argv[0]} <version> <commit> <pr_number> <prev_commit>")
        print(f"Example: {sys.argv[0]} 2025-11-26 6bc34f1 326 2be0cff")
        return 1

    version = sys.argv[1]
    commit = sys.argv[2]
    pr_number = sys.argv[3]
    prev_commit = sys.argv[4]

    if update_changelog(version, commit, pr_number, prev_commit):
        return 0
    return 1


if __name__ == '__main__':
    sys.exit(main())
