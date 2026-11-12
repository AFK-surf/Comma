defmodule Comma.AuthAbuseLifecycleTest do
  use Comma.DataCase, async: false
  alias Comma.Auth.Abuse.AppleKey
  setup {Comma.AuthAbuseTestSupport, :setup}

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  test "confirmed email change retires the old target; deletion retains current keys until due" do
    old_email = "attest-old@example.test"
    new_email = "attest-new@example.test"
    {:ok, user} = Comma.Accounts.create_user(%{"email" => old_email})
    old_key = key!("old-target-key", old_email)
    unrelated = key!("unrelated-key", "unrelated@example.test")

    historical =
      Repo.insert!(%AppleKey{
        unrelated
        | key_id: "prior-secret-key",
          email_fingerprint: "prior-secret-fingerprint"
      })

    {:ok, session} = Comma.Accounts.create_session(user["id"])

    assert {:ok, _} = Comma.EmailChange.change(user["id"], new_email)
    assert Repo.get(AppleKey, old_key.key_id) == nil
    assert Repo.get!(AppleKey, unrelated.key_id)
    assert Repo.get!(AppleKey, historical.key_id)
    assert {:ok, _, _} = Comma.Accounts.resolve_session(session["token"])

    current = key!("new-target-key", new_email)
    {:ok, code} = Comma.AccountDeletion.request_code(user["id"], %{})
    assert {:ok, due} = Comma.AccountDeletion.schedule(user["id"], code)
    assert Repo.get!(AppleKey, current.key_id)
    Comma.AccountDeletion.delete_due(DateTime.add(due, -1))
    assert Repo.get!(AppleKey, current.key_id)
    Comma.AccountDeletion.delete_due(due)
    assert Repo.get(AppleKey, current.key_id) == nil
    assert Repo.get!(AppleKey, unrelated.key_id)
    assert Repo.get!(AppleKey, historical.key_id)
  end

  defp key!(id, email) do
    {:ok, target} = Comma.AuthChallenges.email_fingerprint(email)

    Repo.insert!(%AppleKey{
      key_id: id,
      email_fingerprint: target,
      app_id: "TEAMID.surf.comma.ios",
      environment: "production",
      public_key: <<1, 2, 3>>,
      counter: 0,
      inserted_at: SystemsClock.timestamp(:utc_datetime_usec)
    })
  end
end
