@testitem "on! registers handlers" tags = [:unit, :fast] begin
    using OCPPServer

    cs = CentralSystem(; port = 0)
    on!(cs, "BootNotification") do session, req
        return nothing
    end
    @test haskey(cs.handlers, "BootNotification")
end

@testitem "after! registers after-handlers" tags = [:unit, :fast] begin
    using OCPPServer

    cs = CentralSystem(; port = 0)
    after!(cs, "BootNotification") do session, req, resp
        return nothing
    end
    @test haskey(cs.after_handlers, "BootNotification")
end

@testitem "subscribe! adds listeners" tags = [:unit, :fast] begin
    using OCPPServer

    cs = CentralSystem(; port = 0)
    @test isempty(cs.listeners)
    subscribe!(cs) do event
        return nothing
    end
    @test length(cs.listeners) == 1
end

@testitem "set_connection_validator!" tags = [:unit, :fast] begin
    using OCPPServer

    cs = CentralSystem(; port = 0)
    @test cs.connection_validator === nothing
    set_connection_validator!(cs) do cp_id, request
        return true
    end
    @test cs.connection_validator !== nothing
end

@testitem "set_message_logger!" tags = [:unit, :fast] begin
    using OCPPServer

    cs = CentralSystem(; port = 0)
    @test cs.message_logger === nothing
    set_message_logger!(cs) do direction, cp_id, raw
        return nothing
    end
    @test cs.message_logger !== nothing
end

@testitem "Session queries on empty server" tags = [:unit, :fast] begin
    using OCPPServer

    cs = CentralSystem(; port = 0)
    @test isempty(list_sessions(cs))
    @test is_connected(cs, "CP001") == false
    @test_throws KeyError get_session(cs, "CP001")
end

@testitem "CentralSystem constructors" tags = [:unit, :fast] begin
    using OCPPServer

    # Keyword constructor
    cs1 = CentralSystem(; port = 8080, host = "localhost")
    @test cs1.config.port == 8080
    @test cs1.config.host == "localhost"

    # ServerConfig constructor
    config = ServerConfig(; port = 9090)
    cs2 = CentralSystem(config)
    @test cs2.config.port == 9090
    @test cs2._server === nothing
end
