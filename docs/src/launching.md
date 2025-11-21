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
  --stdio                     Use standard input/output
  --pipe-connect=<path>       Connect to client's Unix domain socket/named pipe
  --pipe-listen=<path>        Listen on Unix domain socket/named pipe
  --socket=<port>             Listen on TCP socket

Options:
  --clientProcessId=<pid>     Monitor client process (enables crash detection)
  --help, -h                  Show this help message

Examples:
  julia runserver.jl
  julia runserver.jl --socket=8080
  julia runserver.jl --pipe-connect=/tmp/jetls.sock --clientProcessId=12345
  julia runserver.jl --pipe-listen=/tmp/jetls.sock
```

## Communication channels

`runserver.jl` supports multiple communication channels between the client and server.
Choose based on your environment and requirements:

### `pipe-connect` / `pipe-listen` (Unix domain socket / named pipe)

- **Advantages**: Complete isolation from `stdin`/`stdout`, preventing protocol
  corruption; fastest for local communication
- **Best for**: Local development, Remote SSH, WSL
- **Limitations**: Not suitable for cross-container communication
- **Note**: Client is responsible for socket file cleanup in both modes

`runserver.jl` provides two pipe modes:

#### `pipe-connect`

Server connects to a client-created socket. This is the mode used by the
`jetls-client` VSCode extension and is generally easier to implement:

- Client creates and listens on the socket first
- Client spawns the server process
- Server immediately connects to the client's socket
- **No stdout monitoring required** - simpler client implementation

Example:
```bash
julia runserver.jl --pipe-connect=/tmp/jetls.sock
```

#### `pipe-listen`

Server creates and listens on a socket, then waits for the client to connect.
This is the traditional LSP server mode:

- Client spawns the server process
- Server creates socket and prints `<JETLS-PIPE-READY>/tmp/jetls.sock</JETLS-PIPE-READY>` to stdout
- **Client must monitor stdout** for the readiness notification
- Client connects to the socket after receiving notification

Example:
```bash
julia runserver.jl --pipe-listen=/tmp/jetls.sock
```

### `socket` (TCP)

- **Advantages**: Complete isolation from `stdin`/`stdout`, preventing protocol
  corruption; works across network boundaries; supports port forwarding
- **Best for**: Manual remote connection across different machines (without
  VSCode Remote); shared server accessed by multiple developers
- **Limitations**: May require firewall configuration; potentially less secure
  than local alternatives

Example:
```bash
julia runserver.jl --socket=7777
```

The server will print `<JETLS-PORT>7777</JETLS-PORT>` to stdout once it starts
listening. This is especially useful when using `--socket=0` for automatic port
assignment, as the actual port number will be announced:

```bash
julia runserver.jl --socket=0
# Output: <JETLS-PORT>54321</JETLS-PORT>  (actual port assigned by OS)
```

Use with SSH port forwarding to connect from a different machine:
```bash
ssh -L 8080:localhost:8080 user@remote
# Then connect your local client to localhost:8080
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

## Communication channel configuration for VSCode (`jetls-client`)

The [`jetls-client`](https://marketplace.visualstudio.com/items?itemName=aviatesk.jetls-client)
VSCode extension by default automatically selects the most appropriate
communication channel based on your environment:

- **Local development**: `pipe` (`pipe-connect`)
- **Remote SSH/WSL**: `pipe` (`pipe-connect`, extension runs in remote environment)
- **Dev Containers**: `stdio`

This automatic selection ensures optimal performance and reliability without
requiring manual configuration.

### Manual channel selection

You can override the automatic selection by configuring
`jetls-client.communicationChannel` in VSCode settings:

- `auto` (default): Automatic selection as described above
- `pipe`: Uses `pipe-connect` mode
- `socket`: Uses TCP socket (configure port with `jetls-client.socketPort`)
- `stdio`: Uses standard input/output

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
