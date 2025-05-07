# JETLS.jl

[![](https://github.com/aviatesk/JETLS.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/aviatesk/JETLS.jl/actions/workflows/ci.yml)
[![](https://codecov.io/gh/aviatesk/JETLS.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/aviatesk/JETLS.jl)

A new language server for the Julia programming language. In a nascent stage of development.

## Development

### Requirements

- VSCode v1.93.0 or higher
- npm v11.0.0 or higher
- Julia [`v"1.12.0-beta2"`](https://julialang.org/downloads/#upcoming_release) or higher

### Steps

- Run `npm install` in this folder to install all necessary node modules for the client.
- Open this folder in VSCode.
- Press <kbd>Ctrl+Shift+B</kbd> to start compiling the client and server in [watch mode](https://code.visualstudio.com/docs/editor/tasks#:~:text=The%20first%20entry%20executes,the%20HelloWorld.js%20file.).
- Switch to the Run and Debug View in the Sidebar (<kbd>Ctrl+Shift+D</kbd>).
- Select `Launch Client` from the drop-down menu (if it is not already selected).
- Press `▷` to run the launch configuration (<kbd>F5</kbd>).
- In the [Extension Development Host](https://code.visualstudio.com/api/get-started/your-first-extension#:~:text=Then%2C%20inside%20the%20editor%2C%20press%20F5.%20This%20will%20compile%20and%20run%20the%20extension%20in%20a%20new%20Extension%20Development%20Host%20window.) instance of VSCode, open a Julia file.

## Structure

This repository manages two components: the VSCode extension (`jetls-client`), which is the
language client, and the Julia package (`JETLS.jl`), which is the language server.

Although these implementations should ideally be managed separately, during the current
prototyping phase, this approach allows for easier simultaneous modifications of both
components and simpler management of the environment in which the language server runs.
In the future, these components will likely be managed separately[^1].

[^1]: Or more likely, the language client may be merged into the [julia-vscode](https://github.com/julia-vscode/julia-vscode) extension.
