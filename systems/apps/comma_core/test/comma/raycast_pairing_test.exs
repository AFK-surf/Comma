defmodule Comma.RaycastPairingTest do
  use Comma.DataCase, async: false
  alias Comma.Accounts.AuthSession
  alias Comma.{Accounts, RaycastPairing}

  @verifier "raycast-verifier-0123456789-abcdefghijklmnopqrstuvwxyz"

  setup do
    Comma.AuthChallengeStore.Memory.reset!()

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "raycast-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, desktop} =
      Accounts.create_session(user["id"], client_kind: "electron", client_platform: "macos")

    %{user: user, desktop: desktop}
  end

  test "the extension that started the pairing gets its own bearer, and desktop logout ends it",
       ctx do
    assert {:ok, grant} = RaycastPairing.create(ctx.user, ctx.desktop, challenge(@verifier))
    refute inspect(grant) =~ ctx.desktop["token"]

    assert {:ok, raycast} =
             RaycastPairing.exchange(
               Map.merge(grant, %{"verifier" => @verifier, "client_platform" => "macos"})
             )

    refute raycast["token"] == ctx.desktop["token"]
    assert {:ok, user, session} = Accounts.validate_session(raycast["token"])
    assert user["id"] == ctx.user["id"]
    assert session["parent_session_id"] == ctx.desktop["id"]
    assert session["client_kind"] == "raycast"
    assert session["client_platform"] == "macos"
    assert session["device_label"] == "Comma for Raycast"
    assert Repo.get!(AuthSession, session["id"]).auth_method == "raycast_pairing"

    # The paired session cannot pair another client, and the grant is spent.
    assert {:error, :forbidden} = RaycastPairing.create(user, session, challenge(@verifier))

    assert {:error, :invalid_raycast_pairing} =
             RaycastPairing.exchange(Map.put(grant, "verifier", @verifier))

    assert :ok = Accounts.revoke_session_token(ctx.desktop["token"])
    assert {:error, :revoked} = Accounts.validate_session(raycast["token"])
  end

  test "the admin session list shows the paired session and filters by its kind", ctx do
    {:ok, grant} = RaycastPairing.create(ctx.user, ctx.desktop, challenge(@verifier))
    {:ok, raycast} = RaycastPairing.exchange(Map.put(grant, "verifier", @verifier))

    assert {:ok, page} =
             Comma.Admin.list_user_sessions(ctx.user["id"], client_kind: "raycast", limit: 50)

    assert [listed] = page["data"]
    assert listed["id"] == raycast["session_id"]
    assert listed["auth_method"] == "raycast_pairing"
    assert listed["client_kind"] == "raycast"
    assert listed["device_label"] == "Comma for Raycast"
  end

  test "a grant without the verifier that started it issues no session and is spent", ctx do
    {:ok, grant} = RaycastPairing.create(ctx.user, ctx.desktop, challenge(@verifier))
    other = String.reverse(@verifier)

    assert {:error, :invalid_raycast_pairing} =
             RaycastPairing.exchange(Map.put(grant, "verifier", other))

    assert {:error, :invalid_raycast_pairing} = RaycastPairing.exchange(grant)

    # The right verifier arrives too late: the first attempt spent the grant.
    assert {:error, :invalid_raycast_pairing} =
             RaycastPairing.exchange(Map.put(grant, "verifier", @verifier))

    assert Repo.aggregate(
             from(session in AuthSession, where: session.auth_method == "raycast_pairing"),
             :count
           ) == 0
  end

  test "Raycast logout keeps the desktop session, and a malformed challenge gets no grant",
       ctx do
    {:ok, grant} = RaycastPairing.create(ctx.user, ctx.desktop, challenge(@verifier))
    {:ok, raycast} = RaycastPairing.exchange(Map.put(grant, "verifier", @verifier))
    assert Repo.get!(AuthSession, raycast["session_id"]).client_platform == "unknown"
    :ok = Accounts.revoke_session_token(raycast["token"])
    assert {:ok, _, _} = Accounts.validate_session(ctx.desktop["token"])

    assert {:error, :invalid_challenge} = RaycastPairing.create(ctx.user, ctx.desktop, "short")
    assert {:error, :invalid_challenge} = RaycastPairing.create(ctx.user, ctx.desktop, nil)
  end

  test "a guest session cannot pair Raycast, even with a grant issued around the check", ctx do
    {:ok, guest} = Accounts.create_session(ctx.user["id"], auth_method: "guest")
    assert {:error, :forbidden} = RaycastPairing.create(ctx.user, guest, challenge(@verifier))

    {:ok, grant} =
      Comma.Auth.OneTimeCredentials.issue(
        "raycast_pairing",
        %{
          "challenge" => challenge(@verifier),
          "user_id" => ctx.user["id"],
          "parent_session_id" => guest["id"]
        },
        120,
        guest["id"]
      )

    assert {:error, :invalid_raycast_pairing} =
             RaycastPairing.exchange(%{
               "pairing_id" => grant.id,
               "pairing_secret" => grant.secret,
               "verifier" => @verifier
             })

    assert Repo.aggregate(
             from(session in AuthSession, where: session.auth_method == "raycast_pairing"),
             :count
           ) == 0
  end

  defp challenge(verifier),
    do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
end
