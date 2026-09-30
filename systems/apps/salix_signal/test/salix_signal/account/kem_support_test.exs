defmodule SalixSignal.Account.KemSupportTest do
  # Owner decision (KEM use): a node without constant-time KEM support
  # refuses to create account keys. Not async: it changes the application
  # environment that the other account tests rely on.
  use ExUnit.Case, async: false

  alias SalixSignal.Account.{PreKeyService, Registration}
  alias SalixSignalProto.KemBackend

  @tag skip: KemBackend.constant_time?() && "this node has constant-time KEM support"
  test "account key creation fails closed without constant-time KEM support" do
    # Made while the test fallback is still allowed.
    store = SalixSignalProto.PreKeys.Store.new(SalixSignalProto.Keys.ec_keypair(), 0)

    Application.put_env(:salix_signal_proto, :plain_kem_in_tests, false)
    on_exit(fn -> Application.put_env(:salix_signal_proto, :plain_kem_in_tests, true) end)

    assert Registration.new_account("+15550100001", 0) == {:error, :kem_unsupported}

    # No request is sent: the transport points at a closed port.
    transport = {:http, "https://localhost:1", []}

    assert PreKeyService.maintain(transport, :aci, store, 0, fn _ -> :ok end) ==
             {:error, :kem_unsupported, store}
  end
end
