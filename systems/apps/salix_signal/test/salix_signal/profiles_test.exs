defmodule SalixSignal.ProfilesTest do
  # Setting and reading profiles (CRS-08 sections 5 to 8) against the fake
  # chat service and a fake CDN 0 written from CRS-08, and the CRS-08 vectors
  # profile-key-version-and-commitment.json and
  # expiring-profile-key-credential.json (test/fixtures/crs/CRS-08).
  use ExUnit.Case, async: true

  # Upper bounds on a loaded machine, not expectations: a TLS connect and
  # upgrade (the chat client's own connect timeout is 10 s), and any other
  # wait for a message or a task.
  @connect_ms 30_000
  @wait_ms 30_000

  alias SalixSignal.Profiles
  alias SalixSignal.Service.{Chat, Credentials}
  alias SalixSignal.Test.{FakeCdn, FakeChat}
  alias SalixSignalProto.Group.{ProfileKey, ProfileKeyCredential, ServerParams}
  alias SalixSignalProto.Profile
  alias SalixSignalProto.Service.Frame

  @fixtures Path.expand("../fixtures/crs", __DIR__)

  defp vectors(name), do: Path.join(@fixtures, name) |> File.read!() |> JSON.decode!()
  defp hex(value), do: Base.decode16!(value, case: :lower)

  @aci "00000000-0000-4000-8000-000000000061"
  @aci_bytes Base.decode16!("00000000000040008000000000000061")
  @peer "00000000-0000-4000-8000-000000000062"
  @peer_bytes Base.decode16!("00000000000040008000000000000062")

  setup_all do
    %{chain: FakeChat.chain()}
  end

  setup %{chain: chain} do
    {:ok, upgrades} = Agent.start_link(fn -> [] end)

    chat_server =
      start_supervised!({Bandit, FakeChat.bandit_options(self(), chain, upgrades)}, id: :chat)

    cdn = start_supervised!({FakeCdn, self()})
    cdn_server = start_supervised!({Bandit, FakeCdn.bandit_options(cdn, chain)}, id: :cdn)

    chat =
      start_supervised!(
        {Chat,
         owner: self(),
         host: "localhost",
         port: FakeChat.port(chat_server),
         roots: [chain.root],
         credentials: Credentials.device(@aci, 1, "pw")}
      )

    assert_receive {:signal_chat, ^chat, {:connected, _}}, @connect_ms
    assert_receive {:fake_chat, :connected, socket}, @connect_ms

    %{
      chat: chat,
      socket: socket,
      cdn: cdn,
      opts: [
        cdn0_url: "https://localhost:#{FakeChat.port(cdn_server)}",
        http: [roots: [chain.root]]
      ]
    }
  end

  defp next_request(socket) do
    assert_receive {:fake_chat, :frame, ^socket, %Frame.Request{} = request}, @wait_ms
    request
  end

  defp reply(socket, request, status, body \\ nil) do
    body = if is_map(body), do: Jason.encode!(body), else: body

    send(
      socket,
      {:send, Frame.encode_response(%Frame.Response{id: request.id, status: status, body: body})}
    )
  end

  defp fields(overrides) do
    Map.merge(
      %{
        profile_key: :binary.copy(<<7>>, 32),
        aci: @aci,
        given_name: "Comma",
        family_name: "Assistant",
        about: "Answers calls for the team.",
        about_emoji: "🤖"
      },
      Map.new(overrides)
    )
  end

  test "a new avatar is encrypted and posted with the returned S3 form", ctx do
    avatar = "\x89PNG\r\n\x1a\n" <> :crypto.strong_rand_bytes(2_000)
    fields = fields(avatar: {:new, avatar})
    task = Task.async(fn -> Profiles.set_profile(ctx.chat, fields, ctx.opts) end)

    request = next_request(ctx.socket)
    assert {request.verb, request.path} == {"PUT", "/v1/profile"}
    body = Jason.decode!(request.body)
    key = fields.profile_key

    assert body["version"] == Profile.version(key, @aci_bytes)
    assert Base.decode64!(body["commitment"]) == ProfileKey.commitment(key, @aci_bytes)

    assert Profile.decrypt_name(key, Base.decode64!(body["name"])) ==
             {:ok, {"Comma", "Assistant"}}

    assert byte_size(Base.decode64!(body["name"])) == 81
    assert Profile.decrypt_text(key, Base.decode64!(body["about"])) == {:ok, fields.about}
    assert Profile.decrypt_text(key, Base.decode64!(body["aboutEmoji"])) == {:ok, "🤖"}

    assert Profile.decrypt_phone_number_sharing(key, Base.decode64!(body["phoneNumberSharing"])) ==
             {:ok, false}

    assert body["paymentAddress"] == nil
    assert {body["avatar"], body["sameAvatar"]} == {true, false}
    refute Map.has_key?(body, "badgeIds")

    form = %{
      "key" => "profiles/AAAAAAAAAAAAAAAAAAAAAA==",
      "credential" => "AKIDEXAMPLE/20260925/us-east-1/s3/aws4_request",
      "acl" => "private",
      "algorithm" => "AWS4-HMAC-SHA256",
      "date" => "20260925T101500Z",
      "policy" => "cG9saWN5",
      "signature" => "abcdef0123"
    }

    reply(ctx.socket, request, 200, form)

    assert Task.await(task, @wait_ms) ==
             {:ok, %{version: body["version"], avatar: "profiles/AAAAAAAAAAAAAAAAAAAAAA=="}}

    assert_received {:fake_cdn, "POST", "/", _headers, multipart}
    names = Regex.scan(~r/name="([^"]+)"/, multipart, capture: :all_but_first) |> List.flatten()

    assert names ==
             ~w(key x-amz-credential acl x-amz-algorithm x-amz-date policy x-amz-signature Content-Type file)

    stored = FakeCdn.object(ctx.cdn, "profiles/AAAAAAAAAAAAAAAAAAAAAA==")
    assert byte_size(stored) == byte_size(avatar) + 28

    assert Profiles.download_avatar("profiles/AAAAAAAAAAAAAAAAAAAAAA==", key, ctx.opts) ==
             {:ok, avatar}
  end

  test "keeping or clearing the avatar needs no upload; refusals are reported", ctx do
    task =
      Task.async(fn ->
        Profiles.set_profile(ctx.chat, fields(avatar: :keep, about: nil), ctx.opts)
      end)

    request = next_request(ctx.socket)
    body = Jason.decode!(request.body)
    assert {body["avatar"], body["sameAvatar"], body["about"]} == {true, true, nil}
    reply(ctx.socket, request, 200)
    assert {:ok, %{avatar: nil}} = Task.await(task, @wait_ms)

    for {status, error} <- [
          {412, :profiles_v2_required},
          {403, :payments_not_allowed},
          {422, :invalid_profile}
        ] do
      task =
        Task.async(fn -> Profiles.set_profile(ctx.chat, fields(avatar: :clear), ctx.opts) end)

      request = next_request(ctx.socket)
      assert Jason.decode!(request.body)["avatar"] == false
      reply(ctx.socket, request, status)
      assert Task.await(task, @wait_ms) == {:error, error}
    end

    assert Profiles.set_profile(ctx.chat, fields(aci: "PNI:" <> @aci)) == {:error, :invalid_aci}

    assert Profiles.set_profile(ctx.chat, fields(about: :binary.copy("a", 600))) ==
             {:error, :too_long}
  end

  test "a versioned read sends the version and decrypts the peer's fields", ctx do
    peer_key = :binary.copy(<<9>>, 32)
    access_key = Profile.access_key(peer_key)
    {:ok, name} = Profile.encrypt_name(peer_key, "Ada", nil)
    {:ok, emoji} = Profile.encrypt_about_emoji(Profile.generate(), "x")

    task =
      Task.async(fn ->
        Profiles.get_profile(ctx.chat, @peer,
          profile_key: peer_key,
          access_key: access_key,
          accept_language: "en-US"
        )
      end)

    request = next_request(ctx.socket)
    assert request.path == "/v1/profile/#{@peer}/#{Profile.version(peer_key, @peer_bytes)}"
    assert {"unidentified-access-key", Base.encode64(access_key)} in request.headers
    assert {"accept-language", "en-US"} in request.headers

    reply(ctx.socket, request, 200, %{
      "identityKey" => Base.encode64(<<5>> <> :binary.copy(<<2>>, 32)),
      "unidentifiedAccess" => Base.encode64(Profile.access_key_checksum(access_key)),
      "unrestrictedUnidentifiedAccess" => false,
      "capabilities" => %{"spqr" => true, "profiles_v2" => false, "future" => "x"},
      "badges" => [],
      "uuid" => @peer,
      "name" => Base.encode64(name),
      "about" => nil,
      "aboutEmoji" => Base.encode64(emoji),
      "avatar" => "profiles/abc",
      "phoneNumberSharing" => Base.encode64(Profile.encrypt_phone_number_sharing(peer_key, true)),
      "unknownField" => 1
    })

    assert {:ok, profile} = Task.await(task, @wait_ms)
    assert profile.name == {"Ada", nil}
    assert profile.phone_number_sharing == true
    assert profile.about == nil
    # The emoji was encrypted under another key: left out and reported.
    assert profile.about_emoji == nil
    assert profile.key_mismatch
    assert profile.avatar == "profiles/abc"
    assert profile.capabilities == %{"spqr" => true, "profiles_v2" => false}
    assert byte_size(profile.identity_key) == 33
    assert Profile.unidentified_access(profile, peer_key) == {:keyed, access_key}
  end

  # CRS-08 sections 3.3 and 3.4: the version and the commitment come from the
  # profile key and the ACI; the commitment is the group credential code's.
  test "the profile body carries the oracle's version and commitment" do
    for %{"inputs" => inputs, "outputs" => outputs} <-
          vectors("CRS-08/profile-key-version-and-commitment.json")["cases"] do
      fields = fields(profile_key: hex(inputs["profile_key"]), aci: inputs["aci"])
      assert {:ok, body, version} = Profiles.profile_body(fields)
      assert version == outputs["version_string"] and body["version"] == version
      assert body["commitment"] == outputs["commitment_base64"]
    end
  end

  test "unversioned reads use the paths of CRS-08 section 6.1", ctx do
    task = Task.async(fn -> Profiles.get_profile(ctx.chat, "PNI:" <> @peer) end)
    request = next_request(ctx.socket)
    assert request.path == "/v1/profile/PNI:#{@peer}"
    reply(ctx.socket, request, 404)
    assert Task.await(task, @wait_ms) == {:error, :not_found}

    peer_key = :binary.copy(<<9>>, 32)

    assert Profiles.get_profile(ctx.chat, "PNI:" <> @peer, profile_key: peer_key) ==
             {:error, :versioned_profile_needs_aci}

    assert Profiles.get_profile(ctx.chat, "PNI:" <> @peer, access_key: <<0::128>>) ==
             {:error, :invalid_access}

    assert Profiles.get_profile(ctx.chat, "not-a-uuid") == {:error, :invalid_service_id}
  end

  # CRS-08 section 7: the request travels hex-encoded in the path; the
  # response is checked against the request context and the local clock.
  test "a credential read sends the oracle's request and receives the oracle's credential", ctx do
    [%{"inputs" => inputs, "outputs" => outputs} | _] =
      vectors("CRS-08/expiring-profile-key-credential.json")["cases"]

    read = fn now ->
      Task.async(fn ->
        Profiles.get_profile(ctx.chat, inputs["aci"],
          profile_key: hex(inputs["profile_key"]),
          credential: %{server_params: hex(inputs["server_public_params"]), now: now},
          credential_randomness: hex(inputs["client_randomness"])
        )
      end)
    end

    task = read.(inputs["receive_time_epoch_seconds"])
    request = next_request(ctx.socket)

    [_, path_segment] =
      Regex.run(~r{/([0-9a-f]+)\?credentialType=expiringProfileKey$}, request.path)

    assert path_segment == outputs["url_path_segment"]

    reply(ctx.socket, request, 200, %{"credential" => outputs["credential_response_base64"]})
    assert {:ok, profile} = Task.await(task, @wait_ms)
    assert profile.credential == hex(outputs["expiring_credential"])
    assert profile.credential_expiration == outputs["expiration_from_credential_epoch_seconds"]

    # The same response eight days later is outside the accepted window.
    task = read.(inputs["receive_time_epoch_seconds"] + 8 * 86_400)
    request = next_request(ctx.socket)
    reply(ctx.socket, request, 200, %{"credential" => outputs["credential_response_base64"]})
    assert Task.await(task, @wait_ms) == {:error, :credential_verification_failed}
  end

  # CRS-08 section 7, rejection cases: an expiration less than one day or at
  # least eight days after now fails on receive.
  test "credentials issued for an expiration outside 1 to 7 days are refused", ctx do
    [first | _] = cases = vectors("CRS-08/expiring-profile-key-credential.json")["cases"]
    server = ServerParams.generate(hex(first["inputs"]["server_secret_params_seed"]))
    server_params = ServerParams.public_from_secret(server)
    assert server_params == hex(first["inputs"]["server_public_params"])

    for %{"inputs" => inputs, "outputs" => %{"error" => _}} <- cases do
      uuid = uuid_bytes(inputs["aci"])
      key = hex(inputs["profile_key"])

      task =
        Task.async(fn ->
          Profiles.get_profile(ctx.chat, inputs["aci"],
            profile_key: key,
            credential: %{server_params: server_params, now: inputs["receive_time_epoch_seconds"]},
            credential_randomness: hex(inputs["client_randomness"])
          )
        end)

      request = next_request(ctx.socket)
      [_, hex_request] = Regex.run(~r{/([0-9a-f]+)\?credentialType=}, request.path)

      {:ok, response} =
        ProfileKeyCredential.issue(
          server,
          hex(hex_request),
          uuid,
          ProfileKey.commitment(key, uuid),
          inputs["expiration_epoch_seconds"],
          hex(inputs["server_randomness"])
        )

      reply(ctx.socket, request, 200, %{"credential" => Base.encode64(response)})
      assert Task.await(task, @wait_ms) == {:error, :credential_verification_failed}
    end
  end

  defp uuid_bytes(uuid), do: uuid |> String.replace("-", "") |> hex()

  test "avatar paths outside profiles/ are refused", ctx do
    assert Profiles.download_avatar("../attachments/x", Profile.generate(), ctx.opts) ==
             {:error, :invalid_avatar_path}

    assert Profiles.download_avatar("profiles/missing", Profile.generate(), ctx.opts) ==
             {:error, :not_found}
  end
end
