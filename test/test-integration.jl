@testsnippet IntegrationSetup begin
    using Sockets: getsockname

    """Get the actual bound port from a running CentralSystem."""
    function get_server_port(cs)
        return Int(getsockname(cs._server.listener.server)[2])
    end

    """Start a CentralSystem and wait for it to be ready."""
    function start_test_server!(cs)
        server_task = @async start!(cs)
        # Wait until the server is actually listening
        deadline = time() + 5.0
        while cs._server === nothing && time() < deadline
            sleep(0.1)
        end
        cs._server === nothing && error("Server failed to start within 5 seconds")
        return server_task
    end

    """Helper to send a raw OCPP-J message on a WebSocket."""
    ws_send(ws, data) = HTTP.WebSockets.send(ws, data)

    """Helper to receive a raw OCPP-J message from a WebSocket."""
    ws_receive(ws) = HTTP.WebSockets.receive(ws)
end

@testitem "BootNotification round-trip" tags = [:integration] setup = [IntegrationSetup] begin
    using OCPPServer, OCPPData, OCPPData.V16, HTTP, JSON, Dates

    cs = CentralSystem(; port = 0, host = "127.0.0.1")

    on!(cs, "BootNotification") do session, req
        session.metadata["vendor"] = req.charge_point_vendor
        return BootNotificationResponse(;
            current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
            interval = 300,
            status = RegistrationAccepted,
        )
    end

    start_test_server!(cs)
    actual_port = get_server_port(cs)
    url = "ws://127.0.0.1:$(actual_port)/ocpp/CP001"

    HTTP.WebSockets.open(url; headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"]) do ws
        call = OCPPData.Call(
            OCPPData.generate_unique_id(),
            "BootNotification",
            Dict{String,Any}(
                "chargePointVendor" => "TestVendor",
                "chargePointModel" => "TestModel",
            ),
        )
        ws_send(ws, OCPPData.encode(call))
        response_raw = ws_receive(ws)
        msg = OCPPData.decode(String(response_raw))
        @test msg isa OCPPData.CallResult
        @test msg.payload["status"] == "Accepted"
        @test msg.payload["interval"] == 300
    end

    stop!(cs)
end

@testitem "Heartbeat round-trip" tags = [:integration] setup = [IntegrationSetup] begin
    using OCPPServer, OCPPData, OCPPData.V16, HTTP, JSON, Dates

    cs = CentralSystem(; port = 0, host = "127.0.0.1")

    on!(cs, "Heartbeat") do session, req
        return HeartbeatResponse(;
            current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
        )
    end

    start_test_server!(cs)
    actual_port = get_server_port(cs)
    url = "ws://127.0.0.1:$(actual_port)/ocpp/CP002"

    HTTP.WebSockets.open(url; headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"]) do ws
        call = OCPPData.Call(OCPPData.generate_unique_id(), "Heartbeat", Dict{String,Any}())
        ws_send(ws, OCPPData.encode(call))
        response_raw = ws_receive(ws)
        msg = OCPPData.decode(String(response_raw))
        @test msg isa OCPPData.CallResult
        @test haskey(msg.payload, "currentTime")
    end

    stop!(cs)
end

@testitem "Unknown action returns NotImplemented" tags = [:integration] setup =
    [IntegrationSetup] begin
    using OCPPServer, OCPPData, HTTP, JSON

    cs = CentralSystem(; port = 0, host = "127.0.0.1")
    start_test_server!(cs)
    actual_port = get_server_port(cs)
    url = "ws://127.0.0.1:$(actual_port)/ocpp/CP003"

    HTTP.WebSockets.open(url; headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"]) do ws
        call = OCPPData.Call(
            OCPPData.generate_unique_id(),
            "UnknownAction",
            Dict{String,Any}(),
        )
        ws_send(ws, OCPPData.encode(call))
        response_raw = ws_receive(ws)
        msg = OCPPData.decode(String(response_raw))
        @test msg isa OCPPData.CallError
        @test msg.error_code == "NotImplemented"
    end

    stop!(cs)
end

@testitem "Connection validator rejects unauthorized" tags = [:integration] setup =
    [IntegrationSetup] begin
    using OCPPServer, HTTP

    cs = CentralSystem(; port = 0, host = "127.0.0.1")
    set_connection_validator!(cs) do cp_id, request
        return cp_id == "ALLOWED"
    end

    start_test_server!(cs)
    actual_port = get_server_port(cs)

    # Rejected connection should throw
    @test_throws Exception HTTP.WebSockets.open(
        "ws://127.0.0.1:$(actual_port)/ocpp/DENIED";
        headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"],
        retry = false,
    ) do ws
        # Should not reach here
    end

    # Allowed connection should succeed
    reached = Ref(false)
    HTTP.WebSockets.open(
        "ws://127.0.0.1:$(actual_port)/ocpp/ALLOWED";
        headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"],
    ) do ws
        reached[] = true
    end
    @test reached[]

    stop!(cs)
end

@testitem "Event subscription" tags = [:integration] setup = [IntegrationSetup] begin
    using OCPPServer, OCPPData, HTTP, Dates

    cs = CentralSystem(; port = 0, host = "127.0.0.1")
    events = Vector{OCPPServer.OCPPEvent}()
    subscribe!(cs) do event
        push!(events, event)
    end

    on!(cs, "Heartbeat") do session, req
        return OCPPData.V16.HeartbeatResponse(;
            current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
        )
    end

    start_test_server!(cs)
    actual_port = get_server_port(cs)
    url = "ws://127.0.0.1:$(actual_port)/ocpp/CPEVT"

    HTTP.WebSockets.open(url; headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"]) do ws
        sleep(0.2)
        connected_events = filter(e -> e isa ChargePointConnected, events)
        @test length(connected_events) >= 1
        @test connected_events[1].charge_point_id == "CPEVT"
        @test connected_events[1].version == :v16
    end

    sleep(0.5)
    disconnected_events = filter(e -> e isa ChargePointDisconnected, events)
    @test length(disconnected_events) >= 1

    stop!(cs)
end

@testitem "Message logger captures raw messages" tags = [:integration] setup =
    [IntegrationSetup] begin
    using OCPPServer, OCPPData, OCPPData.V16, HTTP, JSON, Dates

    cs = CentralSystem(; port = 0, host = "127.0.0.1")
    logged_messages = Vector{Tuple{Symbol,String,String}}()
    set_message_logger!(cs) do direction, cp_id, raw
        push!(logged_messages, (direction, cp_id, raw))
    end

    on!(cs, "Heartbeat") do session, req
        return HeartbeatResponse(;
            current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
        )
    end

    start_test_server!(cs)
    actual_port = get_server_port(cs)
    url = "ws://127.0.0.1:$(actual_port)/ocpp/CPLOG"

    HTTP.WebSockets.open(url; headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"]) do ws
        call = OCPPData.Call(OCPPData.generate_unique_id(), "Heartbeat", Dict{String,Any}())
        ws_send(ws, OCPPData.encode(call))
        ws_receive(ws)
        sleep(0.2)
    end

    inbound = filter(m -> m[1] == :inbound, logged_messages)
    outbound = filter(m -> m[1] == :outbound, logged_messages)
    @test length(inbound) >= 1
    @test length(outbound) >= 1
    @test inbound[1][2] == "CPLOG"
    @test outbound[1][2] == "CPLOG"

    stop!(cs)
end

@testitem "send_call server to client" tags = [:integration] setup = [IntegrationSetup] begin
    using OCPPServer, OCPPData, OCPPData.V16, HTTP, JSON, Dates

    cs = CentralSystem(; port = 0, host = "127.0.0.1")

    on!(cs, "BootNotification") do session, req
        return BootNotificationResponse(;
            current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
            interval = 300,
            status = RegistrationAccepted,
        )
    end

    start_test_server!(cs)
    actual_port = get_server_port(cs)
    url = "ws://127.0.0.1:$(actual_port)/ocpp/CPSEND"

    HTTP.WebSockets.open(url; headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"]) do ws
        # Boot the charger first
        call = OCPPData.Call(
            OCPPData.generate_unique_id(),
            "BootNotification",
            Dict{String,Any}(
                "chargePointVendor" => "TestVendor",
                "chargePointModel" => "TestModel",
            ),
        )
        ws_send(ws, OCPPData.encode(call))
        ws_receive(ws)

        # Server sends Reset to client
        send_task = @async begin
            session = get_session(cs, "CPSEND")
            return send_call(
                session,
                "Reset",
                Dict{String,Any}("type" => "Hard");
                timeout = 5.0,
            )
        end

        sleep(0.3)
        raw_msg = ws_receive(ws)
        incoming = OCPPData.decode(String(raw_msg))
        @test incoming isa OCPPData.Call
        @test incoming.action == "Reset"

        # Client responds
        response = OCPPData.CallResult(
            incoming.unique_id,
            Dict{String,Any}("status" => "Accepted"),
        )
        ws_send(ws, OCPPData.encode(response))

        result = fetch(send_task)
        @test result isa V16.ResetResponse
    end

    stop!(cs)
end

@testitem "Session tracking" tags = [:integration] setup = [IntegrationSetup] begin
    using OCPPServer, HTTP

    cs = CentralSystem(; port = 0, host = "127.0.0.1")
    start_test_server!(cs)
    actual_port = get_server_port(cs)

    @test isempty(list_sessions(cs))
    @test !is_connected(cs, "CPTRACK")

    HTTP.WebSockets.open(
        "ws://127.0.0.1:$(actual_port)/ocpp/CPTRACK";
        headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"],
    ) do ws
        sleep(0.3)
        @test is_connected(cs, "CPTRACK")
        @test length(list_sessions(cs)) == 1

        session = get_session(cs, "CPTRACK")
        @test session.id == "CPTRACK"
        @test session.version == :v16
        @test session.status == :connected
    end

    sleep(0.5)
    @test !is_connected(cs, "CPTRACK")

    stop!(cs)
end

@testitem "after! handler runs after response" tags = [:integration] setup =
    [IntegrationSetup] begin
    using OCPPServer, OCPPData, OCPPData.V16, HTTP, JSON, Dates

    cs = CentralSystem(; port = 0, host = "127.0.0.1")
    after_called = Ref(false)

    on!(cs, "Heartbeat") do session, req
        return HeartbeatResponse(;
            current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
        )
    end

    after!(cs, "Heartbeat") do session, req, resp
        after_called[] = true
    end

    start_test_server!(cs)
    actual_port = get_server_port(cs)
    url = "ws://127.0.0.1:$(actual_port)/ocpp/CPAFTER"

    HTTP.WebSockets.open(url; headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"]) do ws
        call = OCPPData.Call(OCPPData.generate_unique_id(), "Heartbeat", Dict{String,Any}())
        ws_send(ws, OCPPData.encode(call))
        ws_receive(ws)
        sleep(0.5)
    end

    @test after_called[] == true

    stop!(cs)
end
