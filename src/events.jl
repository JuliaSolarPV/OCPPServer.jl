"""Base type for all events emitted by the server."""
abstract type OCPPEvent end

"""Emitted when a charge point establishes a WebSocket connection and passes validation."""
struct ChargePointConnected <: OCPPEvent
    charge_point_id::String
    timestamp::DateTime
    version::Symbol
end

"""
Emitted when a charge point disconnects.

Reason is one of: `:normal`, `:error`, `:timeout`, `:replaced`.
"""
struct ChargePointDisconnected <: OCPPEvent
    charge_point_id::String
    timestamp::DateTime
    reason::Symbol
end

"""Emitted when a message is received from a charge point (after decode, before dispatch)."""
struct MessageReceived <: OCPPEvent
    charge_point_id::String
    message::OCPPData.OCPPMessage
    timestamp::DateTime
end

"""Emitted when a message is sent to a charge point."""
struct MessageSent <: OCPPEvent
    charge_point_id::String
    message::OCPPData.OCPPMessage
    timestamp::DateTime
end

"""Emitted when a handler throws an exception."""
struct HandlerError <: OCPPEvent
    charge_point_id::String
    action::String
    error::Exception
    timestamp::DateTime
end
