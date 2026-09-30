defmodule SalixSignal.Service.EndpointsTest do
  use ExUnit.Case, async: true

  alias SalixSignal.Service.{Credentials, Endpoints}

  # CRS-01 section 3.1: SHA-256 of the DER of roots A and B.
  test "the pinned roots are Signal roots A and B" do
    hashes =
      for der <- Endpoints.pinned_roots(),
          do: Base.encode16(:crypto.hash(:sha256, der), case: :lower)

    assert hashes == [
             "ddb0f92bb95c8d6fd202ea6e8cc5ccd182b544f8cd696f47d580659ddc9df65a",
             "2642f1f90b389fed2558d7324ca26d70e750b06f87c595c5de955e2560821657"
           ]
  end

  # CRS-01 section 4.1: the oracle observation for a registration request.
  test "registration credentials give the CRS-01 Authorization header" do
    credentials = Credentials.registration("+15555550123", "example-password")

    assert Credentials.authorization(credentials) ==
             "Basic KzE1NTU1NTUwMTIzOmV4YW1wbGUtcGFzc3dvcmQ="
  end

  test "device credentials name the ACI and device id and hide the password" do
    aci = "3f0f4b1c-5d2e-4a6b-8c7d-9e0f1a2b3c4d"
    credentials = Credentials.device(aci, 1, "secret")
    assert credentials.username == aci <> ".1"
    refute inspect(credentials) =~ "secret"
    assert_raise ArgumentError, fn -> Credentials.device(String.upcase(aci), 1, "secret") end
    assert byte_size(Credentials.new_password()) == 22
  end
end
