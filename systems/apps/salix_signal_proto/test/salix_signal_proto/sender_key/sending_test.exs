defmodule SalixSignalProto.SenderKey.SendingTest do
  # Send-side rules of CRS-09c section 6: distribution bookkeeping, rotation,
  # recipient selection and the group send token that the server checks
  # (CRS-09a section 15.6, run with the test server side).
  use ExUnit.Case, async: true

  alias SalixSignalProto.Group.{Endorsements, Params, ServerParams, Uid}
  alias SalixSignalProto.SenderKey.{Record, Sending}

  @a {:aci, <<0x00000000000040008000000000000041::128>>}
  @b {:aci, <<0x00000000000040008000000000000042::128>>}
  @c {:aci, <<0x00000000000040008000000000000043::128>>}

  test "targets get the distribution message once; rotation starts over and old receivers fail" do
    state = Sending.new()
    assert <<_::48, 4::4, _::12, 2::2, _::62>> = state.distribution_id

    targets = [{@a, 1}, {@a, 2}, {@b, 1}]
    assert Sending.needs_distribution(state, targets) == targets
    state = Sending.mark_delivered(state, [{@a, 1}, {@b, 1}])
    assert Sending.needs_distribution(state, targets) == [{@a, 2}]

    {:ok, receiver, id} =
      Record.process_distribution(Record.new(), Sending.distribution_message(state))

    assert id == state.distribution_id
    {:ok, message, state} = Sending.encrypt(state, "hello")
    assert {:ok, "hello", _} = Record.decrypt(receiver, message)

    # A 410 for a re-registered device: it needs the message again.
    assert Sending.needs_distribution(Sending.forget_delivered(state, [{@b, 1}]), targets) == [
             {@a, 2},
             {@b, 1}
           ]

    rotated = Sending.rotate(state)
    assert rotated.distribution_id == state.distribution_id
    assert Sending.needs_distribution(rotated, targets) == targets
    {:ok, after_rotation, _} = Sending.encrypt(rotated, "after")
    assert Record.decrypt(receiver, after_rotation) == {:error, :no_sender_key}
  end

  test "the sender-key path needs at least two eligible accounts" do
    eligible = MapSet.new([@a, @b])

    assert Sending.partition_recipients([@a, @b, @c], &MapSet.member?(eligible, &1)) ==
             {[@a, @b], [@c]}

    assert Sending.partition_recipients([@a, @c], &MapSet.member?(eligible, &1)) == {[], [@a, @c]}
  end

  test "the group send token covers exactly the recipient accounts" do
    secret = ServerParams.generate(:binary.copy(<<0x31>>, 32))
    {:ok, server} = ServerParams.decode_public(ServerParams.public_from_secret(secret))
    group = Params.from_master_key(:binary.copy(<<0x32>>, 32))
    now = 1_758_758_400 + 3_600
    expiration = 1_758_758_400 + 2 * 86_400
    members = [@a, @b, @c]
    ciphertexts = Enum.map(members, &Uid.encrypt(group, &1))

    response =
      Endorsements.issue(ciphertexts, Endorsements.key_pair(secret, expiration), <<5::256>>)

    {:ok, received} = Endorsements.receive(server, group, response, members, @a, now)
    endorsements = Map.new(Enum.zip(members, received.endorsements))

    {:ok, token} = Sending.group_send_token(group, endorsements, [@b, @c], expiration)
    assert Endorsements.verify_full_token(token, [@b, @c], secret, now)
    refute Endorsements.verify_full_token(token, [@b], secret, now)

    assert Sending.group_send_token(group, Map.delete(endorsements, @c), [@b, @c], expiration) ==
             :error
  end
end
