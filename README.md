# OCPPServer.jl

[![Development documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaSolarPV.github.io/OCPPServer.jl/dev)
[![Test workflow status](https://github.com/JuliaSolarPV/OCPPServer.jl/actions/workflows/Test.yml/badge.svg?branch=main)](https://github.com/JuliaSolarPV/OCPPServer.jl/actions/workflows/Test.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/JuliaSolarPV/OCPPServer.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/JuliaSolarPV/OCPPServer.jl)
[![Lint workflow Status](https://github.com/JuliaSolarPV/OCPPServer.jl/actions/workflows/Lint.yml/badge.svg?branch=main)](https://github.com/JuliaSolarPV/OCPPServer.jl/actions/workflows/Lint.yml?query=branch%3Amain)
[![Docs workflow Status](https://github.com/JuliaSolarPV/OCPPServer.jl/actions/workflows/Docs.yml/badge.svg?branch=main)](https://github.com/JuliaSolarPV/OCPPServer.jl/actions/workflows/Docs.yml?query=branch%3Amain)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![tested with JET.jl](https://img.shields.io/badge/%F0%9F%9B%A9%EF%B8%8F_tested_with-JET.jl-233f9a)](https://github.com/aviatesk/JET.jl)

OCPPServer.jl is a Julia WebSocket server for [OCPP](https://www.openchargealliance.org/) (Open
Charge Point Protocol) Central System Management Software (CSMS). It accepts connections from
charge points, dispatches OCPP actions to registered handlers, and sends commands back to chargers
— all with typed Julia structs, no manual JSON required. Built on
[HTTP.jl](https://github.com/JuliaWeb/HTTP.jl) and
[OCPPData.jl](https://github.com/JuliaSolarPV/OCPPData.jl).

It is an **engine, not a framework** — it provides WebSocket transport and OCPP message plumbing
only. Applications register handlers and make all decisions about authorization, transactions,
smart charging, and persistence.

- **OCPP 1.6 and 2.0.1** — configure supported versions per server
- **Handler-based routing** — register handlers with `on!` for each OCPP action
- **Post-response callbacks** — `after!` for slow work like DB writes
- **Server-to-charger calls** — `send_call` with typed responses and timeout
- **Event system** — `subscribe!` to connection lifecycle events
- **Connection validation** — accept/reject chargers with `set_connection_validator!`
- **Message logging** — raw OCPP-J logging via `set_message_logger!`
- **Thread-safe** — concurrent charge point connections with locked session registry

## Example Usage

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

on!(cs, "StatusNotification") do session, req
    StatusNotificationResponse()
end

subscribe!(cs) do event
    if event isa ChargePointConnected
        @info "Charger connected" id=event.charge_point_id version=event.version
    elseif event isa ChargePointDisconnected
        @info "Charger disconnected" id=event.charge_point_id reason=event.reason
    end
end

@info "Starting OCPP server on :9000"
start!(cs)  # blocks
```

### Sending commands to a charger

```julia
session = get_session(cs, "CP001")
resp = send_call(session, "Reset", Dict("type" => "Hard"); timeout=10.0)
@info "Reset result" status=resp.status
```

### Connection validation

```julia
set_connection_validator!(cs) do cp_id, request
    cp_id in ALLOWED_CHARGERS
end
```

### Post-response callbacks

```julia
on!(cs, "StartTransaction") do session, req
    StartTransactionResponse(;
        transaction_id = assign_tx_id(),
        id_tag_info = IdTagInfo(; status = AuthorizationAccepted),
    )
end

after!(cs, "StartTransaction") do session, req, resp
    save_transaction_to_db(resp.transaction_id, session.id, req)
end
```

## How to Cite

If you use OCPPServer.jl in your work, please cite using the reference given in [CITATION.cff](https://github.com/JuliaSolarPV/OCPPServer.jl/blob/main/CITATION.cff).

## Contributing

If you want to make contributions of any kind, please first take a look into our [contributing guide directly on GitHub](docs/src/90-contributing.md) or the [contributing page on the website](https://JuliaSolarPV.github.io/OCPPServer.jl/dev/90-contributing/).
