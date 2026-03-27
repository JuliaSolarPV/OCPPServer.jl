@testitem "Event types are subtypes of OCPPEvent" tags = [:unit, :fast] begin
    using OCPPServer
    using Dates

    @test ChargePointConnected <: OCPPEvent
    @test ChargePointDisconnected <: OCPPEvent
    @test MessageReceived <: OCPPEvent
    @test MessageSent <: OCPPEvent
    @test HandlerError <: OCPPEvent
end

@testitem "Event construction" tags = [:unit, :fast] begin
    using OCPPServer
    using Dates

    ts = now(UTC)

    e1 = ChargePointConnected("CP001", ts, :v16)
    @test e1.charge_point_id == "CP001"
    @test e1.timestamp == ts
    @test e1.version == :v16

    e2 = ChargePointDisconnected("CP001", ts, :normal)
    @test e2.reason == :normal

    e3 = ChargePointDisconnected("CP001", ts, :replaced)
    @test e3.reason == :replaced

    e4 = HandlerError("CP001", "BootNotification", ErrorException("test"), ts)
    @test e4.action == "BootNotification"
    @test e4.error isa ErrorException
end
