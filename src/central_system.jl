"""The main server object. Manages connections, handlers, and events."""
mutable struct CentralSystem
    config::ServerConfig
    sessions::Dict{String,ChargePointSession}
    handlers::Dict{String,Function}
    after_handlers::Dict{String,Function}
    listeners::Vector{Function}
    connection_validator::Union{Function,Nothing}
    message_logger::Union{Function,Nothing}
    lock::ReentrantLock
    _server::Union{HTTP.Servers.Server,Nothing}
end

"""Create a CentralSystem. All keyword arguments are forwarded to ServerConfig."""
function CentralSystem(; kwargs...)
    config = ServerConfig(; kwargs...)
    return CentralSystem(config)
end

"""Create a CentralSystem from an existing ServerConfig."""
function CentralSystem(config::ServerConfig)
    return CentralSystem(
        config,
        Dict{String,ChargePointSession}(),
        Dict{String,Function}(),
        Dict{String,Function}(),
        Vector{Function}(),
        nothing,
        nothing,
        ReentrantLock(),
        nothing,
    )
end
