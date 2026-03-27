@testsnippet ClientServerSetup begin
    using Sockets: getsockname

    """Get the actual bound port from a running CentralSystem."""
    function get_server_port(cs)
        return Int(getsockname(cs._server.listener.server)[2])
    end

    """Start a CentralSystem and wait for it to be ready."""
    function start_test_server!(cs)
        server_task = @async OCPPServer.start!(cs)
        deadline = time() + 5.0
        while cs._server === nothing && time() < deadline
            sleep(0.1)
        end
        cs._server === nothing && error("Server failed to start within 5 seconds")
        return server_task
    end

    """Wait for a ChargePoint to reach the given status."""
    function wait_for_status(cp, status::Symbol; timeout = 5.0)
        deadline = time() + timeout
        while cp.status != status && time() < deadline
            sleep(0.1)
        end
        return cp.status == status
    end
end

@testitem "Client BootNotification + Heartbeat flow" tags = [:integration, :client_server] setup =
    [ClientServerSetup] begin
    using OCPPServer
    using OCPPClient
    using OCPPData
    using OCPPData.V16
    using Dates

    cs = CentralSystem(; port = 0, host = "127.0.0.1")

    OCPPServer.on!(cs, "BootNotification") do session, req
        session.metadata["vendor"] = req.charge_point_vendor
        session.metadata["model"] = req.charge_point_model
        return BootNotificationResponse(;
            current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
            interval = 300,
            status = RegistrationAccepted,
        )
    end

    OCPPServer.on!(cs, "Heartbeat") do session, req
        return HeartbeatResponse(;
            current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
        )
    end

    start_test_server!(cs)
    port = get_server_port(cs)

    cp = ChargePoint("CP001", "ws://127.0.0.1:$(port)/ocpp"; reconnect = false)
    conn_task = @async OCPPClient.connect!(cp)
    @test wait_for_status(cp, :connected)

    resp = boot_notification(
        cp;
        charge_point_vendor = "TestVendor",
        charge_point_model = "TestModel",
    )
    @test resp.status == RegistrationAccepted
    @test resp.interval == 300

    session = OCPPServer.get_session(cs, "CP001")
    @test session.metadata["vendor"] == "TestVendor"
    @test session.metadata["model"] == "TestModel"

    resp = heartbeat(cp)
    @test !isempty(resp.current_time)

    OCPPClient.disconnect!(cp)
    sleep(0.3)
    OCPPServer.stop!(cs)
end

@testitem "Server sends Reset to client" tags = [:integration, :client_server] setup =
    [ClientServerSetup] begin
    using OCPPServer
    using OCPPClient
    using OCPPData
    using OCPPData.V16
    using Dates

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

    cp = ChargePoint("CP002", "ws://127.0.0.1:$(port)/ocpp"; reconnect = false)
    reset_received = Ref(false)

    OCPPClient.on!(cp, "Reset") do cp_ref, req
        reset_received[] = true
        return ResetResponse(; status = GenericAccepted)
    end

    conn_task = @async OCPPClient.connect!(cp)
    @test wait_for_status(cp, :connected)

    boot_notification(
        cp;
        charge_point_vendor = "TestVendor",
        charge_point_model = "TestModel",
    )

    session = OCPPServer.get_session(cs, "CP002")
    resp = OCPPServer.send_call(
        session,
        "Reset",
        Dict{String,Any}("type" => "Hard");
        timeout = 5.0,
    )
    @test resp isa ResetResponse
    @test reset_received[]

    OCPPClient.disconnect!(cp)
    sleep(0.3)
    OCPPServer.stop!(cs)
end

@testitem "StatusNotification flow" tags = [:integration, :client_server] setup =
    [ClientServerSetup] begin
    using OCPPServer
    using OCPPClient
    using OCPPData
    using OCPPData.V16
    using Dates

    cs = CentralSystem(; port = 0, host = "127.0.0.1")
    received_statuses = Vector{Symbol}()

    OCPPServer.on!(cs, "BootNotification") do session, req
        return BootNotificationResponse(;
            current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
            interval = 300,
            status = RegistrationAccepted,
        )
    end

    OCPPServer.on!(cs, "StatusNotification") do session, req
        push!(received_statuses, Symbol(string(req.status)))
        return StatusNotificationResponse()
    end

    start_test_server!(cs)
    port = get_server_port(cs)

    cp = ChargePoint("CP003", "ws://127.0.0.1:$(port)/ocpp"; reconnect = false)
    conn_task = @async OCPPClient.connect!(cp)
    @test wait_for_status(cp, :connected)

    boot_notification(
        cp;
        charge_point_vendor = "TestVendor",
        charge_point_model = "TestModel",
    )

    status_notification(
        cp;
        connector_id = 1,
        status = ChargePointAvailable,
        error_code = NoError,
    )

    sleep(0.2)
    @test length(received_statuses) == 1

    OCPPClient.disconnect!(cp)
    sleep(0.3)
    OCPPServer.stop!(cs)
