"""Represents a connected charge point's WebSocket session."""
mutable struct ChargePointSession
    id::String
    ws::HTTP.WebSockets.WebSocket
    status::Symbol
    version::Symbol
    pending_calls::Dict{String,Channel{OCPPData.OCPPMessage}}
    metadata::Dict{String,Any}
    connected_at::DateTime
    last_seen::DateTime
end

"""Create a ChargePointSession with default empty collections and current timestamps."""
function ChargePointSession(id::String, ws::HTTP.WebSockets.WebSocket, version::Symbol)
    return ChargePointSession(
        id,
        ws,
        :connected,
        version,
        Dict{String,Channel{OCPPData.OCPPMessage}}(),
        Dict{String,Any}(),
        now(UTC),
        now(UTC),
    )
end
