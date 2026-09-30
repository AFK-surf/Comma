defmodule SalixSignal.Account.RegistrationRequestsTest do
  # Verification-session and registration requests on the chat socket
  # against vectors/CRS-02/registration-requests.json (CRS-02 §2, §3): the
  # method, path, headers and JSON of each request, and the client result
  # of each reply. JSON is compared as values: the service accepts byte
  # fields as base64 or as an array of byte values (CRS-02 §0), and
  # signatures are randomized, so they are checked by verification.
  #
  # The "check SVR2 credentials" case is not run: registration lock and
  # secure value recovery are deferred (CRS-02, Comma decision 2).
  use ExUnit.Case, async: true

  # Upper bounds on a loaded machine, not expectations: a TLS connect and
  # upgrade (the chat client's own connect timeout is 10 s), and any other
  # wait for a message or a task.
  @connect_ms 30_000
  @wait_ms 30_000

  alias SalixSignal.Account.{Registration, Verification}
  alias SalixSignal.Service.Chat
  alias SalixSignal.Test.FakeChat
  alias SalixSignalProto.{Keys, PreKeys}
  alias SalixSignalProto.Crypto.XEdDSA
  alias SalixSignalProto.PreKeys.Store
  alias SalixSignalProto.Service.Frame

  @vectors Path.expand("../../fixtures/crs/CRS-02/registration-requests.json", __DIR__)

  setup_all do
    cases = @vectors |> File.read!() |> JSON.decode!() |> Map.fetch!("cases")
    %{cases: cases, chain: FakeChat.chain()}
  end

  setup %{chain: chain} do
    {:ok, upgrades} = Agent.start_link(fn -> [] end)
    server = start_supervised!({Bandit, FakeChat.bandit_options(self(), chain, upgrades)})

    chat =
      start_supervised!(
        {Chat, owner: self(), host: "localhost", port: FakeChat.port(server), roots: [chain.root]}
      )

    assert_receive {:signal_chat, ^chat, {:connected, _}}, @connect_ms
    assert_receive {:fake_chat, :connected, socket}, @connect_ms
    %{transport: {:chat, chat}, socket: socket}
  end

  # Runs `fun` in a task, checks the request it sends against the vector and
  # answers with the vector's reply.
  defp exchange(%{socket: socket}, vector, fun, check_body) do
    task = Task.async(fun)
    expected = vector["outputs"]["request"]
    assert_receive {:fake_chat, :frame, ^socket, %Frame.Request{} = request}, @wait_ms

    assert request.verb == expected["verb"]
    assert request.path == expected["path"]

    assert Map.new(request.headers, fn {k, v} -> {String.downcase(k), v} end) ==
             expected["headers"]

    check_body.(JSON.decode!(request.body), JSON.decode!(expected["body_utf8"]))

    reply = JSON.encode!(vector["outputs"]["server_reply_used"])

    send(
      socket,
      {:send, Frame.encode_response(%Frame.Response{id: request.id, status: 200, body: reply})}
    )

    Task.await(task, @wait_ms)
  end

  defp same(actual, expected), do: assert(actual == expected)

  defp named(cases, operation), do: Enum.filter(cases, &(&1["inputs"]["operation"] == operation))
  defp named!(cases, operation), do: cases |> named(operation) |> hd()

  test "verification session requests and results", %{cases: cases, transport: t} = context do
    create = named!(cases, "create verification session")

    assert {:ok, session} =
             exchange(
               context,
               create,
               fn -> Verification.create(t, create["inputs"]["e164"]) end,
               &same/2
             )

    state = create["outputs"]["client_state"]
    assert session.id == state["session_id"]
    assert session.requested_information == [:captcha]
    assert session.allowed_to_request_code == state["allowed_to_request_code"]

    captcha = named!(cases, "submit captcha")

    assert {:ok, ready} =
             exchange(
               context,
               captcha,
               fn -> Verification.submit_captcha(t, session.id, captcha["inputs"]["captcha"]) end,
               &same/2
             )

    result = captcha["outputs"]["client_result"]
    assert {ready.allowed_to_request_code, ready.verified} == {true, false}

    assert {ready.next_call, ready.next_sms} ==
             {result["next_call_seconds"], result["next_sms_seconds"]}

    assert ready.requested_information == []

    codes = named(cases, "request verification code")
    assert Enum.map(codes, & &1["inputs"]["transport"]) |> Enum.sort() == ["sms", "voice"]

    for vector <- codes do
      inputs = vector["inputs"]

      assert {:ok, sent} =
               exchange(
                 context,
                 vector,
                 fn ->
                   Verification.request_code(
                     t,
                     session.id,
                     String.to_existing_atom(inputs["transport"]),
                     client: inputs["client"],
                     languages: inputs["languages"]
                   )
                 end,
                 &same/2
               )

      assert sent.next_verification_attempt == 0
    end

    submit = named!(cases, "submit verification code")

    assert {:ok, verified} =
             exchange(
               context,
               submit,
               fn -> Verification.submit_code(t, session.id, submit["inputs"]["code"]) end,
               &same/2
             )

    assert verified.verified == submit["outputs"]["client_result_verified"]
  end

  test "registration request and result", %{cases: cases, transport: t} = context do
    vector = named!(cases, "register account")
    inputs = vector["inputs"]
    hex = &Base.decode16!(&1, case: :lower)
    expected_body = JSON.decode!(vector["outputs"]["request"]["body_utf8"])

    # The account from the vector's keys, IDs and password.
    store = fn identity_private, signed_private, signed_id, kem_public, kem_id ->
      identity = Keys.ec_keypair(hex.(identity_private))
      signed = Keys.ec_keypair(hex.(signed_private))
      kem = hex.(kem_public)

      %Store{
        identity: identity,
        signed: [
          %PreKeys.SignedPreKey{
            id: signed_id,
            public: signed.public,
            private: signed.private,
            signature: XEdDSA.sign(identity.private, signed.public),
            created_ms: 0
          }
        ],
        last_resort: [
          %PreKeys.KemPreKey{
            id: kem_id,
            public: kem,
            secret: <<>>,
            signature: XEdDSA.sign(identity.private, kem),
            last_resort: true,
            created_ms: 0
          }
        ],
        next_signed_id: signed_id + 1,
        next_one_time_id: 1,
        next_kem_id: kem_id + 1
      }
    end

    account = %Registration.NewAccount{
      number: vector["outputs"]["server_reply_used"]["number"],
      password: inputs["account_password"],
      aci:
        store.(
          inputs["aci_identity_private_key"],
          inputs["aci_signed_pre_key_private"],
          1,
          inputs["aci_kem_public_key"],
          3
        ),
      pni:
        store.(
          inputs["pni_identity_private_key"],
          inputs["pni_signed_pre_key_private"],
          2,
          inputs["pni_kem_public_key"],
          4
        ),
      registration_id: expected_body["accountAttributes"]["registrationId"],
      pni_registration_id: expected_body["accountAttributes"]["pniRegistrationId"]
    }

    attributes = %{
      unidentified_access_key: hex.(inputs["unidentified_access_key"]),
      registration_lock: inputs["registration_lock"],
      recovery_password: hex.(inputs["recovery_password"])
    }

    check_body = fn actual, expected ->
      assert Map.keys(actual) |> Enum.sort() == Map.keys(expected) |> Enum.sort()
      assert actual["sessionId"] == expected["sessionId"]
      assert actual["skipDeviceTransfer"] == expected["skipDeviceTransfer"]

      for prefix <- ["aci", "pni"] do
        identity_key = Base.decode64!(actual[prefix <> "IdentityKey"])
        assert identity_key == Base.decode64!(expected[prefix <> "IdentityKey"])

        for field <- [prefix <> "SignedPreKey", prefix <> "PqLastResortPreKey"] do
          assert actual[field]["keyId"] == expected[field]["keyId"]

          assert Base.decode64!(actual[field]["publicKey"]) ==
                   Base.decode64!(expected[field]["publicKey"])

          assert Keys.verify_signature(
                   identity_key,
                   Base.decode64!(actual[field]["publicKey"]),
                   Base.decode64!(actual[field]["signature"])
                 )
        end
      end

      a = actual["accountAttributes"]
      e = expected["accountAttributes"]

      for key <- ~w(fetchesMessages registrationId pniRegistrationId registrationLock
                    unrestrictedUnidentifiedAccess discoverableByPhoneNumber) do
        assert a[key] == e[key], key
      end

      assert Base.decode64!(a["recoveryPassword"]) == Base.decode64!(e["recoveryPassword"])

      assert :binary.bin_to_list(Base.decode64!(a["unidentifiedAccessKey"])) ==
               e["unidentifiedAccessKey"]

      # Comma advertises only the capability that the service requires.
      assert a["capabilities"] == %{"spqr" => true}
      assert e["capabilities"]["spqr"] == true
    end

    assert {:ok, registered} =
             exchange(
               context,
               vector,
               fn ->
                 Registration.register(
                   t,
                   account,
                   {:session, expected_body["sessionId"]},
                   attributes
                 )
               end,
               check_body
             )

    result = vector["outputs"]["client_result"]
    assert registered.aci == result["aci"]
    assert "PNI:" <> registered.pni == result["pni"]
    assert registered.number == result["number"]
    assert registered.reregistration == result["reregistration"]
  end
end