end

@testitem "Full charge session flow" tags = [:integration, :client_server] setup =
    [ClientServerSetup] begin
    using OCPPServer
    using OCPPClient
    using OCPPData
    using OCPPData.V16
    using Dates

    cs = CentralSystem(; port = 0, host = "127.0.0.1")
    next_tx_id = Ref(1000)

    OCPPServer.on!(cs, "BootNotification") do session, req
        return BootNotificationResponse(;
            current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
            interval = 300,
            status = RegistrationAccepted,
        )
    end

    OCPPServer.on!(cs, "Heartbeat") do session, req
        return HeartbeatResponse(;
            current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
        )
    end

    OCPPServer.on!(cs, "StatusNotification") do session, req
        return StatusNotificationResponse()
    end

    OCPPServer.on!(cs, "Authorize") do session, req
        return AuthorizeResponse(;
            id_tag_info = IdTagInfo(; status = AuthorizationAccepted),
        )
    end

    OCPPServer.on!(cs, "StartTransaction") do session, req
        tx_id = next_tx_id[]
        next_tx_id[] += 1
        return StartTransactionResponse(;
            transaction_id = tx_id,
            id_tag_info = IdTagInfo(; status = AuthorizationAccepted),
        )
    end

    OCPPServer.on!(cs, "StopTransaction") do session, req
        return StopTransactionResponse()
    end

    OCPPServer.on!(cs, "MeterValues") do session, req
        return MeterValuesResponse()
    end

    start_test_server!(cs)
    port = get_server_port(cs)

    cp = ChargePoint("CP004", "ws://127.0.0.1:$(port)/ocpp"; reconnect = false)
    conn_task = @async OCPPClient.connect!(cp)
    @test wait_for_status(cp, :connected)

    # 1. Boot
    resp = boot_notification(
        cp;
        charge_point_vendor = "TestVendor",
        charge_point_model = "TestModel",
    )
    @test resp.status == RegistrationAccepted

    # 2. Status: Available
    status_notification(
        cp;
        connector_id = 1,
        status = ChargePointAvailable,
        error_code = NoError,
    )

    # 3. Authorize
    auth_resp = authorize(cp; id_tag = "USER001")
    @test auth_resp.id_tag_info.status == AuthorizationAccepted

    # 4. Start Transaction
    start_resp =
        start_transaction(cp; connector_id = 1, id_tag = "USER001", meter_start = 0)
    @test start_resp.transaction_id == 1000
    @test start_resp.id_tag_info.status == AuthorizationAccepted

    # 5. Status: Charging
    status_notification(
        cp;
        connector_id = 1,
        status = ChargePointCharging,
        error_code = NoError,
    )

    # 6. Meter Values
    meter_values(
        cp;
        connector_id = 1,
        meter_value = [
            MeterValue(;
                timestamp = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
                sampled_value = [SampledValue(; value = "1234")],
            ),
        ],
    )

    # 7. Heartbeat during charging
    hb_resp = heartbeat(cp)
    @test !isempty(hb_resp.current_time)

    # 8. Stop Transaction
    stop_resp = stop_transaction(cp; transaction_id = 1000, meter_stop = 5000)
    @test stop_resp isa StopTransactionResponse

    # 9. Status: Available again
    status_notification(
        cp;
        connector_id = 1,
        status = ChargePointAvailable,
        error_code = NoError,
    )

    OCPPClient.disconnect!(cp)
    sleep(0.3)
    OCPPServer.stop!(cs)
end

