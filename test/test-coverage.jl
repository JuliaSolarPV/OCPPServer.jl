@testsnippet CoverageSetup begin
    using Sockets: getsockname

    function get_server_port(cs)
        return Int(getsockname(cs._server.listener.server)[2])
    end

    function start_test_server!(cs)
        server_task = @async OCPPServer.start!(cs)
        deadline = time() + 10.0
        while cs._server === nothing && time() < deadline
            sleep(0.1)
        end
        cs._server === nothing && error("Server failed to start within 10 seconds")
        return server_task
    end

    ws_send(ws, data) = HTTP.WebSockets.send(ws, data)
    ws_receive(ws) = HTTP.WebSockets.receive(ws)
end

@testitem "stop! with active sessions emits events" tags = [:coverage] setup =
    [CoverageSetup] begin
    using OCPPServer, HTTP, Dates

    cs = CentralSystem(; port = 0, host = "127.0.0.1")
    events = OCPPServer.OCPPEvent[]
    subscribe!(cs) do event
        push!(events, event)
    end

    start_test_server!(cs)
    port = get_server_port(cs)

    HTTP.WebSockets.open(
        "ws://127.0.0.1:$(port)/ocpp/CPSTOP";
        headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"],
    ) do ws
        sleep(0.3)
        @test is_connected(cs, "CPSTOP")
        # stop! while client is still connected
        stop!(cs)
    end

    sleep(0.3)
    disconnect_events = filter(e -> e isa ChargePointDisconnected, events)
    @test length(disconnect_events) >= 1
end

@testitem "Invalid path returns 404" tags = [:coverage] setup = [CoverageSetup] begin
    using OCPPServer, HTTP

    cs = CentralSystem(; port = 0, host = "127.0.0.1")
    start_test_server!(cs)
    port = get_server_port(cs)

    # Request to a path that doesn't match /ocpp/{id}
    resp = HTTP.get("http://127.0.0.1:$(port)/invalid/path"; status_exception = false)
    @test resp.status == 404

    stop!(cs)
end

@testitem "Unsupported version returns 400" tags = [:coverage] setup = [CoverageSetup] begin
    using OCPPServer, HTTP

    # Both versions supported but client sends unknown protocol
    cs = CentralSystem(; port = 0, host = "127.0.0.1", supported_versions = [:v16, :v201])
    start_test_server!(cs)
    port = get_server_port(cs)

    # Client sends unrecognized protocol — no fallback when multiple versions supported
    @test_throws Exception HTTP.WebSockets.open(
        "ws://127.0.0.1:$(port)/ocpp/CPVER";
        headers = ["Sec-WebSocket-Protocol" => "unknown"],
        retry = false,
    ) do ws
    end

    stop!(cs)
end

@testitem "Duplicate connection replaces old session" tags = [:coverage] setup =
    [CoverageSetup] begin
    using OCPPServer, OCPPData, HTTP, Dates

    cs = CentralSystem(; port = 0, host = "127.0.0.1")
    events = OCPPServer.OCPPEvent[]
    subscribe!(cs) do event
        push!(events, event)
    end

    start_test_server!(cs)
    port = get_server_port(cs)

    # First connection — keep it alive via a Channel signal
    keep_alive = Channel{Bool}(1)
    @async HTTP.WebSockets.open(
        "ws://127.0.0.1:$(port)/ocpp/CPDUP";
        headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"],
        suppress_close_error = true,
    ) do ws
        take!(keep_alive)  # block until signaled
    end
    # Wait for first connection to be established
    deadline = time() + 10.0
    while !is_connected(cs, "CPDUP") && time() < deadline
        sleep(0.1)
    end
    @test is_connected(cs, "CPDUP")

    # Second connection with same ID — should replace the first
    HTTP.WebSockets.open(
        "ws://127.0.0.1:$(port)/ocpp/CPDUP";
        headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"],
    ) do ws
        sleep(0.3)
    end

    # Signal first connection to close
    isopen(keep_alive) && put!(keep_alive, true)
    sleep(0.3)

    replaced_events = filter(events) do e
        e isa ChargePointDisconnected && e.reason == :replaced
    end
    @test length(replaced_events) >= 1

    stop!(cs)
end

