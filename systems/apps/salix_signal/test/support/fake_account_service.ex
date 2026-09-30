defmodule SalixSignal.Test.FakeAccountService do
  @moduledoc false
  # A fake chat service for registration and account tests, written from
  # CRS-02 (verification sessions, registration, attributes, usernames) and
  # CRS-03 section 9 (pre-key upload, count, check and bundle fetch). It
  # serves HTTPS with the FakeChat test chain and keeps its state in an
  # Agent. It applies the service checks that a client can trip over: session
  # state, signature verification, the PNI group, the delivery channel, the
  # required capability, the registration lock and device credentials.

  alias SalixSignalProto.{Keys, Username}

  @captcha "signal-hcaptcha.SITE.registration.GOOD"
  @code "123456"

  def captcha, do: @captcha
  def code, do: @code

  def start_link(opts \\ []) do
    Agent.start_link(fn ->
      %{
        sessions: %{},
        accounts: %{},
        locks: Keyword.get(opts, :locks, %{}),
        taken_hashes: MapSet.new(),
        requests: []
      }
    end)
  end

  def bandit_options(agent, chain) do
    [
      plug: {__MODULE__.Router, agent},
      scheme: :https,
      ip: :loopback,
      port: 0,
      thousand_island_options: [transport_options: chain.server ++ [versions: [:"tlsv1.3"]]]
    ]
  end

  def state(agent), do: Agent.get(agent, & &1)
  def update(agent, fun), do: Agent.update(agent, fun)

  defmodule Router do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    alias SalixSignal.Test.FakeAccountService, as: Fake

    @impl true
    def init(agent), do: agent

    @impl true
    def call(conn, agent) do
      {:ok, raw, conn} = read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)
      conn = fetch_query_params(conn)
      Agent.update(agent, &%{&1 | requests: [{conn.method, conn.request_path} | &1.requests]})

      {status, reply} =
        Agent.get_and_update(agent, fn state ->
          case route(conn.method, conn.path_info, conn, body, state) do
            {status, reply, state} -> {{status, reply}, state}
            {status, reply} -> {{status, reply}, state}
          end
        end)

      conn
      |> put_resp_header("x-signal-timestamp", "1758790000000")
      |> put_resp_content_type("application/json")
      |> send_resp(status, if(reply == nil, do: "", else: Jason.encode!(reply)))
    end

    # --- Verification sessions (CRS-02 section 2) ---

    defp route("POST", ["v1", "verification", "session"], _conn, %{"number" => number}, state) do
      if Regex.match?(~r/\A\+[1-9][0-9]{6,14}\z/, number) do
        id = Base.url_encode64(:crypto.strong_rand_bytes(16))

        session = %{
          id: id,
          number: number,
          requested: ["captcha"],
          code_sent: false,
          verified: false
        }

        {200, session_json(session), put_in(state.sessions[id], session)}
      else
        {400, nil}
      end
    end

    defp route("PATCH", ["v1", "verification", "session", id], _conn, body, state) do
      with_session(state, id, fn session ->
        if body["captcha"] == Fake.captcha() do
          session = %{session | requested: []}
          {200, session_json(session), put_in(state.sessions[id], session)}
        else
          {403, session_json(session)}
        end
      end)
    end

    defp route("POST", ["v1", "verification", "session", id, "code"], _conn, body, state) do
      with_session(state, id, fn session ->
        cond do
          session.requested != [] or session.verified ->
            {409, session_json(session)}

          body["transport"] not in ["sms", "voice"] ->
            {422, nil}

          true ->
            session = %{session | code_sent: true}
            {200, session_json(session), put_in(state.sessions[id], session)}
        end
      end)
    end

    defp route("PUT", ["v1", "verification", "session", id, "code"], _conn, body, state) do
      with_session(state, id, fn session ->
        if session.code_sent and not session.verified do
          session = %{session | verified: body["code"] == Fake.code()}
          {200, session_json(session), put_in(state.sessions[id], session)}
        else
          {409, session_json(session)}
        end
      end)
    end

    # --- Registration (CRS-02 section 3) ---

    defp route("POST", ["v1", "registration"], conn, body, state) do
      with {:ok, number, password} <- basic(conn),
           :ok <- verified(state, body, number),
           :ok <- registration_valid(body),
           :ok <- lock_ok(state, number, body["accountAttributes"]) do
        existing = Map.get(state.accounts, number)
        aci = (existing && existing.aci) || uuid()
        pni = (existing && existing.pni) || uuid()

        account = %{
          aci: aci,
          pni: pni,
          number: number,
          password: password,
          attributes: body["accountAttributes"],
          username_hash: nil,
          reservation: nil,
          link: nil,
          identities: %{
            "aci" => identity(body, "aci"),
            "pni" => identity(body, "pni")
          }
        }

        reply = %{
          "uuid" => aci,
          "number" => number,
          "pni" => pni,
          "usernameHash" => nil,
          "usernameLinkHandle" => nil,
          "storageCapable" => false,
          "reregistration" => existing != nil
        }

        {200, reply, put_in(state.accounts[number], account)}
      else
        {status, reply} -> {status, reply}
      end
    end

    # --- Authenticated account paths ---

    defp route("GET", ["v2", "keys"], conn, _body, state) do
      with_account(conn, state, fn account ->
        identity = account.identities[conn.query_params["identity"] || "aci"]
        {200, %{"count" => length(identity.pre_keys), "pqCount" => length(identity.kem_pre_keys)}}
      end)
    end

    defp route("PUT", ["v2", "keys"], conn, body, state) do
      with_account(conn, state, fn account ->
        kind = conn.query_params["identity"] || "aci"
        identity = account.identities[kind]
        signed = [body["signedPreKey"], body["pqLastResortPreKey"] | body["pqPreKeys"] || []]

        if Enum.all?(Enum.reject(signed, &is_nil/1), &signed_by?(&1, identity.key)) do
          identity =
            identity
            |> replace(:signed, body["signedPreKey"])
            |> replace(:last_resort, body["pqLastResortPreKey"])
            |> replace(:pre_keys, body["preKeys"])
            |> replace(:kem_pre_keys, body["pqPreKeys"])

          {200, nil, put_in(state.accounts[account.number].identities[kind], identity)}
        else
          {422, nil}
        end
      end)
    end

    defp route("POST", ["v2", "keys", "check"], conn, body, state) do
      with_account(conn, state, fn account ->
        identity = account.identities[String.downcase(body["identityType"])]

        digest =
          :crypto.hash(:sha256, [
            identity.key,
            <<identity.signed["keyId"]::64>>,
            b64(identity.signed["publicKey"]),
            <<identity.last_resort["keyId"]::64>>,
            b64(identity.last_resort["publicKey"])
          ])

        if Base.decode64!(body["digest"], padding: false) == digest,
          do: {200, nil},
          else: {409, nil}
      end)
    end

    defp route("PUT", ["v1", "accounts", "attributes"], conn, body, state) do
      with_account(conn, state, fn account ->
        {204, nil, put_in(state.accounts[account.number].attributes, body)}
      end)
    end

    defp route("GET", ["v1", "accounts", "whoami"], conn, _body, state) do
      with_account(conn, state, fn account ->
        {200,
         %{
           "uuid" => account.aci,
           "pni" => account.pni,
           "number" => account.number,
           "usernameHash" =>
             account.username_hash && Base.url_encode64(account.username_hash, padding: false)
         }}
      end)
    end

    # --- Usernames (CRS-02 section 10.5) ---

    defp route("PUT", ["v1", "accounts", "username_hash", "reserve"], conn, body, state) do
      with_account(conn, state, fn account ->
        hashes = Enum.map(body["usernameHashes"], &Base.url_decode64!(&1, padding: false))

        case Enum.find(hashes, &(not MapSet.member?(state.taken_hashes, &1))) do
          nil ->
            {409, nil}

          hash ->
            {200, %{"usernameHash" => Base.url_encode64(hash, padding: false)},
             put_in(state.accounts[account.number].reservation, hash)}
        end
      end)
    end

    defp route("PUT", ["v1", "accounts", "username_hash", "confirm"], conn, body, state) do
      with_account(conn, state, fn account ->
        hash = Base.url_decode64!(body["usernameHash"], padding: false)
        proof = Base.url_decode64!(body["zkProof"], padding: false)

        cond do
          account.reservation != hash ->
            {409, nil}

          not Username.verify_proof(proof, hash) ->
            {422, nil}

          true ->
            link =
              body["encryptedUsername"] &&
                Base.url_decode64!(body["encryptedUsername"], padding: false)

            handle = if link, do: uuid()

            account = %{
              account
              | username_hash: hash,
                reservation: nil,
                link: link && {handle, link}
            }

            state =
              state
              |> put_in([:accounts, account.number], account)
              |> Map.update!(:taken_hashes, &MapSet.put(&1, hash))

            {200, %{"usernameHash" => body["usernameHash"], "usernameLinkHandle" => handle},
             state}
        end
      end)
    end

    defp route("GET", ["v1", "accounts", "username_hash", encoded], conn, _body, state) do
      if get_req_header(conn, "authorization") != [] do
        {400, nil}
      else
        hash = Base.url_decode64!(encoded, padding: false)

        case Enum.find(Map.values(state.accounts), &(&1.username_hash == hash)) do
          nil -> {404, nil}
          account -> {200, %{"uuid" => account.aci}}
        end
      end
    end

    defp route("GET", ["v1", "accounts", "username_link", handle], _conn, _body, state) do
      case Enum.find(Map.values(state.accounts), &match?({^handle, _}, &1.link)) do
        nil ->
          {404, nil}

        %{link: {_, value}} ->
          {200, %{"usernameLinkEncryptedValue" => Base.url_encode64(value, padding: false)}}
      end
    end

    # --- Bundle fetch (CRS-03 section 9.5), used by peers ---

    defp route("GET", ["v2", "keys", service_id, "1"], _conn, _body, state) do
      {kind, id} =
        case service_id do
          "PNI:" <> id -> {"pni", id}
          id -> {"aci", id}
        end

      case Enum.find(Map.values(state.accounts), &(Map.get(&1, String.to_atom(kind)) == id)) do
        nil ->
          {404, nil}

        account ->
          identity = account.identities[kind]
          {pre_key, pre_keys} = List.pop_at(identity.pre_keys, 0)
          {kem, kem_pre_keys} = List.pop_at(identity.kem_pre_keys, 0)
          reg_field = if kind == "aci", do: "registrationId", else: "pniRegistrationId"
          reg_id = account.attributes[reg_field]

          device =
            %{
              "deviceId" => 1,
              "registrationId" => reg_id,
              "signedPreKey" => identity.signed,
              "pqPreKey" => kem || identity.last_resort
            }
            |> then(&if(pre_key, do: Map.put(&1, "preKey", pre_key), else: &1))

          identity = %{identity | pre_keys: pre_keys, kem_pre_keys: kem_pre_keys}

          {200, %{"identityKey" => Base.encode64(identity.key), "devices" => [device]},
           put_in(state.accounts[account.number].identities[kind], identity)}
      end
    end

    defp route(_method, _path, _conn, _body, _state), do: {404, nil}

    # --- Helpers ---

    defp with_session(state, id, fun) do
      case Map.fetch(state.sessions, id) do
        {:ok, session} -> fun.(session)
        :error -> {404, nil}
      end
    end

    defp session_json(session) do
      %{
        "id" => session.id,
        "nextSms" => if(session.requested == [], do: 0),
        "nextCall" => if(session.requested == [], do: 60),
        "nextVerificationAttempt" => if(session.code_sent, do: 0),
        "allowedToRequestCode" => session.requested == [] and not session.verified,
        "requestedInformation" => session.requested,
        "verified" => session.verified
      }
    end

    defp basic(conn) do
      with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
           {:ok, decoded} <- Base.decode64(encoded),
           [username, password] <- :binary.split(decoded, ":") do
        {:ok, username, password}
      else
        _ -> {401, nil}
      end
    end

    defp with_account(conn, state, fun) do
      with {:ok, username, password} <- basic(conn),
           [aci, "1"] <- String.split(username, "."),
           %{} = account <- Enum.find(Map.values(state.accounts), &(&1.aci == aci)),
           true <- account.password == password do
        fun.(account)
      else
        _ -> {401, nil}
      end
    end

    defp verified(state, %{"sessionId" => id}, number) do
      case Map.fetch(state.sessions, id) do
        {:ok, %{verified: true, number: ^number}} -> :ok
        _ -> {401, nil}
      end
    end

    defp verified(_state, _body, _number), do: {400, nil}

    defp registration_valid(body) do
      attributes = body["accountAttributes"] || %{}

      pni_group = [
        body["pniIdentityKey"],
        attributes["pniRegistrationId"],
        body["pniSignedPreKey"],
        body["pniPqLastResortPreKey"]
      ]

      signed_ok =
        Enum.all?(["aci", "pni"], fn kind ->
          key = Base.decode64!(body[kind <> "IdentityKey"])

          signed_by?(body[kind <> "SignedPreKey"], key) and
            signed_by?(body[kind <> "PqLastResortPreKey"], key)
        end)

      channel_ok =
        attributes["fetchesMessages"] == true and not Map.has_key?(body, "apnToken") and
          not Map.has_key?(body, "gcmToken")

      cond do
        not (Enum.all?(pni_group, &(&1 != nil)) or Enum.all?(pni_group, &is_nil/1)) -> {422, nil}
        not channel_ok -> {422, nil}
        not signed_ok -> {422, nil}
        attributes["capabilities"]["spqr"] != true -> {499, nil}
        true -> :ok
      end
    end

    defp lock_ok(state, number, attributes) do
      case Map.fetch(state.locks, number) do
        :error ->
          :ok

        {:ok, lock} ->
          if attributes["registrationLock"] == lock,
            do: :ok,
            else:
              {423,
               %{
                 "timeRemaining" => 604_387_000,
                 "svr2Credentials" => %{"username" => "u", "password" => "p"}
               }}
      end
    end

    defp identity(body, kind) do
      %{
        key: Base.decode64!(body[kind <> "IdentityKey"]),
        signed: body[kind <> "SignedPreKey"],
        last_resort: body[kind <> "PqLastResortPreKey"],
        pre_keys: [],
        kem_pre_keys: []
      }
    end

    defp signed_by?(%{"publicKey" => public, "signature" => signature}, identity_key) do
      Keys.verify_signature(identity_key, b64(public), b64(signature))
    end

    defp signed_by?(_key, _identity_key), do: false

    # The service accepts base64 with or without padding (CRS-03 section 9.1).
    defp b64(value) do
      case Base.decode64(value) do
        {:ok, bytes} -> bytes
        :error -> Base.decode64!(value, padding: false)
      end
    end

    defp replace(identity, _field, nil), do: identity
    defp replace(identity, _field, []), do: identity
    defp replace(identity, field, value), do: Map.put(identity, field, value)

    defp uuid do
      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
        e::binary-size(12)>> =
        Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      Enum.join([a, b, c, d, e], "-")
    end
  end
end