@testitem "Event tracking on both sides" tags = [:integration, :client_server] setup =
    [ClientServerSetup] begin
    using OCPPServer
    using OCPPClient
    using OCPPData
    using OCPPData.V16
    using Dates

    cs = CentralSystem(; port = 0, host = "127.0.0.1")
    server_events = Vector{OCPPServer.OCPPEvent}()
    OCPPServer.subscribe!(cs) do event
        push!(server_events, event)
    end

    OCPPServer.on!(cs, "BootNotification") do session, req
        return BootNotificationResponse(;
            current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
            interval = 300,
            status = RegistrationAccepted,
        )
    end

    start_test_server!(cs)
    port = get_server_port(cs)

    client_events = Vector{OCPPClient.ClientEvent}()
    cp = ChargePoint("CPEVT", "ws://127.0.0.1:$(port)/ocpp"; reconnect = false)
    OCPPClient.subscribe!(cp) do event
        push!(client_events, event)
    end

    conn_task = @async OCPPClient.connect!(cp)
    @test wait_for_status(cp, :connected)

    boot_notification(
        cp;
        charge_point_vendor = "TestVendor",
        charge_point_model = "TestModel",
    )
    sleep(0.2)

    # Server events
    connect_evts = filter(e -> e isa OCPPServer.ChargePointConnected, server_events)
    @test length(connect_evts) >= 1
    @test connect_evts[1].charge_point_id == "CPEVT"

    msg_received = filter(e -> e isa OCPPServer.MessageReceived, server_events)
    @test length(msg_received) >= 1

    msg_sent = filter(e -> e isa OCPPServer.MessageSent, server_events)
    @test length(msg_sent) >= 1

    # Client events
    client_connect = filter(e -> e isa OCPPClient.Connected, client_events)
    @test length(client_connect) >= 1

    client_responses = filter(e -> e isa OCPPClient.ResponseReceived, client_events)
    @test length(client_responses) >= 1

    OCPPClient.disconnect!(cp)
    sleep(0.5)

    server_disconnects =
        filter(e -> e isa OCPPServer.ChargePointDisconnected, server_events)
    @test length(server_disconnects) >= 1

    client_disconnects = filter(e -> e isa OCPPClient.Disconnected, client_events)
    @test length(client_disconnects) >= 1

    OCPPServer.stop!(cs)
end

@testitem "Connection validator with client" tags = [:integration, :client_server] setup =
    [ClientServerSetup] begin
    using OCPPServer
    using OCPPClient
    using OCPPData

    cs = CentralSystem(; port = 0, host = "127.0.0.1")
    OCPPServer.set_connection_validator!(cs) do cp_id, request
        return cp_id == "ALLOWED_CP"
    end

    start_test_server!(cs)
    port = get_server_port(cs)

    # Rejected client
    cp_denied = ChargePoint("DENIED_CP", "ws://127.0.0.1:$(port)/ocpp"; reconnect = false)
    @async OCPPClient.connect!(cp_denied)
    sleep(1.0)
    @test cp_denied.status == :disconnected

    # Allowed client
    cp_allowed = ChargePoint("ALLOWED_CP", "ws://127.0.0.1:$(port)/ocpp"; reconnect = false)
    @async OCPPClient.connect!(cp_allowed)
    @test wait_for_status(cp_allowed, :connected)

    OCPPClient.disconnect!(cp_allowed)
    sleep(0.3)
    OCPPServer.stop!(cs)
end

@testitem "Multiple simultaneous clients" tags = [:integration, :client_server] setup =
    [ClientServerSetup] begin
    using OCPPServer
    using OCPPClient
    using OCPPData
    using OCPPData.V16
    using Dates

    cs = CentralSystem(; port = 0, host = "127.0.0.1")

    OCPPServer.on!(cs, "BootNotification") do session, req
        return BootNotificationResponse(;
            current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
            interval = 300,
            status = RegistrationAccepted,
        )
    end

    OCPPServer.on!(cs, "Heartbeat") do session, req
        return HeartbeatResponse(;
            current_time = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z"),
        )
    end

    start_test_server!(cs)
    port = get_server_port(cs)

    clients = ChargePoint[]
    for i = 1:3
        cp = ChargePoint("MULTI_CP$(i)", "ws://127.0.0.1:$(port)/ocpp"; reconnect = false)
        push!(clients, cp)
        @async OCPPClient.connect!(cp)
    end

    for cp in clients
        @test wait_for_status(cp, :connected)
    end

    @test length(OCPPServer.list_sessions(cs)) == 3

    for cp in clients
        resp = boot_notification(
            cp;
            charge_point_vendor = "TestVendor",
            charge_point_model = "TestModel",
        )
        @test resp.status == RegistrationAccepted
    end

    for cp in clients
        resp = heartbeat(cp)
        @test !isempty(resp.current_time)
    end

    for cp in clients
        OCPPClient.disconnect!(cp)
    end
    sleep(0.5)

    @test length(OCPPServer.list_sessions(cs)) == 0

    OCPPServer.stop!(cs)
end
