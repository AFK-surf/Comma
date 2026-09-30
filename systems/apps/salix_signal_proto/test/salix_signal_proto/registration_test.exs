defmodule SalixSignalProto.RegistrationTest do
  # Registration and account-attribute bodies (CRS-02 §3, §5) and the
  # service rules on them that a peer can see (CRS-02 §3.1 validation rules,
  # CRS-15 §3.3).
  use ExUnit.Case, async: true

  alias SalixSignalProto.{AccountKeys, Keys, Registration}
  alias SalixSignalProto.PreKeys.Store

  @access_key :binary.copy(<<0x11>>, 16)

  setup_all do
    now = 1_758_790_000_000
    %{aci: Store.new(Keys.ec_keypair(), now), pni: Store.new(Keys.ec_keypair(), now)}
  end

  defp attributes(extra \\ %{}) do
    Map.merge(
      %{registration_id: 4242, pni_registration_id: 5151, unidentified_access_key: @access_key},
      extra
    )
  end

  test "a registration body carries both identities with pre-keys signed by their identity key",
       %{aci: aci, pni: pni} do
    body = Registration.registration_body({:session, "Q3Vl"}, attributes(), aci, pni)

    assert body["sessionId"] == "Q3Vl"
    refute Map.has_key?(body, "recoveryPassword")
    assert body["skipDeviceTransfer"] == true

    for {identity, prefix} <- [{aci, "aci"}, {pni, "pni"}] do
      identity_key = Base.decode64!(body[prefix <> "IdentityKey"])
      assert identity_key == identity.identity.public

      for field <- [prefix <> "SignedPreKey", prefix <> "PqLastResortPreKey"] do
        key = body[field]

        assert Keys.verify_signature(
                 identity_key,
                 Base.decode64!(key["publicKey"]),
                 Base.decode64!(key["signature"])
               ),
               field
      end
    end

    # A fetch-only primary device: no push token field of any name.
    attrs = body["accountAttributes"]
    assert attrs["fetchesMessages"] == true
    refute Enum.any?(["apnToken", "gcmToken", "pushToken"], &Map.has_key?(body, &1))
    assert attrs["capabilities"] == %{"spqr" => true}
    assert Base.decode64!(attrs["unidentifiedAccessKey"]) == @access_key
    assert {attrs["registrationId"], attrs["pniRegistrationId"]} == {4242, 5151}
    refute Map.has_key?(attrs, "registrationLock")
  end

  test "re-registration with a recovery password and attributes that keep the lock", %{
    aci: aci,
    pni: pni
  } do
    {:ok, svr_key} = AccountKeys.svr_key(AccountKeys.generate_entropy_pool())
    password = AccountKeys.recovery_password(svr_key)
    lock = AccountKeys.registration_lock_token(svr_key)

    body =
      Registration.registration_body(
        {:recovery_password, password},
        attributes(%{
          registration_lock: lock,
          recovery_password: password,
          capabilities: ["storage"]
        }),
        aci,
        pni
      )

    refute Map.has_key?(body, "sessionId")
    assert Base.decode64!(body["recoveryPassword"]) == password
    attrs = body["accountAttributes"]
    assert attrs["registrationLock"] == lock
    assert Base.decode64!(attrs["recoveryPassword"]) == password
    # spqr stays set whatever else is requested.
    assert attrs["capabilities"] == %{"spqr" => true, "storage" => true}
  end

  test "attributes are rejected locally when the service would answer 422" do
    assert_raise ArgumentError, fn ->
      Registration.account_attributes(attributes(%{unidentified_access_key: <<1, 2>>}))
    end

    assert_raise ArgumentError, fn ->
      Registration.account_attributes(attributes(%{registration_lock: "short"}))
    end

    assert_raise ArgumentError, fn ->
      Registration.account_attributes(attributes(%{registration_id: 16_384}))
    end

    unrestricted =
      Registration.account_attributes(
        attributes(%{unidentified_access_key: nil, unrestricted_unidentified_access: true})
      )

    refute Map.has_key?(unrestricted, "unidentifiedAccessKey")

    assert Enum.all?(
             for(_ <- 1..200, do: Registration.random_registration_id()),
             &(&1 in 1..16_380)
           )
  end

  test "account objects parse; a malformed one is refused" do
    assert {:ok, account} =
             Registration.parse_account(%{
               "uuid" => "00000000-0000-4000-8000-00000000000A",
               "number" => "+15550100001",
               "pni" => "00000000-0000-4000-8000-00000000000b",
               "usernameHash" => Base.url_encode64(:binary.copy(<<0xFB>>, 32), padding: false),
               "usernameLinkHandle" => nil,
               "reregistration" => true
             })

    assert account.aci == "00000000-0000-4000-8000-00000000000a"
    assert account.username_hash == :binary.copy(<<0xFB>>, 32)
    assert account.reregistration

    assert Registration.parse_account(%{"uuid" => "not-a-uuid"}) == {:error, :malformed}

    assert Registration.parse_account(%{
             "uuid" => "00000000-0000-4000-8000-00000000000a",
             "usernameHash" => "AAAA"
           }) == {:error, :malformed}
  end
end
