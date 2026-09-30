defmodule SalixSignalProto.PreKeysTest do
  # Pre-key generation, JSON forms and lifecycle (CRS-03 §4, §9, §10), and
  # the responder side through a real pre-key session (CRS-03 §10.2).
  use ExUnit.Case, async: true

  alias SalixSignalProto.{Address, Keys, PreKeyBundle, PreKeys, Session}
  alias SalixSignalProto.PreKeys.Store

  @day 86_400_000
  @t0 1_758_790_000_000

  setup_all do
    # One store with published one-time batches, shared by the tests that
    # only read it: KEM key generation is the slow part.
    identity = Keys.ec_keypair()
    {store, body} = identity |> Store.new(@t0) |> Store.refresh(%{count: 0, kem_count: 0}, @t0)
    %{identity: identity, store: Store.uploaded(store), body: body}
  end

  test "published keys are signed by the identity key over their serialized form", %{
    store: store,
    body: body
  } do
    public = store.identity.public

    for key <- [body["signedPreKey"], body["pqLastResortPreKey"] | body["pqPreKeys"]],
        key != nil do
      assert Keys.verify_signature(
               public,
               Base.decode64!(key["publicKey"]),
               Base.decode64!(key["signature"])
             )
    end

    assert length(body["preKeys"]) == 100
    assert length(body["pqPreKeys"]) == 100
    assert Enum.all?(body["preKeys"], &(byte_size(Base.decode64!(&1["publicKey"])) == 33))
    assert Enum.all?(body["pqPreKeys"], &(byte_size(Base.decode64!(&1["publicKey"])) == 1569))
    refute Map.has_key?(body, "signedPreKey")
    refute Map.has_key?(body, "pqLastResortPreKey")

    # One-time and last-resort KEM pre-keys share one ID space.
    kem_ids = Enum.map(body["pqPreKeys"], & &1["keyId"])
    refute Store.current_last_resort(store).id in kem_ids
    assert Enum.all?(kem_ids, &(&1 in 1..0xFFFFFF))
  end

  test "a pending upload is returned again until it is confirmed", %{identity: identity} do
    {store, body} =
      identity |> Store.new(@t0) |> Store.refresh(%{count: 50, kem_count: 50}, @t0 + 3 * @day)

    assert Map.keys(body) |> Enum.sort() == ["pqLastResortPreKey", "signedPreKey"]
    assert Store.refresh(store, %{count: 50, kem_count: 50}, @t0 + 3 * @day) |> elem(1) == body

    store = Store.uploaded(store)
    assert Store.refresh(store, %{count: 50, kem_count: 50}, @t0 + 4 * @day) == {store, nil}
    assert {_store, %{"signedPreKey" => _}} = Store.refresh(store, nil, @t0 + 5 * @day)
  end

  # CRS-03 §9.5 and §10.1: an unconfirmed upload can have reached the
  # service, which hands each one-time key out once. The retry must not
  # publish those keys again, and Comma must keep their private keys.
  test "a retried upload publishes no one-time key of the earlier attempt", %{
    identity: identity
  } do
    {store, first} = identity |> Store.new(@t0) |> Store.refresh(%{count: 0, kem_count: 0}, @t0)
    {store, retry} = Store.refresh(store, %{count: 0, kem_count: 0}, @t0 + 1)
    ids = fn body, field -> MapSet.new(body[field], & &1["keyId"]) end

    assert MapSet.disjoint?(ids.(first, "preKeys"), ids.(retry, "preKeys"))
    assert MapSet.disjoint?(ids.(first, "pqPreKeys"), ids.(retry, "pqPreKeys"))
    assert store.pending == retry

    lookup = Store.pre_key_lookup(store)
    assert {:ok, _} = lookup.({:one_time_pre_key, hd(first["preKeys"])["keyId"]})
    assert {:ok, _} = lookup.({:kem_pre_key, hd(first["pqPreKeys"])["keyId"]})
  end

  test "rotation keeps replaced keys for 30 days and always the newest replaced key", %{
    identity: identity
  } do
    store = Store.new(identity, @t0)
    first = Store.current_signed(store)

    store =
      Enum.reduce(1..20, store, fn day, store ->
        {store, _body} = Store.refresh(store, nil, @t0 + day * 2 * @day)
        Store.uploaded(store)
      end)

    # 21 signed keys were made two days apart; the current one and the ones
    # replaced less than 30 days ago stay.
    now = @t0 + 40 * @day
    store = Store.prune(store, now)
    assert length(store.signed) == 16
    lookup = Store.pre_key_lookup(store)
    assert lookup.({:signed_pre_key, first.id}) == :error
    assert {:ok, _} = lookup.({:signed_pre_key, Store.current_signed(store).id})

    much_later = Store.prune(store, now + 100 * @day)
    assert length(much_later.signed) == 2
    assert length(much_later.last_resort) == 2
  end

  test "the consistency check digest covers the identity, signed and last-resort keys", %{
    store: store
  } do
    signed = Store.current_signed(store)
    last_resort = Store.current_last_resort(store)

    expected =
      :crypto.hash(
        :sha256,
        store.identity.public <>
          <<signed.id::64>> <> signed.public <> <<last_resort.id::64>> <> last_resort.public
      )

    assert Store.check_body(store, :aci) == %{
             "identityType" => "ACI",
             "digest" => Base.encode64(expected, padding: false)
           }

    {rotated, body} = Store.rotate_all(store, @t0 + 1)

    assert Enum.sort(Map.keys(body)) == [
             "pqLastResortPreKey",
             "pqPreKeys",
             "preKeys",
             "signedPreKey"
           ]

    refute Store.check_body(rotated, :pni)["digest"] == Store.check_body(store, :pni)["digest"]
  end

  test "a session started from a published bundle decrypts, and consumes one-time keys", %{
    store: store,
    body: body
  } do
    local = Address.new("00000000-0000-4000-8000-000000000001", 1)
    remote = Address.new("00000000-0000-4000-8000-000000000002", 1)
    initiator = Keys.ec_keypair()

    bundle_json = fn pre_key, kem ->
      %{
        "identityKey" => Base.encode64(store.identity.public),
        "devices" => [
          %{
            "deviceId" => 1,
            "registrationId" => 77,
            "signedPreKey" => PreKeys.to_json(Store.current_signed(store)),
            "preKey" => pre_key,
            "pqPreKey" => kem
          }
        ]
      }
    end

    ctx = fn identity, reg, me, peer ->
      %{
        identity: identity,
        registration_id: reg,
        local_address: me,
        remote_address: peer,
        trusted?: fn _, _ -> true end
      }
    end

    responder_ctx = ctx.(store.identity, 77, local, remote)
    initiator_ctx = ctx.(initiator, 55, remote, local)

    start = fn json ->
      {:ok, [bundle]} = PreKeyBundle.from_service_response(json)
      {:ok, record} = Session.process_bundle(nil, bundle, initiator_ctx)
      {:ok, {3, message}, _record} = Session.encrypt(record, "hello", initiator_ctx)
      message
    end

    # One-time EC and KEM pre-keys: both are deleted after use.
    [pre_key | _] = body["preKeys"]
    [kem | _] = body["pqPreKeys"]
    message = start.(bundle_json.(pre_key, kem))

    assert {:ok, "hello", _record, effects} =
             Session.decrypt_pre_key(nil, message, responder_ctx, Store.pre_key_lookup(store))

    used = Store.apply_effects(store, effects)
    lookup = Store.pre_key_lookup(used)
    assert lookup.({:one_time_pre_key, pre_key["keyId"]}) == :error
    assert lookup.({:kem_pre_key, kem["keyId"]}) == :error

    assert {:error, :missing_pre_key} =
             Session.decrypt_pre_key(nil, message, responder_ctx, lookup)

    # Last-resort KEM pre-key: kept, but the same combination is refused again.
    last_resort = PreKeys.to_json(Store.current_last_resort(store))
    message = start.(bundle_json.(nil, last_resort))

    assert {:ok, "hello", _record, effects} =
             Session.decrypt_pre_key(nil, message, responder_ctx, Store.pre_key_lookup(store))

    used = Store.apply_effects(store, effects)
    assert {:ok, _} = Store.pre_key_lookup(used).({:kem_pre_key, last_resort["keyId"]})

    assert {:error, _} =
             Session.decrypt_pre_key(nil, message, responder_ctx, Store.pre_key_lookup(used))
  end
end
