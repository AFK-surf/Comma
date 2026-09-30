defmodule SalixSignalProto.KemBackendTest do
  # Owner decision (KEM use, fail closed): secret-key KEM operations run in
  # constant time in OTP :crypto; plain Elixir stands in only when a test
  # enables it. Not async: it changes the application environment that the
  # other tests rely on.
  use ExUnit.Case, async: false

  import SalixSignalProto.Test.SessionFixtures

  alias SalixSignalProto.{Address, Keys, KemBackend, Session}
  alias SalixSignalProto.Crypto.MlKem768
  alias SalixSignalProto.KemBackend.UnsupportedError

  @moduletag skip: KemBackend.constant_time?() && "this node has constant-time KEM support"

  @alice Address.new("00000000-0000-4000-8000-000000000021", 1)
  @bob Address.new("00000000-0000-4000-8000-000000000022", 1)

  setup do
    on_exit(fn -> Application.put_env(:salix_signal_proto, :plain_kem_in_tests, true) end)
  end

  defp disable_plain_kem,
    do: Application.put_env(:salix_signal_proto, :plain_kem_in_tests, false)

  test "without constant-time KEM, a responder refuses a pre-key message and a new session cannot send" do
    bob = responder()
    alice_ctx = context(:crypto.strong_rand_bytes(32), 1234, @alice, @bob)

    bob_ctx = %{
      identity: bob.identity,
      registration_id: 4321,
      local_address: @bob,
      remote_address: @alice,
      trusted?: &trust_all/2
    }

    {:ok, alice} = Session.process_bundle(nil, bob.bundle, alice_ctx)
    {:ok, {3, first}, _alice} = Session.encrypt(alice, "first", alice_ctx)
    {:ok, second_session} = Session.process_bundle(nil, responder().bundle, alice_ctx)

    disable_plain_kem()

    # PQXDH decapsulation (Kyber1024) and the first post-quantum key pair
    # (ML-KEM-768) both refuse; neither falls back to plain Elixir.
    assert_raise UnsupportedError, fn ->
      Session.decrypt_pre_key(nil, first, bob_ctx, bob.pre_keys)
    end

    assert_raise UnsupportedError, fn -> Session.encrypt(second_session, "x", alice_ctx) end
    assert_raise UnsupportedError, fn -> Keys.kem_keypair() end

    {_ek, dk} = MlKem768.keypair_from_seed(<<1::256>>, <<2::256>>)

    assert_raise UnsupportedError, fn ->
      MlKem768.decapsulate(dk, :binary.copy(<<0>>, 1088))
    end
  end
end
