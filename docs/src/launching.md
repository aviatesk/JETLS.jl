# Launching JETLS

This guide explains how to launch the JETLS language server using
`runserver.jl` and describes the available communication channels.

## Using runserver.jl

The JETLS server is launched using the `runserver.jl` script at the root of
the repository. You can run it with various options to configure how the
server communicates with clients.

> `julia runserver.jl --help`
```
JETLS - A Julia language server providing advanced static analysis and seamless
runtime integration. Powered by JET.jl, JuliaSyntax.jl, and JuliaLowering.jl.

Usage: julia runserver.jl [OPTIONS]

Communication channel options (choose one, default: --stdio):
  --stdio                  Use standard input/output
  --pipe=<path>            Use named pipe (Windows) or Unix domain socket
  --socket=<port>          Use TCP socket on specified port

Options:
  --clientProcessId=<pid>  Monitor client process (enables crash detection)
  --help, -h               Show this help message

Examples:
  julia runserver.jl
  julia runserver.jl --socket=8080
  julia runserver.jl --pipe=/tmp/jetls.sock --clientProcessId=12345
```

## Communication channels

JETLS supports multiple communication channels between the client and server.
Choose based on your environment and requirements:

### `auto` (default for VSCode)

The `jetls-client` VSCode extension automatically selects the most appropriate
channel based on your environment:

- Local development: `pipe` for maximum safety
- Remote SSH/WSL: `pipe` (works well in these environments)
- Dev Containers: `stdio` for compatibility

### `pipe` (Unix domain socket / named pipe)

- **Advantages**: Complete isolation from `stdin`/`stdout`, preventing protocol
  corruption; fastest for local communication
- **Best for**: Local development, Remote SSH, WSL
- **Limitations**: Not suitable for cross-container communication

Example:
```bash
julia runserver.jl --pipe=/tmp/jetls.sock
```

### `socket` (TCP)

- **Advantages**: Complete isolation from `stdin`/`stdout`, preventing protocol
  corruption; works across network boundaries; supports port forwarding
- **Best for**: Remote development with port forwarding
- **Limitations**: May require firewall configuration; potentially less secure
  than local alternatives

Example:
```bash
julia runserver.jl --socket=7777
```

### `stdio`

- **Advantages**: Simplest setup; maximum compatibility; works everywhere
- **Best for**: Dev containers; environments where `pipe` doesn't work
- **Limitations**: Risk of protocol corruption if any code writes to
  `stdin`/`stdout`

Example:
```bash
julia runserver.jl --stdio
# or simply
julia runserver.jl
```

!!! warning
    When using `stdio` mode, any `println(stdout, ...)` in your code or
    dependency packages may corrupt the LSP protocol and break the connection.
    Prefer `pipe` or `socket` modes when possible.

## Client process monitoring

The `--clientProcessId` option enables the server to monitor the client process
for crash detection, where the server periodically checks whether the specified
process is still alive. If the client crashes or terminates unexpectedly, the
server will automatically shut down, ensuring proper cleanup even when the
client cannot execute the normal LSP shutdown sequence.

!!! note
    When specified via command line, the process ID should match the
    `processId` field that the client sends in the LSP `initialize` request
    parameters.
