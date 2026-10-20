defmodule SalixSignal.ContactDiscoveryTest do
  # CRS-11: a lookup against a fake contact discovery service that plays
  # the enclave (SalixSignal.Test.FakeCdsi) with a synthetic attestation
  # from a test PKI (SalixSignalProto.Test.SgxAttestation).
  use SystemsClock.Case, async: false

  # The fake enclave runs in Bandit's connection processes: while one of them
  # works on a frame (the Noise handshake takes a while on a busy machine),
  # the clock must not move past the lookup's deadline.
  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.SalixSignal", "Elixir.ThousandIsland", "Elixir.Bandit"]

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
      SgxAttestation.build(
        noise_key: X25519.public_key(static),
        now: SystemsClock.system_time(:second)
      )

    enclave =
      Map.merge(%{attestation: attestation.message, static_private: static}, enclave)

    server =
      start_supervised!(
        {Bandit, FakeCdsi.bandit_options(SystemsRuntime.Proc.self(), context.chain, enclave)}
      )

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

    settle_refute_receive({:fake_cdsi, :handshake, _}, 200)
  end
end
