
"""
A pattern kind describing if a glob pattern matches a file a folder or both.

# Tags
- since – 3.16.0
"""
@namespace FileOperationPatternKind::String begin
    "The pattern matches a file only."
    file = "file"

    "The pattern matches a folder only."
    folder = "folder"
end

"""
Matching options for the file operation pattern.

# Tags
- since – 3.16.0
"""
@interface FileOperationPatternOptions begin
    "The pattern should be matched ignoring casing."
    ignoreCase::Union{Bool, Nothing} = nothing
end

"""
A pattern to describe in which file operation requests or notifications the server is
interested in.

# Tags
- since – 3.16.0
"""
@interface FileOperationPattern begin
    """
    The glob pattern to match. Glob patterns can have the following syntax:
    - `*` to match one or more characters in a path segment
    - `?` to match on one character in a path segment
    - `**` to match any number of path segments, including none
    - `{}` to group sub patterns into an OR expression. (e.g. `**\u200b/*.{ts,js}`
      matches all TypeScript and JavaScript files)
    - `[]` to declare a range of characters to match in a path segment (e.g.,
      `example.[0-9]` to match on `example.0`, `example.1`, …)
    - `[!...]` to negate a range of characters to match in a path segment (e.g.,
      `example.[!0-9]` to match on `example.a`, `example.b`, but not `example.0`)
    """
    glob::String

    "Whether to match files or folders with this pattern. Matches both if undefined."
    matches::Union{FileOperationPatternKind.Ty, Nothing} = nothing

    "Additional options used during matching."
    options::Union{FileOperationPatternOptions, Nothing} = nothing
end

"""
A filter to describe in which file operation requests or notifications the server is
interested in.

# Tags
- since – 3.16.0
"""
@interface FileOperationFilter begin
    "A Uri like `file` or `untitled`."
    scheme::Union{String, Nothing} = nothing

    "The actual file operation pattern."
    pattern::FileOperationPattern
end

"""
The options to register for file operations.

# Tags
- since – 3.16.0
"""
@interface FileOperationRegistrationOptions begin
    "The actual filters."
    filters::Vector{FileOperationFilter}
end
