"""Configuration for the OCPP WebSocket server."""
@kwdef struct ServerConfig
    host::String = "0.0.0.0"
    port::Int = 9000
    path_prefix::String = "/ocpp"

    # TLS - set both to enable WSS, leave nothing for plain WS
    tls_cert::Union{String,Nothing} = nothing
    tls_key::Union{String,Nothing} = nothing

    # Version support
    supported_versions::Vector{Symbol} = [:v16]

    # Timeouts
    heartbeat_timeout::Float64 = 600.0
    default_call_timeout::Float64 = 30.0

    # Protocol behavior
    validate_messages::Bool = false
    ping_interval::Float64 = 30.0
end
