"""
    send_call(session::ChargePointSession, action::String, payload; timeout=nothing) -> response

Send an OCPP Call to a charge point and block until the response arrives.

Returns the typed response payload (deserialized from the CallResult).
Throws `ErrorException` on CallError or timeout.

The payload can be a Dict or a typed OCPPData.jl request struct.
"""
function send_call(
    session::ChargePointSession,
    action::String,
    payload;
    timeout::Union{Float64,Nothing} = nothing,
)
    if session.status != :connected
        error("Session $(session.id) is not connected")
    end

    unique_id = OCPPData.generate_unique_id()

    # Serialize payload
    payload_dict = if payload isa Dict
        payload
    else
        _serialize_response(payload)
    end

    call = OCPPData.Call(unique_id, action, payload_dict)

    # Create response channel and register it
    ch = Channel{OCPPData.OCPPMessage}(1)
    session.pending_calls[unique_id] = ch

    # Send the Call on the wire
    raw = OCPPData.encode(call)
    Sockets.send(session.ws, raw)

    effective_timeout = something(timeout, 30.0)

    # Wait for response
    response = try
        result = timedwait(() -> isready(ch), effective_timeout)
        if result === :timed_out
            delete!(session.pending_calls, unique_id)
            close(ch)
            error("Timeout waiting for response to $action ($(effective_timeout)s)")
        end
        take!(ch)
    catch e
        delete!(session.pending_calls, unique_id)
        rethrow(e)
    finally
        delete!(session.pending_calls, unique_id)
    end

    if response isa OCPPData.CallError
        error(
            "CallError from $(session.id): " *
            "$(response.error_code) - $(response.error_description)",
        )
    end

    ResponseType = _response_type(action, session.version)
    return _deserialize_payload(response.payload, ResponseType)
end

"""Match an incoming CallResult/CallError to a pending send_call."""
function _resolve_pending(session::ChargePointSession, msg::OCPPData.OCPPMessage)
    uid = msg.unique_id
    ch = get(session.pending_calls, uid, nothing)
    if ch !== nothing
        put!(ch, msg)
    else
        @warn "Received response with no pending call" charge_point = session.id unique_id =
            uid
    end
    return nothing
end

"""Serialize a typed struct to a Dict{String,Any} for embedding in a CallResult."""
function _serialize_response(response)
    return _to_string_dict(JSON.parse(JSON.json(response)))
end

"""Deserialize a Dict payload to a typed struct using JSON round-trip."""
function _deserialize_payload(payload, T::Type)
    return JSON.parse(JSON.json(payload), T)
end

"""Recursively convert a JSON.Object to Dict{String,Any}."""
function _to_string_dict(obj)
    result = Dict{String,Any}()
    for (k, v) in pairs(obj)
        result[String(k)] = _convert_value(v)
    end
    return result
end

function _convert_value(v)
    if v isa AbstractDict
        return _to_string_dict(v)
    elseif v isa AbstractVector
        return Any[_convert_value(item) for item in v]
    else
        return v
    end
end
