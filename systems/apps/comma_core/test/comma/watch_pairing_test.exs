defmodule Comma.WatchPairingTest do
  use Comma.DataCase, async: false
  alias Comma.Accounts.AuthSession
  alias Comma.{Accounts, WatchPairing}

  setup do
    Comma.AuthChallengeStore.Memory.reset!()

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "watch-#{System.unique_integer([:positive])}@example.test"
      })

    {:ok, phone} = Accounts.create_session(user["id"], client_kind: "ios", client_platform: "ios")
    %{user: user, phone: phone}
  end

  test "one-time phone grant produces an independent Watch bearer and phone logout revokes it",
       ctx do
    assert {:ok, grant} = WatchPairing.create(ctx.user, ctx.phone)
    refute inspect(grant) =~ ctx.phone["token"]
    assert {:ok, watch} = WatchPairing.exchange(grant)
    refute watch["token"] == ctx.phone["token"]
    assert {:ok, user, session} = Accounts.validate_session(watch["token"])
    assert user["id"] == ctx.user["id"]
    assert session["parent_session_id"] == ctx.phone["id"]
    assert session["client_kind"] == "watch"
    assert session["client_platform"] == "watchos"
    assert {:error, :invalid_watch_pairing} = WatchPairing.exchange(grant)
    assert {:error, :forbidden} = WatchPairing.create(user, session)
    assert :ok = Accounts.revoke_session_token(ctx.phone["token"])
    assert {:error, :revoked} = Accounts.validate_session(watch["token"])
    assert {:error, :revoked} = Accounts.resolve_session_id(watch["session_id"])
  end

  test "owner mutation checks deny a Watch whose phone session is revoked", ctx do
    {:ok, grant} = WatchPairing.create(ctx.user, ctx.phone)
    {:ok, watch} = WatchPairing.exchange(grant)
    assert :ok = Comma.Accounts.Sessions.authorize_current(ctx.user["id"], watch["session_id"])

    # Revoke only the parent row to exercise the pairing-parent check itself.
    Comma.Repo.update_all(
      from(s in AuthSession, where: s.id == ^ctx.phone["id"]),
      set: [revoked_at: DateTime.utc_now()]
    )

    assert {:error, :revoked} =
             Comma.Accounts.Sessions.authorize_current(ctx.user["id"], watch["session_id"])
  end

  test "a revoked phone grant cannot issue a bearer; Watch logout preserves the phone", ctx do
    {:ok, grant} = WatchPairing.create(ctx.user, ctx.phone)
    {:ok, watch} = WatchPairing.exchange(grant)
    :ok = Accounts.revoke_session_token(watch["token"])
    assert {:ok, _, _} = Accounts.validate_session(ctx.phone["token"])
    {:ok, pending} = WatchPairing.create(ctx.user, ctx.phone)
    :ok = Accounts.revoke_session(ctx.user["id"], ctx.phone["id"])
    assert {:error, :invalid_watch_pairing} = WatchPairing.exchange(pending)
  end

  test "phone expiry does not end an issued Watch session but disables pending exchange", ctx do
    {:ok, grant} = WatchPairing.create(ctx.user, ctx.phone)
    {:ok, watch} = WatchPairing.exchange(grant)
    {:ok, pending} = WatchPairing.create(ctx.user, ctx.phone)

    Repo.get!(AuthSession, ctx.phone["id"])
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:ok, _, _} = Accounts.validate_session(watch["token"])
    assert {:error, :invalid_watch_pairing} = WatchPairing.exchange(pending)
    {:ok, _} = Accounts.update_user(ctx.user["id"], %{"status" => "disabled"})
    assert {:error, :revoked} = Accounts.validate_session(watch["token"])
  end

  test "wrong grant secret never creates a session", ctx do
    {:ok, grant} = WatchPairing.create(ctx.user, ctx.phone)

    assert {:error, :invalid_watch_pairing} =
             WatchPairing.exchange(Map.put(grant, "pairing_secret", "wrong"))

    assert Repo.aggregate(
             from(session in AuthSession, where: session.auth_method == "watch_pairing"),
             :count
           ) == 0
  end
end