@testitem "Handler error sends CallError and emits HandlerError" tags = [:coverage] setup =
    [CoverageSetup] begin
    using OCPPServer, OCPPData, HTTP, Dates

    cs = CentralSystem(; port = 0, host = "127.0.0.1")
    events = OCPPServer.OCPPEvent[]
    subscribe!(cs) do event
        push!(events, event)
    end

    on!(cs, "Heartbeat") do session, req
        error("intentional handler failure")
    end

    start_test_server!(cs)
    port = get_server_port(cs)

    HTTP.WebSockets.open(
        "ws://127.0.0.1:$(port)/ocpp/CPERR";
        headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"],
    ) do ws
        call = OCPPData.Call(OCPPData.generate_unique_id(), "Heartbeat", Dict{String,Any}())
        ws_send(ws, OCPPData.encode(call))
        raw = ws_receive(ws)
        msg = OCPPData.decode(String(raw))
        @test msg isa OCPPData.CallError
        @test msg.error_code == "InternalError"
    end

    sleep(0.2)
    handler_errors = filter(e -> e isa HandlerError, events)
    @test length(handler_errors) >= 1
    @test handler_errors[1].action == "Heartbeat"

    stop!(cs)
end

@testitem "Schema validation rejects bad payload" tags = [:coverage] setup = [CoverageSetup] begin
    using OCPPServer, OCPPData, HTTP

    cs = CentralSystem(; port = 0, host = "127.0.0.1", validate_messages = true)

    on!(cs, "BootNotification") do session, req
        error("should not reach handler")
    end

    start_test_server!(cs)
    port = get_server_port(cs)

    HTTP.WebSockets.open(
        "ws://127.0.0.1:$(port)/ocpp/CPVAL";
        headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"],
    ) do ws
        # Send BootNotification with missing required fields
        call = OCPPData.Call(
            OCPPData.generate_unique_id(),
            "BootNotification",
            Dict{String,Any}(),
        )
        ws_send(ws, OCPPData.encode(call))
        raw = ws_receive(ws)
        msg = OCPPData.decode(String(raw))
        @test msg isa OCPPData.CallError
        @test msg.error_code == "FormationViolation"
    end

    stop!(cs)
end

@testitem "send_call on disconnected session throws" tags = [:coverage] setup =
    [CoverageSetup] begin
    using OCPPServer, OCPPData, HTTP, Sockets

    cs = CentralSystem(; port = 0, host = "127.0.0.1")
    start_test_server!(cs)
    port = get_server_port(cs)

    # Connect then disconnect to get a session reference in disconnected state
    session_holder = Ref{Any}(nothing)
    HTTP.WebSockets.open(
        "ws://127.0.0.1:$(port)/ocpp/CPDIS";
        headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"],
    ) do ws
        sleep(0.3)
        session_holder[] = OCPPServer.get_session(cs, "CPDIS")
    end
    sleep(0.5)

    session_ref = session_holder[]::OCPPServer.ChargePointSession
    @test session_ref.status == :disconnected

    @test_throws ErrorException OCPPServer.send_call(
        session_ref,
        "Reset",
        Dict{String,Any}("type" => "Hard"),
    )

    stop!(cs)
end

@testitem "send_call with typed struct payload" tags = [:coverage] setup = [CoverageSetup] begin
    using OCPPServer, OCPPClient, OCPPData, OCPPData.V16, HTTP, Dates

    cs = CentralSystem(; port = 0, host = "127.0.0.1")

    OCPPServer.on!(cs, "BootNotification") do session, req
        return BootNotificationResponse(;
            current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
            interval = 300,
            status = RegistrationAccepted,
        )
    end

    start_test_server!(cs)
    port = get_server_port(cs)

    cp =
        OCPPClient.ChargePoint("CPSTRUCT", "ws://127.0.0.1:$(port)/ocpp"; reconnect = false)
    OCPPClient.on!(cp, "Reset") do cp_ref, req
        return ResetResponse(; status = GenericAccepted)
    end

    @async OCPPClient.connect!(cp)
    deadline = time() + 10.0
    while cp.status != :connected && time() < deadline
        sleep(0.1)
    end

    OCPPClient.boot_notification(
        cp;
        charge_point_vendor = "Test",
        charge_point_model = "Test",
    )

    # Send with a typed struct payload (not Dict)
    session = OCPPServer.get_session(cs, "CPSTRUCT")
    resp = OCPPServer.send_call(
        session,
        "Reset",
        ResetRequest(; type = ResetHard);
        timeout = 5.0,
    )
    @test resp isa ResetResponse

    OCPPClient.disconnect!(cp)
    sleep(0.3)
    OCPPServer.stop!(cs)
