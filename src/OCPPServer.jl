module OCPPServer

using OCPPData
using HTTP
using HTTP.WebSockets: WebSocket, WebSocketError
import HTTP.WebSockets
import Sockets
using JSON
using Dates
using UUIDs

# Types
export ServerConfig, CentralSystem, ChargePointSession

# Events
export OCPPEvent,
    ChargePointConnected,
    ChargePointDisconnected,
    MessageReceived,
    MessageSent,
    HandlerError

# Public API
export start!, stop!
export on!, after!, subscribe!
export send_call
export list_sessions, get_session, is_connected
export set_connection_validator!, set_message_logger!

include("config.jl")
include("events.jl")
include("session.jl")
include("central_system.jl")
include("routing.jl")
include("outbound.jl")
include("transport.jl")

end # module OCPPServer
