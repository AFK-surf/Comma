defmodule SalixSignal.Service.EndpointsTest do
  use SystemsClock.Case, async: true

  alias SalixSignal.Service.Credentials

  test "device credentials name the ACI and device id and hide the password" do
    aci = "3f0f4b1c-5d2e-4a6b-8c7d-9e0f1a2b3c4d"
    credentials = Credentials.device(aci, 1, "secret")
    assert credentials.username == aci <> ".1"
    refute inspect(credentials) =~ "secret"
    assert_raise ArgumentError, fn -> Credentials.device(String.upcase(aci), 1, "secret") end
    assert byte_size(Credentials.new_password()) == 22
  end
end
