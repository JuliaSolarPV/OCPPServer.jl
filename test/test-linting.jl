
@testitem "Aqua" tags = [:linting] begin
    using Aqua: Aqua
    using OCPPServer

    Aqua.test_all(OCPPServer)
end

@testitem "JET" tags = [:linting] begin
    if v"1.12" <= VERSION < v"1.13"
        using JET: JET
        using OCPPServer

        JET.test_package(OCPPServer; target_modules = (OCPPServer,))
    end
end
