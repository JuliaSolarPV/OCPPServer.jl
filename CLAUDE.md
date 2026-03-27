# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OCPPServer.jl is a Julia package implementing a Central System Management System (CSMS) for the Open Charge Point Protocol (OCPP). Part of the JuliaSolarPV ecosystem alongside OCPPData.jl (types/codecs), with planned OCPPClient.jl, ChargeHub.jl (demo CSMS), and ChargeBox.jl (demo charger simulator).

Design philosophy: **engine, not framework** — provides WebSocket transport and OCPP message plumbing only. Applications register handlers and make all business decisions. No database, auth, billing, or UI responsibilities.

## Build & Test Commands

```bash
# Run all tests
julia --project=. -e 'using Pkg; Pkg.test()'

# Format code
julia -e 'using JuliaFormatter; format(".")'

# Run all linting (pre-commit hooks: JSON/TOML/YAML validation, JuliaFormatter, markdown lint)
pre-commit run -a

# Build and serve docs locally
julia --project=docs -e 'using LiveServer; servedocs()'
```

## Architecture

```
src/
├── OCPPServer.jl       # Module root — imports, includes, exports
├── config.jl           # ServerConfig @kwdef struct
├── session.jl          # ChargePointSession mutable struct
├── central_system.jl   # CentralSystem struct + constructors
├── events.jl           # OCPPEvent abstract type + 5 concrete event types
├── routing.jl          # on!(), after!(), subscribe!(), session queries, hooks
├── outbound.jl         # send_call() + serialization helpers
└── transport.jl        # Internal: WebSocket server, message loop, handler dispatch
```

- **ServerConfig** — host, port, TLS, OCPP version support, timeouts
- **ChargePointSession** — per-connection state (WebSocket ref, pending calls, metadata)
- **CentralSystem** — sessions registry, handler/event dispatch, connection hooks
- **Handler routing** — `on!(cs, "ActionName", handler)` and `after!(cs, "ActionName", callback)`
- **Outbound calls** — `send_call(session, action, payload)` with Channel-based response matching
- **Event system** — abstract `OCPPEvent` with subtypes for connection lifecycle
- **Transport** — `HTTP.listen!` with Stream handler, manual `Sec-WebSocket-Protocol` header + `HTTP.WebSockets.upgrade`

### Key dependencies

- **OCPPData.jl** (local dev dep at `../OCPPData.jl`) — OCPP types, encode/decode, validation
- **HTTP.jl** — WebSocket server via `HTTP.listen!` + `HTTP.WebSockets.upgrade`
- **JSON.jl** — serialization (note: `JSON.parse` returns `JSON.Object`, not `Dict`; use `_to_string_dict` helper)

### HTTP.jl API notes

- Use `HTTP.listen!` (Stream handler), NOT `HTTP.WebSockets.listen!`, to support subprotocol negotiation
- Set `Sec-WebSocket-Protocol` header via `HTTP.setheader(http, ...)` before `HTTP.WebSockets.upgrade(http)`
- `HTTP.WebSockets.send(ws, data)` / `HTTP.WebSockets.receive(ws)` for messages
- `HTTP.WebSockets.isclosed(ws)` to check state (no `isopen`)
- `Sockets.getsockname(server.listener.server)[2]` to get actual bound port (not `HTTP.port`)
- `for msg in ws` iteration works for reading messages

OCPP protocol schemas live in `ocpp-files/` (v1.6 and v2.0.1 JSON schemas). Design spec in `ocpp-files/OCPP_SERVER_DESIGN.md`.

## Code Style

- **Formatter**: JuliaFormatter with indent=4, margin=92, Unix line endings (`.JuliaFormatter.toml`)
- **Testing**: TestItemRunner + TestItems framework — tests use `@testitem`, `@testsnippet`, `@testmodule` (not standard `@testset`)
- **Template**: Generated from BestieTemplate.jl — follow its conventions for CI, docs, and project structure
- **Julia compat**: 1.10+
- **do-block API**: All public registration functions (`on!`, `after!`, `subscribe!`, `set_connection_validator!`, `set_message_logger!`) have function-first method overloads for `do` block syntax

## CI/CD

- **Test.yml** — matrix across Julia LTS + latest, Ubuntu/macOS/Windows
- **Lint.yml** — JuliaFormatter check, pre-commit hooks, markdown/YAML/CFF linting, link checking (Lychee)
- **Docs.yml** — Documenter.jl build + deploy to GitHub Pages
- **Pre-commit hooks** must pass before push (install with `pre-commit install`)
