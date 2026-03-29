"""
    start!(cs::CentralSystem)

Start the OCPP WebSocket server. This function blocks.
Run it with `@async` or `Threads.@spawn` for non-blocking operation.
"""
function start!(cs::CentralSystem)
    _start_server(cs)
    server = cs._server
    server === nothing && error("Server failed to start")
    return wait(server)
end

"""
    stop!(cs::CentralSystem)

Stop the server and close all active WebSocket connections.
Emits ChargePointDisconnected events for all connected sessions.
"""
function stop!(cs::CentralSystem)
    # Close all active sessions
    sessions = lock(cs.lock) do
        collect(values(cs.sessions))
    end
    for session in sessions
        try
            close(session.ws)
        catch
        end
        _emit(cs, ChargePointDisconnected(session.id, now(UTC), :normal))
    end
    lock(cs.lock) do
        empty!(cs.sessions)
    end

    # Close the server
    server = cs._server
    if server !== nothing
        close(server)
        cs._server = nothing
    end
    return nothing
end

"""Start the HTTP/WebSocket server and accept connections."""
function _start_server(cs::CentralSystem)
    handler = function (http::HTTP.Stream)
        request = http.message

        # 1. Extract charge point ID from URL path
        cp_id = _extract_cp_id(request, cs.config.path_prefix)
        if cp_id === nothing
            HTTP.setstatus(http, 404)
            HTTP.startwrite(http)
            write(http, "Invalid path")
            return
        end

        # 2. Detect OCPP version from Sec-WebSocket-Protocol header
        version = _detect_version(request, cs.config.supported_versions)
        if version === nothing
            HTTP.setstatus(http, 400)
            HTTP.startwrite(http)
            write(http, "Unsupported OCPP version")
            return
        end

        # 3. Call connection validator (if registered)
        if cs.connection_validator !== nothing
            if !cs.connection_validator(cp_id, request)
                HTTP.setstatus(http, 401)
                HTTP.startwrite(http)
                write(http, "Connection rejected")
                return
            end
        end

        # 4. Set subprotocol header and upgrade to WebSocket
        HTTP.setheader(http, "Sec-WebSocket-Protocol" => _version_to_subprotocol(version))
        HTTP.WebSockets.upgrade(http) do ws
            _handle_connection(cs, cp_id, ws, version)
        end
    end

    cs._server = HTTP.listen!(handler, cs.config.host, cs.config.port)
    return nothing
end

"""Handle a single charge point's WebSocket connection lifecycle."""
function _handle_connection(
    cs::CentralSystem,
    cp_id::String,
    ws::HTTP.WebSockets.WebSocket,
    version::Symbol,
)
    session = ChargePointSession(cp_id, ws, version)

    # Handle duplicate connection (same ID already connected)
    lock(cs.lock) do
        if haskey(cs.sessions, cp_id)
            old = cs.sessions[cp_id]
            try
                close(old.ws)
            catch
            end
            _emit(cs, ChargePointDisconnected(cp_id, now(UTC), :replaced))
        end
        cs.sessions[cp_id] = session
    end

    _emit(cs, ChargePointConnected(cp_id, now(UTC), version))

    try
        @async _ping_loop(ws, cs.config.ping_interval)
        _message_loop(cs, session)
    catch e
        if !(e isa HTTP.WebSockets.WebSocketError || e isa EOFError)
            @warn "Connection error" charge_point = cp_id exception = e
        end
    finally
        session.status = :disconnected
        lock(cs.lock) do
            delete!(cs.sessions, cp_id)
        end
        for (_, ch) in session.pending_calls
            close(ch)
        end
        empty!(session.pending_calls)
        _emit(cs, ChargePointDisconnected(cp_id, now(UTC), :normal))
    end
    return nothing
end

"""Process messages from a charge point until disconnect."""
function _message_loop(cs::CentralSystem, session::ChargePointSession)
    for raw_msg in session.ws
        raw_msg isa AbstractString || raw_msg isa AbstractVector{UInt8} || continue
        raw = String(raw_msg)
        session.last_seen = now(UTC)

        # Log raw message
        if cs.message_logger !== nothing
            try
                cs.message_logger(:inbound, session.id, raw)
            catch
            end
        end

        # Decode OCPP-J message
        msg = try
            OCPPData.decode(raw)
        catch e
            @warn "Malformed OCPP-J message, closing connection" charge_point =
                session.id exception = e
            close(session.ws)
            return
        end

        _emit(cs, MessageReceived(session.id, msg, now(UTC)))

        if msg isa OCPPData.Call
            _handle_incoming_call(cs, session, msg)
        elseif msg isa OCPPData.CallResult || msg isa OCPPData.CallError
            _resolve_pending(session, msg)
        end
    end
    return nothing
end

