# Architecture

OCPPServer.jl is organized into layers with clear responsibilities. The transport layer is
internal — everything else is part of the public API.

## Layer overview

```text
┌──────────────────────────────────────────────────────┐
│  Public API                                          │
│  routing.jl                                          │
│  on!, after!, subscribe!, session queries, hooks      │
├──────────────────────────────────────────────────────┤
│  Outbound calls                                      │
│  outbound.jl                                         │
│  send_call, response matching, serialization          │
├──────────────────────────────────────────────────────┤
│  Transport (internal)                                │
│  transport.jl                                        │
│  start!, stop!, WebSocket server, message loop        │
├──────────────────────────────────────────────────────┤
│  Core types                                          │
│  config.jl, session.jl, central_system.jl, events.jl │
│  ServerConfig, ChargePointSession, CentralSystem      │
└──────────────────────────────────────────────────────┘
```

## Core types

### ServerConfig (`config.jl`)

A `@kwdef` struct holding all server configuration. Created directly or via keyword
arguments forwarded from the `CentralSystem` constructor.

### ChargePointSession (`session.jl`)

Mutable struct representing one connected charge point:

| Field | Type | Description |
|-------|------|-------------|
| `id` | `String` | Charge point ID (from URL path) |
| `ws` | `WebSocket` | Active WebSocket connection |
| `status` | `Symbol` | `:connected` or `:disconnected` |
| `version` | `Symbol` | `:v16` or `:v201` |
| `pending_calls` | `Dict{String, Channel}` | Outbound calls awaiting responses |
| `metadata` | `Dict{String, Any}` | Free-form application data |
| `connected_at` | `DateTime` | Connection timestamp (UTC) |
| `last_seen` | `DateTime` | Last message timestamp (UTC) |

### CentralSystem (`central_system.jl`)

The main server object holding sessions, handlers, event listeners, and hooks:

| Field | Type | Description |
|-------|------|-------------|
| `config` | `ServerConfig` | Server configuration |
| `sessions` | `Dict{String, ChargePointSession}` | Connected sessions by ID |
| `handlers` | `Dict{String, Function}` | Action -> handler (via `on!`) |
| `after_handlers` | `Dict{String, Function}` | Action -> post-response callback (via `after!`) |
| `listeners` | `Vector{Function}` | Event callbacks (via `subscribe!`) |
| `connection_validator` | `Function` or `nothing` | Accept/reject hook |
| `message_logger` | `Function` or `nothing` | Raw message logging hook |
| `lock` | `ReentrantLock` | Guards the sessions dict |

## Transport layer (`transport.jl`)

All functions in this file are internal (prefixed with `_`) and not exported.

### Server startup

`start!(cs)` calls `_start_server(cs)` which creates an `HTTP.listen!` handler. The handler
is a Stream-based HTTP handler (not `HTTP.WebSockets.listen!`) because OCPP requires
subprotocol negotiation:

1. Extract charge point ID from the URL path
2. Detect OCPP version from the `Sec-WebSocket-Protocol` request header
3. Run the connection validator (if registered)
4. Set the `Sec-WebSocket-Protocol` response header
5. Call `HTTP.WebSockets.upgrade` to complete the WebSocket handshake

### Connection lifecycle

`_handle_connection(cs, cp_id, ws, version)` manages a single charge point session:

1. Create a `ChargePointSession`
2. Handle duplicate connections (close old session, emit `:replaced` disconnect event)
3. Register the session and emit `ChargePointConnected`
4. Start a ping/pong keepalive loop
5. Enter the message loop
6. On exit: mark disconnected, clean up pending calls, emit `ChargePointDisconnected`

### Message loop

`_message_loop(cs, session)` iterates over WebSocket frames:

```text
for raw_frame in ws
    log raw message (if logger registered)
    msg = OCPPData.decode(raw_frame)
    emit MessageReceived event
    if msg isa Call       -> _handle_incoming_call
    if msg isa CallResult -> _resolve_pending (match to send_call)
    if msg isa CallError  -> _resolve_pending
end
```

### Incoming call dispatch

`_handle_incoming_call(cs, session, call)`:

1. Optional schema validation via `OCPPData.validate`
2. Look up handler in `cs.handlers[call.action]`
3. Deserialize payload to typed request struct via `OCPPData.V16.request_type` or `V201.request_type`
4. Call the handler
5. Serialize response and send `CallResult`
6. Fire `after!` handler asynchronously (if registered)

## Outbound calls (`outbound.jl`)

`send_call(session, action, payload; timeout)` implements the server -> charger
request/response cycle:

1. Generate a UUID `unique_id` via `OCPPData.generate_unique_id()`
2. Serialize the payload and encode as a `Call` frame
3. Create a `Channel{OCPPMessage}(1)` and store in `session.pending_calls[unique_id]`
4. Send the frame over the WebSocket
5. `timedwait` on the channel — the message loop deposits the matching response
6. On timeout: clean up and throw; on `CallError`: throw
7. Deserialize the `CallResult` payload to a typed response struct

## Serialization helpers

- `_serialize_response(response)` — typed struct -> `Dict{String,Any}` via JSON round-trip
- `_deserialize_payload(payload, T)` — `Dict{String,Any}` -> typed struct `T` via JSON round-trip
- `_to_string_dict(obj)` — recursively converts `JSON.Object` to `Dict{String,Any}`
  (needed because `JSON.parse` returns `JSON.Object`, not `Dict`)

## Design philosophy

OCPPServer.jl intentionally does **not** include:

- Database or persistence
- Authorization decisions
- Transaction state machines
- Smart charging algorithms
- Billing or pricing
- REST API or web UI

All of these belong in application packages that depend on OCPPServer.jl. The server
provides the plumbing; applications make all business decisions through registered handlers.
