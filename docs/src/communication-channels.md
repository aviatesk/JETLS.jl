# Communication channels

JETLS supports multiple communication channels between the client and server.
Choose based on your environment and requirements:

## `auto` (default for VSCode)

The `jetls-client` VSCode extension automatically selects the most appropriate
channel based on your environment:

- Local development: `pipe` for maximum safety
- Remote SSH/WSL: `pipe` (works well in these environments)
- Dev Containers: `stdio` for compatibility

## `pipe` (Unix domain socket / named pipe)

- **Advantages**: Complete isolation from `stdin`/`stdout`, preventing protocol
  corruption; fastest for local communication
- **Best for**: Local development, Remote SSH, WSL
- **Limitations**: Not suitable for cross-container communication

## `socket` (TCP)

- **Advantages**: Complete isolation from `stdin`/`stdout`, preventing protocol
  corruption; works across network boundaries; supports port forwarding
- **Best for**: Remote development with port forwarding
- **Limitations**: May require firewall configuration; potentially less secure
  than local alternatives

## `stdio`

- **Advantages**: Simplest setup; maximum compatibility; works everywhere
- **Best for**: Dev containers; environments where `pipe` doesn't work
- **Limitations**: Risk of protocol corruption if any code writes to
  `stdin`/`stdout`

!!! warning
    When using `stdio` mode, any `println(stdout, ...)` in your code or
    dependency packages may corrupt the LSP protocol and break the connection.
    Prefer `pipe` or `socket` modes when possible.

## Command-line usage

When using JETLS from the command line or with other editors:

```bash
# Standard input/output (default, --stdio can be omitted)
julia runserver.jl --stdio

# Unix domain socket or Windows named pipe
julia runserver.jl --pipe=/tmp/jetls.sock

# TCP socket
julia runserver.jl --socket=7777
```
