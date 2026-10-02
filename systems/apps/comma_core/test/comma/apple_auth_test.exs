defmodule Comma.AppleAuthTest do
  use Comma.DataCase, async: false

  @moduletag database_isolation: "SERIALIZABLE"

  alias Comma.Accounts.{AuthSession, Identity}
  alias Comma.Auth.{AppleKeys, AppleToken}
  alias Comma.{Accounts, AppleAuth}

  setup do
    Comma.AuthChallengeStore.Memory.reset!()
    previous = Application.get_env(:comma_core, :apple_auth)
    key = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    public = Map.merge(public, %{"kid" => "apple-test", "alg" => "RS256", "use" => "sig"})

    Application.put_env(:comma_core, :apple_auth,
      client_id: "surf.comma.ios.test",
      request_options: [plug: {Req.Test, __MODULE__}]
    )

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"keys" => [public]}) end)
    pid = start_supervised!(AppleKeys)
    Req.Test.allow(__MODULE__, self(), pid)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:comma_core, :apple_auth, previous),
        else: Application.delete_env(:comma_core, :apple_auth)
    end)

    %{key: key}
  end

  test "verified Apple subject creates one account and survives missing or changed email", %{
    key: key
  } do
    email = email("first")
    {:ok, attempt} = AppleAuth.start_attempt()
    token = token(key, claims(attempt, %{"email" => email}))
    assert {:ok, first} = AppleAuth.complete(completion(attempt, token))
    assert {:ok, user, session} = Accounts.validate_session(first["token"])
    assert user["email"] == email
    assert session["client_kind"] == "ios"
    stored = Repo.get!(AuthSession, first["session_id"])
    assert stored.auth_method == "apple"
    assert Repo.get!(Identity, stored.login_identity_id).subject == "stable-subject"
    assert {:error, :invalid_apple_attempt} = AppleAuth.complete(completion(attempt, token))

    for extra <- [%{"email" => email("new")}, %{"email" => nil}] do
      {:ok, next} = AppleAuth.start_attempt()

      assert {:ok, returning} =
               AppleAuth.complete(completion(next, token(key, claims(next, extra))))

      assert returning["user"]["id"] == first["user"]["id"]
      assert returning["user"]["email"] == email
    end
  end

  test "existing email requires account OTP and rejects unverified first-login emails", %{
    key: key
  } do
    email = email("existing")
    {:ok, user} = Accounts.create_user(%{"email" => email})
    {:ok, attempt} = AppleAuth.start_attempt()

    assert {:ok, %{"status" => "otp_required", "challenge_id" => id, "code" => code}} =
             AppleAuth.complete(
               completion(attempt, token(key, claims(attempt, %{"email" => email})))
             )

    assert Repo.aggregate(from(identity in Identity, where: identity.provider == "apple"), :count) ==
             0

    wrong_code = if code == "999999", do: "000000", else: "999999"

    assert {:error, :invalid_verification_code} =
             AppleAuth.verify_link(%{"challenge_id" => id, "code" => wrong_code})

    assert {:ok, linked} = AppleAuth.verify_link(%{"challenge_id" => id, "code" => code})
    assert linked["user"]["id"] == user["id"]

    assert {:error, :invalid_verification_code} =
             AppleAuth.verify_link(%{"challenge_id" => id, "code" => code})

    {:ok, next} = AppleAuth.start_attempt()

    assert {:error, :apple_email_required} =
             AppleAuth.complete(
               completion(
                 next,
                 token(
                   key,
                   claims(next, %{
                     "sub" => "other-subject",
                     "email" => email,
                     "email_verified" => false
                   })
                 )
               )
             )
  end

  test "wrong issuer, audience, nonce, expiry, future issued-at, and signature cannot authenticate",
       %{key: key} do
    {:ok, attempt} = AppleAuth.start_attempt()

    expected = %{
      "nonce" => attempt["nonce"],
      "client_id" => attempt["client_id"],
      "issued_at" => System.system_time(:second)
    }

    now = System.system_time(:second)

    for override <- [
          %{"iss" => "https://attacker.test"},
          %{"aud" => "another.bundle"},
          %{"nonce" => "another-attempt"},
          %{"exp" => now - 1},
          # Beyond the 60s skew allowance even if verification crosses a second.
          %{"iat" => now + 120}
        ] do
      assert {:error, :invalid_apple_credential} =
               AppleToken.verify(token(key, claims(attempt, override)), expected)
    end

    attacker = JOSE.JWK.generate_key({:rsa, 2048})

    assert {:error, :invalid_apple_credential} =
             AppleToken.verify(token(attacker, claims(attempt)), expected)

    assert {:error, :invalid_apple_credential} = AppleToken.verify("malformed.jwt", expected)
  end

  test "disabled Apple identity rejects its existing bearer", %{key: key} do
    {:ok, attempt} = AppleAuth.start_attempt()
    {:ok, issued} = AppleAuth.complete(completion(attempt, token(key, claims(attempt))))
    identity_id = Repo.get!(AuthSession, issued["session_id"]).login_identity_id

    Repo.get!(Identity, identity_id)
    |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:error, :revoked} = Accounts.resolve_session_id(issued["session_id"])
    assert {:error, :revoked} = Accounts.validate_session(issued["token"])
  end

  test "unconfigured Apple login fails before allocating an attempt" do
    Application.delete_env(:comma_core, :apple_auth)
    assert {:error, :apple_not_configured} = AppleAuth.start_attempt()
  end

  defp claims(attempt, extra \\ %{}) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "iss" => "https://appleid.apple.com",
        "aud" => attempt["client_id"],
        "nonce" => attempt["nonce"],
        "sub" => "stable-subject",
        "iat" => now,
        "exp" => now + 300,
        "email" => email("apple"),
        "email_verified" => "true"
      },
      extra
    )
  end

  defp token(key, claims),
    do:
      JOSE.JWT.sign(key, %{"alg" => "RS256", "kid" => "apple-test"}, claims)
      |> JOSE.JWS.compact()
      |> elem(1)

  defp completion(attempt, token),
    do: %{
      "attempt_id" => attempt["attempt_id"],
      "identity_token" => token,
      "client_kind" => "ios",
      "client_platform" => "ios"
    }

  defp email(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}@example.test"
end
