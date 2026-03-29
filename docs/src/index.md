```@meta
CurrentModule = OCPPServer
```

# OCPPServer.jl

OCPPServer.jl is a Julia WebSocket server for OCPP (Open Charge Point Protocol) Central System
Management Software (CSMS). It accepts connections from charge points, dispatches OCPP actions
to registered handlers, and sends commands back to chargers — all with typed Julia structs, no
manual JSON required. Built on top of [HTTP.jl](https://github.com/JuliaWeb/HTTP.jl) and
[OCPPData.jl](https://github.com/JuliaSolarPV/OCPPData.jl).

## Features

- **OCPP 1.6 and 2.0.1** — configure supported versions per server
- **Handler-based routing** — register handlers with `on!` for each OCPP action
- **Post-response callbacks** — `after!` for slow work (DB writes, logging) that should not
  delay the OCPP response
- **Server-to-charger calls** — `send_call` with Channel-based response matching and timeout
- **Event system** — `subscribe!` to connection lifecycle events
- **Connection validation** — accept/reject chargers with `set_connection_validator!`
- **Message logging** — raw OCPP-J logging via `set_message_logger!`
- **Thread-safe** — concurrent charge point connections with locked session registry

## Quick start

```julia
using OCPPServer, OCPPData.V16, Dates

cs = CentralSystem(port=9000)

on!(cs, "BootNotification") do session, req
    session.metadata["vendor"] = req.charge_point_vendor
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

start!(cs)  # blocks — use @async for non-blocking
```

## Package structure

```text
OCPPServer.jl/
├── src/
│   ├── OCPPServer.jl       # Module entry point, exports
│   ├── config.jl           # ServerConfig struct
│   ├── session.jl          # ChargePointSession struct
│   ├── central_system.jl   # CentralSystem struct, constructors
│   ├── events.jl           # OCPPEvent types
│   ├── routing.jl          # on!, after!, subscribe!, session queries
│   ├── outbound.jl         # send_call, response matching
│   └── transport.jl        # WebSocket server, message loop (internal)
├── test/
│   ├── runtests.jl
│   ├── test-config.jl
│   ├── test-events.jl
│   ├── test-routing.jl
│   ├── test-integration.jl
│   └── test-client-server.jl
└── docs/
    └── src/                # This documentation
```

## Contributors

```@raw html
<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->
```
