defmodule SalixSignal.ContactDiscoveryTest do
  # CRS-11: a lookup against a fake contact discovery service that plays
  # the enclave (SalixSignal.Test.FakeCdsi) with a synthetic attestation
  # from a test PKI (SalixSignalProto.Test.SgxAttestation).
  use ExUnit.Case, async: false

  alias SalixSignal.ContactDiscovery
  alias SalixSignal.Test.{FakeCdsi, FakeChat}
  alias SalixSignalProto.ContactDiscovery.Lookup
  alias SalixSignalProto.Crypto.X25519
  alias SalixSignalProto.Test.SgxAttestation

  @pni <<0::96, 0x0101::32>>
  @aci <<0::96, 0x0202::32>>

  setup do
    %{chain: FakeChat.chain()}
  end

  defp start_enclave(context, enclave \\ %{}) do
    static = X25519.generate_private_key()

    attestation =
      SgxAttestation.build(noise_key: X25519.public_key(static), now: System.os_time(:second))

    enclave =
      Map.merge(%{attestation: attestation.message, static_private: static}, enclave)

    server = start_supervised!({Bandit, FakeCdsi.bandit_options(self(), context.chain, enclave)})
    port = FakeChat.port(server)
    transport = {:http, "https://localhost:#{port}", roots: [context.chain.root]}

    opts = [
      host: "localhost",
      port: port,
      roots: [context.chain.root],
      pins: attestation.pins,
      timeout: 10_000
    ]

    {transport, opts, attestation}
  end

  test "looks up numbers through the attested channel", context do
    {transport, opts, attestation} =
      start_enclave(context, %{
        results: %{"+15550100001" => {@pni, <<0::128>>}, "+15550100003" => {@pni, @aci}}
      })

    numbers = ["+15550100001", "+15550100002", "+15550100003"]

    assert {:ok, %{results: results, token: token}} =
             ContactDiscovery.lookup(transport, numbers, opts)

    assert results == %{
             "+15550100001" => %{pni: {:pni, @pni}, aci: nil},
             "+15550100002" => nil,
             "+15550100003" => %{pni: {:pni, @pni}, aci: {:aci, @aci}}
           }

    assert token == :binary.copy(<<0x5A>>, 20)

    # The credential from /v2/directory/auth authenticates the upgrade to
    # the pinned enclave's path.
    {username, password} = FakeCdsi.credentials()
    basic = "Basic " <> Base.encode64(username <> ":" <> password)
    mrenclave = Base.encode16(attestation.pins.mrenclave, case: :lower)
    assert_received {:fake_cdsi, :upgrade, path, [^basic]}
    assert path == mrenclave <> "/discovery"

    assert_received {:fake_cdsi, :handshake, 1632}
    assert_received {:fake_cdsi, :request, request}
    {:ok, expected} = Lookup.encode_request(new_numbers: numbers)
    assert request == expected
    assert_received {:fake_cdsi, :ack, <<0x38, 0x01>>}
  end

  test "an attestation that fails verification ends the lookup before the client sends",
       context do
    {transport, opts, _attestation} = start_enclave(context)
    pins = %{opts[:pins] | mrenclave: :binary.copy(<<0x01>>, 32)}

    assert ContactDiscovery.lookup(transport, ["+15550100001"], Keyword.put(opts, :pins, pins)) ==
             {:error, {:attestation_failed, :mrenclave_mismatch}}

    refute_receive {:fake_cdsi, :handshake, _}, 200
  end

  test "enclave closes map to rate limiting and token invalidation", context do
    for {close, expected} <- [
          {{4008, ~s({"retry_after":30})}, {:rate_limited, 30}},
          {{4101, ""}, :invalid_token},
          {{4013, ""}, {:unavailable, 4013}}
        ] do
      {transport, opts, _} = start_enclave(context, %{close_after_request: close})
      assert ContactDiscovery.lookup(transport, ["+15550100001"], opts) == {:error, expected}
    end
  end

  test "a rate-limited upgrade returns its Retry-After", context do
    {transport, opts, _} =
      start_enclave(context, %{upgrade: {:reject, 429, [{"retry-after", "7"}]}})

    assert ContactDiscovery.lookup(transport, ["+15550100001"], opts) ==
             {:error, {:rate_limited, 7}}
  end

  test "refuses to run without constant-time ML-KEM outside tests", context do
    {transport, opts, _} = start_enclave(context)
    Application.put_env(:salix_signal_proto, :plain_kem_in_tests, false)
    on_exit(fn -> Application.put_env(:salix_signal_proto, :plain_kem_in_tests, true) end)

    unless SalixSignalProto.KemBackend.openssl?(:mlkem1024) do
      assert ContactDiscovery.lookup(transport, ["+15550100001"], opts) ==
               {:error, :kem_unsupported}

      refute_received {:fake_cdsi, :auth, _}
    end
  end
end