"""Handle an incoming Call from a charge point."""
function _handle_incoming_call(
    cs::CentralSystem,
    session::ChargePointSession,
    call::OCPPData.Call,
)
    # 1. Optional schema validation
    if cs.config.validate_messages
        spec = if session.version == :v16
            OCPPData.V16.Spec()
        else
            OCPPData.V201.Spec()
        end
        err = OCPPData.validate(spec, call.action, call.payload, :request)
        if err !== nothing
            _send_error(cs, session, call.unique_id, "FormationViolation", string(err))
            return
        end
    end

    # 2. Look up handler
    handler = get(cs.handlers, call.action, nothing)
    if handler === nothing
        _send_error(
            cs,
            session,
            call.unique_id,
            "NotImplemented",
            "No handler registered for $(call.action)",
        )
        return
    end

    # 3. Deserialize payload to typed request struct
    RequestType = _request_type(call.action, session.version)
    request = _deserialize_payload(call.payload, RequestType)

    # 4. Call handler
    response = try
        handler(session, request)
    catch e
        _emit(cs, HandlerError(session.id, call.action, e, now(UTC)))
        _send_error(cs, session, call.unique_id, "InternalError", string(e))
        return
    end

    # 5. Serialize response and send CallResult
    response_payload = _serialize_response(response)
    result = OCPPData.CallResult(call.unique_id, response_payload)
    _send_message(cs, session, result)

    # 6. Call after-handler (async, non-blocking, errors caught)
    _run_after_handler(cs, session, call.action, request, response)
    return nothing
end

"""Run after-handler asynchronously if registered. Errors are caught and logged."""
function _run_after_handler(
    cs::CentralSystem,
    session::ChargePointSession,
    action::String,
    request,
    response,
)
    after_handler = get(cs.after_handlers, action, nothing)
    if after_handler !== nothing
        @async try
            after_handler(session, request, response)
        catch e
            @warn "after! handler error" action charge_point = session.id exception = e
        end
    end
    return nothing
end

"""Send an OCPP-J message on the wire and emit MessageSent event."""
function _send_message(
    cs::CentralSystem,
    session::ChargePointSession,
    msg::OCPPData.OCPPMessage,
)
    raw = OCPPData.encode(msg)
    Sockets.send(session.ws, raw)

    if cs.message_logger !== nothing
        try
            cs.message_logger(:outbound, session.id, raw)
        catch
        end
    end

    _emit(cs, MessageSent(session.id, msg, now(UTC)))
    return nothing
end

"""Send a CallError response."""
function _send_error(
    cs::CentralSystem,
    session::ChargePointSession,
    unique_id::String,
    error_code::String,
    description::String,
)
    err = OCPPData.CallError(unique_id, error_code, description, Dict{String,Any}())
    _send_message(cs, session, err)
    return nothing
end

"""Emit an event to all subscribers. Exceptions are caught and logged."""
function _emit(cs::CentralSystem, event::OCPPEvent)
    for listener in cs.listeners
        try
            listener(event)
        catch e
            @warn "Event listener error" event_type = typeof(event) exception = e
        end
    end
    return nothing
end

"""Extract charge point ID from the request URL path."""
function _extract_cp_id(request::HTTP.Request, prefix::String)::Union{String,Nothing}
    path = HTTP.URI(request.target).path
    if startswith(path, prefix * "/")
        id = path[(length(prefix)+2):end]
        return isempty(id) ? nothing : id
    end
    return nothing
end

"""Detect OCPP version from the Sec-WebSocket-Protocol header."""
function _detect_version(
    request::HTTP.Request,
    supported::Vector{Symbol},
)::Union{Symbol,Nothing}
    protocols = HTTP.header(request, "Sec-WebSocket-Protocol", "")
    if contains(protocols, "ocpp2.0.1") && :v201 in supported
        return :v201
    elseif contains(protocols, "ocpp1.6") && :v16 in supported
        return :v16
    end
    # Fallback: if only one version is supported, use it
    return length(supported) == 1 ? first(supported) : nothing
end

"""Convert version symbol to WebSocket subprotocol string."""
function _version_to_subprotocol(version::Symbol)::String
    return version == :v16 ? "ocpp1.6" : "ocpp2.0.1"
end

"""Look up the request type for an action using OCPPData's type registry."""
function _request_type(action::String, version::Symbol)
    if version == :v16
        return OCPPData.V16.request_type(action)
    else
        return OCPPData.V201.request_type(action)
    end
end

"""Look up the response type for an action using OCPPData's type registry."""
function _response_type(action::String, version::Symbol)
    if version == :v16
        return OCPPData.V16.response_type(action)
    else
        return OCPPData.V201.response_type(action)
    end
end

"""WebSocket ping/pong keepalive loop."""
function _ping_loop(ws::HTTP.WebSockets.WebSocket, interval::Float64)
    while !HTTP.WebSockets.isclosed(ws)
        try
            HTTP.WebSockets.ping(ws)
        catch
            break
        end
        sleep(interval)
    end
    return nothing
end
