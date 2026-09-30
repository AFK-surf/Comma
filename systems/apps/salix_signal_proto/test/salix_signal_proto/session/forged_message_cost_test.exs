defmodule SalixSignalProto.Session.ForgedMessageCostTest do
  # Timing regression for the owner decision on forged messages (review of
  # C1/C2): the single account writer must not spend more on a forged
  # message than the chain walks that CRS-04 §5.3 and CRS-04b §7.4 require
  # for its jump. The forged message here is an honest message at the
  # forward-jump limits of both ratchets with one bit of its MAC changed, so
  # the receiver does all the work of an accepted message and then rejects
  # it.
  #
  # The bound is relative to the required work, measured on the same node
  # in the same test: one EC chain step (CRS-04 §4.2) and one post-quantum
  # chain step (CRS-04b §7.2) for each skipped index. Timing runs are
  # repeated and the fastest is kept, and the module is not async, so that
  # other tests do not share the schedulers during a measurement.
  use ExUnit.Case, async: false

  import Bitwise

  alias SalixSignalProto.Session
  alias SalixSignalProto.Session.{Kdf, Spqr}
  alias SalixSignalProto.Test.Party

  @limit 25_000
  @runs 3
  @max_ratio 2.0

  @tag timeout: 180_000
  test "one forged message at both forward-jump limits costs at most twice the required chain walks" do
    alice = Party.new()
    bob = Party.new()
    alice_ctx = Party.session_context(alice, bob)
    bob_ctx = Party.session_context(bob, alice)

    {:ok, alice_record} = Session.process_bundle(nil, Party.bundle(bob), alice_ctx)
    {:ok, {3, first}, alice_record} = Session.encrypt(alice_record, "first", alice_ctx)

    {:ok, "first", bob_record, _effects} =
      Session.decrypt_pre_key(nil, first, bob_ctx, Party.pre_keys(bob))

    {:ok, {2, reply}, bob_record} = Session.encrypt(bob_record, "reply", bob_ctx)
    {:ok, "reply", alice_record, _effects} = Session.decrypt(alice_record, reply, alice_ctx)

    # Bob has a one-session record. Alice now sends messages that are lost:
    # her next one has EC message number 24999 on a new chain (a DH ratchet
    # step and 24999 skipped indices for Bob) and post-quantum index 25001
    # (25000 above the last index Bob received on that chain).
    alice_record =
      Enum.reduce(1..(@limit - 1), alice_record, fn _step, record ->
        {:ok, _lost, record} = Session.encrypt(record, "lost", alice_ctx)
        record
      end)

    {:ok, {2, far}, _alice_record} = Session.encrypt(alice_record, "far", alice_ctx)
    forged = flip_last_bit(far)

    # The honest message is inside both limits; the forged one fails only
    # at the MAC, after the walks.
    assert {:ok, "far", _record, _effects} = Session.decrypt(bob_record, far, bob_ctx)
    assert Session.decrypt(bob_record, forged, bob_ctx) == {:error, :invalid}

    chain_key = :crypto.strong_rand_bytes(32)

    {forged_runs, required_runs} =
      Enum.unzip(
        for _run <- 1..@runs do
          required = microseconds(fn -> required_walks(chain_key) end)
          {microseconds(fn -> Session.decrypt(bob_record, forged, bob_ctx) end), required}
        end
      )

    {forged_us, required_us} = {Enum.min(forged_runs), Enum.min(required_runs)}

    assert forged_us <= @max_ratio * required_us,
           "a forged message took #{forged_us} us; the required chain walks take #{required_us} us"
  end

  # One EC chain step and one post-quantum chain step for each index up to
  # the forward-jump limit.
  defp required_walks(chain_key) do
    Enum.reduce(1..@limit, {chain_key, chain_key}, fn index, {ec, pq} ->
      {pq, _key} = Spqr.chain_next(pq, index)
      {Kdf.next(ec), pq}
    end)
  end

  defp microseconds(fun) do
    {microseconds, _result} = :timer.tc(fun)
    microseconds
  end

  defp flip_last_bit(bytes) do
    size = byte_size(bytes) - 1
    <<head::binary-size(^size), last>> = bytes
    <<head::binary, bxor(last, 1)>>
  end
end
