"""
    on!(cs::CentralSystem, action::String, handler::Function)
    on!(handler::Function, cs::CentralSystem, action::String)

Register a handler for an incoming OCPP action (charger -> server).

The handler must return a typed OCPPData.jl response struct.
Signature: `handler(session::ChargePointSession, request) -> response`
"""
function on!(cs::CentralSystem, action::String, handler::Function)
    cs.handlers[action] = handler
    return nothing
end
on!(handler::Function, cs::CentralSystem, action::String) = on!(cs, action, handler)

"""
    after!(cs::CentralSystem, action::String, handler::Function)
    after!(handler::Function, cs::CentralSystem, action::String)

Register a post-response callback for an OCPP action.

Runs after the CallResult has been sent. Use for slow operations like DB writes.
Signature: `handler(session::ChargePointSession, request, response) -> nothing`
"""
function after!(cs::CentralSystem, action::String, handler::Function)
    cs.after_handlers[action] = handler
    return nothing
end
after!(handler::Function, cs::CentralSystem, action::String) = after!(cs, action, handler)

"""
    subscribe!(cs::CentralSystem, callback::Function)
    subscribe!(callback::Function, cs::CentralSystem)

Subscribe to all events emitted by the server.
Signature: `callback(event::OCPPEvent) -> nothing`
"""
function subscribe!(cs::CentralSystem, callback::Function)
    push!(cs.listeners, callback)
    return nothing
end
subscribe!(callback::Function, cs::CentralSystem) = subscribe!(cs, callback)

"""
    set_connection_validator!(cs::CentralSystem, validator::Function)
    set_connection_validator!(validator::Function, cs::CentralSystem)

Register a function to accept or reject incoming WebSocket connections.
Signature: `validator(charge_point_id::String, request::HTTP.Request) -> Bool`
"""
function set_connection_validator!(cs::CentralSystem, validator::Function)
    cs.connection_validator = validator
    return nothing
end
set_connection_validator!(validator::Function, cs::CentralSystem) =
    set_connection_validator!(cs, validator)

"""
    set_message_logger!(cs::CentralSystem, logger::Function)
    set_message_logger!(logger::Function, cs::CentralSystem)

Register a function that receives every raw OCPP-J message for logging.
Signature: `logger(direction::Symbol, charge_point_id::String, raw::String) -> nothing`
"""
function set_message_logger!(cs::CentralSystem, logger::Function)
    cs.message_logger = logger
    return nothing
end
set_message_logger!(logger::Function, cs::CentralSystem) = set_message_logger!(cs, logger)

"""
    list_sessions(cs::CentralSystem) -> Vector{ChargePointSession}

Return all currently connected sessions. Thread-safe snapshot.
"""
function list_sessions(cs::CentralSystem)::Vector{ChargePointSession}
    return lock(cs.lock) do
        collect(values(cs.sessions))
    end
end

"""
    get_session(cs::CentralSystem, id::String) -> ChargePointSession

Get a session by charge point ID. Throws `KeyError` if not connected.
"""
function get_session(cs::CentralSystem, id::String)::ChargePointSession
    return lock(cs.lock) do
        cs.sessions[id]
    end
end

"""
    is_connected(cs::CentralSystem, id::String) -> Bool

Check if a charge point is currently connected.
"""
function is_connected(cs::CentralSystem, id::String)::Bool
    return lock(cs.lock) do
        haskey(cs.sessions, id)
    end
end
