#!/usr/bin/env julia

const ANNOUNCEMENT_PATTERN = r"^### Announcement.*?(?=^### |\z)"ms

const UNRELEASED_HEADER_PATTERN =
    raw"## Unreleased\n\n" *
    raw"- Commit: \[`HEAD`\]\(https://github\.com/aviatesk/JETLS\.jl/commit/HEAD\)\n" *
    raw"- Diff: \[`[a-f0-9]+\.\.\.HEAD`\]" *
    raw"\(https://github\.com/aviatesk/JETLS\.jl/compare/[a-f0-9]+\.\.\.HEAD\)\n"

const UNRELEASED_PATTERN =
    Regex("(" * UNRELEASED_HEADER_PATTERN * raw")(.*?)(## \d{4}-\d{2}-\d{2})", "s")

function required_capture(m::RegexMatch, index::Int)
    return String(@something m.captures[index] error("missing capture $index"))
end

function split_announcement_and_entries(text::String)
    announcement_match =
        @something match(ANNOUNCEMENT_PATTERN, text) return ("", String(strip(text)))
    announcement = String(strip(announcement_match.match))
    entries = replace(text, ANNOUNCEMENT_PATTERN => ""; count = 1)
    entries = replace(strip(entries), r"\n{3,}" => "\n\n")
    return (announcement, entries)
end

function release_metadata(version::String, commit::String, prev_commit::String)
    commit_url = "https://github.com/aviatesk/JETLS.jl/commit/$commit"
    diff_url = "https://github.com/aviatesk/JETLS.jl/compare/$prev_commit...$commit"
    package_url = "https://github.com/aviatesk/JETLS.jl"
    return """- Commit: [`$commit`]($commit_url)
    - Diff: [`$prev_commit...$commit`]($diff_url)
    - Installation:
      ```bash
      julia -e 'using Pkg; Pkg.Apps.add(; url="$package_url", rev="$version")'
      ```

    """
end

function extract_unreleased_content(
        version::String, commit::String, prev_commit::String;
        changelog_path::String = "CHANGELOG.md",
    )
    content = read(changelog_path, String)
    unreleased_match = @something match(UNRELEASED_PATTERN, content) return ""

    unreleased_content = String(strip(required_capture(unreleased_match, 2)))
    announcement, entries = split_announcement_and_entries(unreleased_content)
    announcement_has_content = !isempty(announcement) && announcement != "### Announcement"

    final_content = if announcement_has_content
        isempty(entries) ? announcement : announcement * "\n\n" * entries
    else
        entries
    end

    all(!isempty, (version, commit, prev_commit)) &&
        return release_metadata(version, commit, prev_commit) * final_content
    return final_content
end

function update_changelog(
        version::String, commit::String, prev_commit::String;
        changelog_path::String = "CHANGELOG.md",
    )
    content = read(changelog_path, String)
    release_header = "## $version"
    if any(line -> line == release_header, eachline(IOBuffer(content)))
        println("Release $version already exists in CHANGELOG.md, skipping update")
        return false
    end

    unreleased_match = match(UNRELEASED_PATTERN, content)
    if isnothing(unreleased_match)
        println("Could not find Unreleased section pattern")
        return false
    end

    unreleased_content = String(strip(required_capture(unreleased_match, 2)))
    announcement, entries = split_announcement_and_entries(unreleased_content)

    new_unreleased_header = """## Unreleased

    - Commit: [`HEAD`](https://github.com/aviatesk/JETLS.jl/commit/HEAD)
    - Diff: [`$commit...HEAD`](https://github.com/aviatesk/JETLS.jl/compare/$commit...HEAD)

    """
    if !isempty(announcement)
        new_unreleased_header *= announcement * "\n\n"
    end

    new_release_section = "## $version\n\n" * release_metadata(version, commit, prev_commit)
    if !isempty(entries)
        new_release_section *= entries * "\n\n"
    end

    replacement =
        new_unreleased_header * new_release_section * required_capture(unreleased_match, 3)
    new_content = replace(content, UNRELEASED_PATTERN => replacement; count = 1)
    write(changelog_path, new_content)

    println("CHANGELOG.md updated for release $version")
    return true
end

function strip_announcement(text::String)
    result_lines = String[]
    in_announcement = false

    for line in split(text, '\n'; keepempty = true)
        if startswith(line, "### Announcement")
            in_announcement = true
        elseif in_announcement && startswith(line, "### ")
            in_announcement = false
        end
        in_announcement || push!(result_lines, line)
    end

    result = replace(join(result_lines, '\n'), r"\n{3,}" => "\n\n")
    return String(strip(result))
end

function print_usage(io::IO, program::String)
    println(
        io,
        """Usage: $program <version> <commit> <prev_commit>
               $program --extract-unreleased [<version> <commit> <prev_commit>]
               $program --strip-announcement < input.md
        Example: $program 2025-11-26 6bc34f1 2be0cff""",
    )
end

function (@main)(args::Vector{String})
    command = get(args, 1, "")
    if command == "--strip-announcement"
        println(strip_announcement(read(stdin, String)))
        return 0
    end

    if command == "--extract-unreleased"
        version = get(args, 2, "")
        commit = get(args, 3, "")
        prev_commit = get(args, 4, "")
        content = extract_unreleased_content(version, commit, prev_commit)
        isempty(content) && return 1
        println(content)
        return 0
    end

    if length(args) != 3
        program = isempty(PROGRAM_FILE) ? "scripts/update-changelog.jl" : PROGRAM_FILE
        print_usage(stdout, program)
        return 1
    end

    return update_changelog(args[1], args[2], args[3]) ? 0 : 1
end