end

@testitem "Event listener error is caught" tags = [:coverage] setup = [CoverageSetup] begin
    using OCPPServer, HTTP

    cs = CentralSystem(; port = 0, host = "127.0.0.1")

    # Register a listener that throws
    subscribe!(cs) do event
        error("listener failure")
    end

    # Also register a good listener after the bad one
    events_received = Ref(0)
    subscribe!(cs) do event
        events_received[] += 1
    end

    start_test_server!(cs)
    port = get_server_port(cs)

    HTTP.WebSockets.open(
        "ws://127.0.0.1:$(port)/ocpp/CPLIST";
        headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"],
    ) do ws
        sleep(0.3)
    end

    sleep(0.3)
    # The good listener should still have been called despite the bad one throwing
    @test events_received[] > 0

    stop!(cs)
end

@testitem "_extract_cp_id edge cases" tags = [:coverage, :unit] begin
    using OCPPServer, HTTP

    # No match
    req = HTTP.Request("GET", "/wrong/path")
    @test OCPPServer._extract_cp_id(req, "/ocpp") === nothing

    # Empty id after prefix
    req2 = HTTP.Request("GET", "/ocpp/")
    @test OCPPServer._extract_cp_id(req2, "/ocpp") === nothing

    # Valid id
    req3 = HTTP.Request("GET", "/ocpp/CP001")
    @test OCPPServer._extract_cp_id(req3, "/ocpp") == "CP001"
end

@testitem "_detect_version edge cases" tags = [:coverage, :unit] begin
    using OCPPServer, HTTP

    # No matching protocol, multiple versions
    req = HTTP.Request("GET", "/")
    HTTP.setheader(req, "Sec-WebSocket-Protocol" => "unknown")
    @test OCPPServer._detect_version(req, [:v16, :v201]) === nothing

    # Fallback: single version supported, no header match
    @test OCPPServer._detect_version(req, [:v16]) == :v16

    # v201 match
    req2 = HTTP.Request("GET", "/")
    HTTP.setheader(req2, "Sec-WebSocket-Protocol" => "ocpp2.0.1")
    @test OCPPServer._detect_version(req2, [:v16, :v201]) == :v201

    # v16 match
    req3 = HTTP.Request("GET", "/")
    HTTP.setheader(req3, "Sec-WebSocket-Protocol" => "ocpp1.6")
    @test OCPPServer._detect_version(req3, [:v16, :v201]) == :v16
end

@testitem "_version_to_subprotocol" tags = [:coverage, :unit] begin
    using OCPPServer
    @test OCPPServer._version_to_subprotocol(:v16) == "ocpp1.6"
    @test OCPPServer._version_to_subprotocol(:v201) == "ocpp2.0.1"
end

@testitem "_request_type and _response_type v201 branch" tags = [:coverage, :unit] begin
    using OCPPServer, OCPPData

    # V201 branch
    RT = OCPPServer._request_type("BootNotification", :v201)
    @test RT == OCPPData.V201.BootNotificationRequest

    RespT = OCPPServer._response_type("BootNotification", :v201)
    @test RespT == OCPPData.V201.BootNotificationResponse

    # V16 branch (already covered but verify)
    RT16 = OCPPServer._request_type("Heartbeat", :v16)
    @test RT16 == OCPPData.V16.HeartbeatRequest
end

