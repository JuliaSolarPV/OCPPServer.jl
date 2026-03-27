@testitem "ServerConfig defaults" tags = [:unit, :fast] begin
    using OCPPServer

    config = ServerConfig()
    @test config.host == "0.0.0.0"
    @test config.port == 9000
    @test config.path_prefix == "/ocpp"
    @test config.tls_cert === nothing
    @test config.tls_key === nothing
    @test config.supported_versions == [:v16]
    @test config.heartbeat_timeout == 600.0
    @test config.default_call_timeout == 30.0
    @test config.validate_messages == false
    @test config.ping_interval == 30.0
end

@testitem "ServerConfig custom values" tags = [:unit, :fast] begin
    using OCPPServer

    config = ServerConfig(;
        host = "127.0.0.1",
        port = 8080,
        path_prefix = "/ws",
        tls_cert = "/path/to/cert.pem",
        tls_key = "/path/to/key.pem",
        supported_versions = [:v16, :v201],
        heartbeat_timeout = 300.0,
        default_call_timeout = 15.0,
        validate_messages = true,
        ping_interval = 10.0,
    )
    @test config.host == "127.0.0.1"
    @test config.port == 8080
    @test config.path_prefix == "/ws"
    @test config.tls_cert == "/path/to/cert.pem"
    @test config.tls_key == "/path/to/key.pem"
    @test config.supported_versions == [:v16, :v201]
    @test config.heartbeat_timeout == 300.0
    @test config.default_call_timeout == 15.0
    @test config.validate_messages == true
    @test config.ping_interval == 10.0
end
