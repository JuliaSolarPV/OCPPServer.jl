# User guide

## Creating a server

Create a `CentralSystem` with configuration options. All keyword arguments are forwarded to
`ServerConfig`:

```julia
using OCPPServer

cs = CentralSystem(
    port = 9000,                      # WebSocket port (default: 9000)
    host = "0.0.0.0",                 # bind address (default: "0.0.0.0")
    path_prefix = "/ocpp",            # URL path prefix (default: "/ocpp")
    supported_versions = [:v16],      # :v16, :v201, or both (default: [:v16])
    heartbeat_timeout = 600.0,        # seconds of no messages before stale (default: 600)
    default_call_timeout = 30.0,      # timeout for send_call (default: 30)
    validate_messages = false,        # validate payloads against JSON schemas (default: false)
    ping_interval = 30.0,             # WebSocket ping/pong interval (default: 30)
)
```

Charge points connect to `ws://{host}:{port}{path_prefix}/{charge_point_id}`. For example,
a charger with ID `CP001` connects to `ws://localhost:9000/ocpp/CP001`.

## Starting and stopping

`start!` blocks the current task, so wrap it in `@async` or `Threads.@spawn` for non-blocking
operation:

```julia
# Blocking (for scripts)
start!(cs)

# Non-blocking (for REPL or applications)
server_task = @async start!(cs)
```

To shut down the server and close all connections:

```julia
stop!(cs)
```

`stop!` emits a `ChargePointDisconnected` event for every connected session before closing.

## Handling incoming calls

When a charge point sends a Call (e.g., `BootNotification`, `Heartbeat`), the server
deserializes the payload to a typed OCPPData.jl struct, calls your handler, and serializes
the response back.

Register handlers with `on!` using do-block syntax:

```julia
using OCPPData.V16, Dates

on!(cs, "BootNotification") do session, req
    session.metadata["vendor"] = req.charge_point_vendor
    session.metadata["model"] = req.charge_point_model
    BootNotificationResponse(;
        current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
        interval = 300,
        status = RegistrationAccepted,
    )
end

on!(cs, "Heartbeat") do session, req
    HeartbeatResponse(;
        current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
    )
end

on!(cs, "StatusNotification") do session, req
    StatusNotificationResponse()
end
```

The handler receives:

- `session` — a `ChargePointSession` with the charger's ID, version, metadata, etc.
- `req` — a typed request struct (e.g., `OCPPData.V16.BootNotificationRequest`)

The handler **must return** a typed response struct. OCPPServer serializes it automatically.

If no handler is registered for an action, the server sends `CallError("NotImplemented")`.
If the handler throws, the server sends `CallError("InternalError")` and emits a
`HandlerError` event.

## Post-response callbacks

Use `after!` for work that should happen **after** the response has been sent to the charger.
This keeps OCPP responses fast while allowing slow operations like database writes:

```julia
on!(cs, "StartTransaction") do session, req
    StartTransactionResponse(;
        transaction_id = assign_tx_id(),
        id_tag_info = IdTagInfo(; status = AuthorizationAccepted),
    )
end

after!(cs, "StartTransaction") do session, req, resp
    # This runs after the response is already sent
    save_transaction_to_db(resp.transaction_id, session.id, req)
end
```

Exceptions in `after!` handlers are caught and logged — they never affect the response or
the connection.

## Sending commands to chargers

Use `send_call` to send an OCPP Call from the server to a connected charger and wait for the
response:

```julia
session = get_session(cs, "CP001")

# Send Reset
resp = send_call(session, "Reset", Dict("type" => "Hard"); timeout=10.0)
@info "Reset result" status=resp.status

# Send RemoteStartTransaction
resp = send_call(session, "RemoteStartTransaction",
    Dict("idTag" => "USER001", "connectorId" => 1))
```

`send_call` blocks until the charger responds or the timeout expires. It returns a typed
response struct (e.g., `ResetResponse`). On timeout or `CallError`, it throws an
`ErrorException`.

## Session queries

```julia
# List all connected sessions
sessions = list_sessions(cs)

# Get a specific session (throws KeyError if not connected)
session = get_session(cs, "CP001")

# Check if a charger is connected
if is_connected(cs, "CP001")
    # ...
end
```

The `session.metadata` dict is a free-form bag for application data. The server never reads
or writes to it — use it to stash vendor info, connector statuses, transaction IDs, etc.

## Connection validation

Accept or reject incoming connections based on charger identity or HTTP headers:

```julia
set_connection_validator!(cs) do cp_id, request
    if cp_id in ALLOWED_CHARGERS
        return true
    end
    @warn "Rejected unknown charger" id=cp_id
    return false
end
```

The validator receives the charge point ID (extracted from the URL path) and the raw
`HTTP.Request` (for inspecting headers, e.g., Basic Auth). If no validator is set, all
connections are accepted.

## Event subscriptions

Subscribe to lifecycle events with `subscribe!`:

```julia
subscribe!(cs) do event
    if event isa ChargePointConnected
        @info "Connected" id=event.charge_point_id version=event.version
    elseif event isa ChargePointDisconnected
        @info "Disconnected" id=event.charge_point_id reason=event.reason
    elseif event isa HandlerError
        @error "Handler failed" id=event.charge_point_id action=event.action
    end
end
```

Available event types:

| Type | Fields | When fired |
|------|--------|------------|
| `ChargePointConnected` | `charge_point_id`, `timestamp`, `version` | WebSocket opened and validated |
| `ChargePointDisconnected` | `charge_point_id`, `timestamp`, `reason` | WebSocket closed (`:normal`, `:error`, `:replaced`) |
| `MessageReceived` | `charge_point_id`, `message`, `timestamp` | Incoming message decoded |
| `MessageSent` | `charge_point_id`, `message`, `timestamp` | Outgoing message sent |
| `HandlerError` | `charge_point_id`, `action`, `error`, `timestamp` | Handler threw an exception |

## Message logging

Log every raw OCPP-J message for debugging or auditing:

```julia
set_message_logger!(cs) do direction, cp_id, raw
    prefix = direction == :inbound ? "<-" : "->"
    println("[$cp_id] $prefix $raw")
end
```

`direction` is `:inbound` (charger -> server) or `:outbound` (server -> charger).
`raw` is the complete OCPP-J JSON array as it appears on the wire.

## OCPP version support

Configure supported versions via `supported_versions`:

```julia
# V1.6 only (default)
cs = CentralSystem(supported_versions = [:v16])

# V2.0.1 only
cs = CentralSystem(supported_versions = [:v201])

# Both
cs = CentralSystem(supported_versions = [:v16, :v201])
```

The server detects the OCPP version from the `Sec-WebSocket-Protocol` header sent by the
charger (`"ocpp1.6"` or `"ocpp2.0.1"`) and stores it in `session.version`. Handlers receive
typed structs from the appropriate OCPPData version module.