@testitem "send_call timeout" tags = [:coverage] setup = [CoverageSetup] begin
    using OCPPServer, OCPPClient, OCPPData, OCPPData.V16, HTTP, Dates

    cs = CentralSystem(; port = 0, host = "127.0.0.1")

    OCPPServer.on!(cs, "BootNotification") do session, req
        return BootNotificationResponse(;
            current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
            interval = 300,
            status = RegistrationAccepted,
        )
    end

    start_test_server!(cs)
    port = get_server_port(cs)

    # Client that does NOT handle Reset — so send_call will timeout
    cp = OCPPClient.ChargePoint("CPTMO", "ws://127.0.0.1:$(port)/ocpp"; reconnect = false)
    @async OCPPClient.connect!(cp)
    deadline = time() + 10.0
    while cp.status != :connected && time() < deadline
        sleep(0.1)
    end

    OCPPClient.boot_notification(
        cp;
        charge_point_vendor = "Test",
        charge_point_model = "Test",
    )

    session = OCPPServer.get_session(cs, "CPTMO")
    # Very short timeout — client won't respond in time since it has no handler
    # (OCPPClient sends CallError("NotImplemented") which triggers the CallError path)
    @test_throws ErrorException OCPPServer.send_call(
        session,
        "ChangeConfiguration",
        Dict{String,Any}("key" => "test", "value" => "1");
        timeout = 1.0,
    )

    OCPPClient.disconnect!(cp)
    sleep(0.3)
    OCPPServer.stop!(cs)
end

@testitem "Malformed JSON closes connection" tags = [:coverage] setup = [CoverageSetup] begin
    using OCPPServer, HTTP

    cs = CentralSystem(; port = 0, host = "127.0.0.1")
    start_test_server!(cs)
    port = get_server_port(cs)

    HTTP.WebSockets.open(
        "ws://127.0.0.1:$(port)/ocpp/CPBAD";
        headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"],
        suppress_close_error = true,
    ) do ws
        # Send invalid JSON — not a valid OCPP-J array
        ws_send(ws, "this is not json")
        sleep(0.5)
    end

    sleep(0.3)
    @test !is_connected(cs, "CPBAD")
    stop!(cs)
end

@testitem "after! handler error is caught" tags = [:coverage] setup = [CoverageSetup] begin
    using OCPPServer, OCPPData, OCPPData.V16, HTTP, JSON, Dates

    cs = CentralSystem(; port = 0, host = "127.0.0.1")

    on!(cs, "Heartbeat") do session, req
        return HeartbeatResponse(;
            current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
        )
    end

    after!(cs, "Heartbeat") do session, req, resp
        error("after handler failure")
    end

    start_test_server!(cs)
    port = get_server_port(cs)

    HTTP.WebSockets.open(
        "ws://127.0.0.1:$(port)/ocpp/CPAFT2";
        headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"],
    ) do ws
        call = OCPPData.Call(OCPPData.generate_unique_id(), "Heartbeat", Dict{String,Any}())
        ws_send(ws, OCPPData.encode(call))
        # Response should still arrive even though after! throws
        raw = ws_receive(ws)
        msg = OCPPData.decode(String(raw))
        @test msg isa OCPPData.CallResult
    end

    sleep(0.5)
    stop!(cs)
end

@testitem "_convert_value with nested arrays" tags = [:coverage, :unit] begin
    using OCPPServer, OCPPData, OCPPData.V16, JSON, Dates

    # Create a response with arrays to exercise _convert_value vector path
    mv = MeterValuesResponse()
    d = OCPPServer._serialize_response(mv)
    @test d isa Dict{String,Any}

    # Directly test _convert_value with a vector
    result = OCPPServer._convert_value([1, 2, 3])
    @test result == Any[1, 2, 3]

    # Nested dict in vector
    result2 = OCPPServer._convert_value([Dict("a" => 1)])
    @test result2[1] isa Dict{String,Any}
    @test result2[1]["a"] == 1
end

@testitem "Unmatched response warning" tags = [:coverage] setup = [CoverageSetup] begin
    using OCPPServer, OCPPData, HTTP

    cs = CentralSystem(; port = 0, host = "127.0.0.1")
    start_test_server!(cs)
    port = get_server_port(cs)

    HTTP.WebSockets.open(
        "ws://127.0.0.1:$(port)/ocpp/CPUNM";
        headers = ["Sec-WebSocket-Protocol" => "ocpp1.6"],
    ) do ws
        # Send a CallResult with a unique_id that nobody is waiting for
        fake_result = OCPPData.CallResult("nonexistent-id", Dict{String,Any}())
        ws_send(ws, OCPPData.encode(fake_result))
        sleep(0.3)
    end

    sleep(0.2)
    stop!(cs)
end
