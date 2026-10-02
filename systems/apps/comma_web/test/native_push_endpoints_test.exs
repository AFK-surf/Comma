defmodule CommaWeb.NativePushEndpointsTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias Comma.{Accounts, Repo}
  alias Comma.Notifications.Target

  @path "/v1/comma/notifications/devices"
  @opts CommaWeb.Router.init([])

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    Comma.PodLifecycle.reset_for_test()

    on_exit(fn ->
      CommaWeb.TestRepoSandbox.stop_owner(owner)
      Comma.PodLifecycle.reset_for_test()
    end)

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "unsubscribe-#{System.unique_integer([:positive])}@example.test"
      })

    {:ok, session} =
      Accounts.create_session(user["id"], client_kind: "ios", client_platform: "ios")

    %{user: user, session: session}
  end

  test "authenticated ID-free DELETE reconciles only this session's ordinary legacy slot", ctx do
    {:ok, watch} =
      Accounts.create_session(ctx.user["id"],
        auth_method: "watch_pairing",
        parent_session_id: ctx.session["id"],
        client_kind: "watch",
        client_platform: "watchos"
      )

    {:ok, second_phone} = Accounts.create_session(ctx.user["id"], client_kind: "ios")

    {:ok, outsider} =
      Accounts.create_user(%{
        "email" => "unsubscribe-other-#{System.unique_integer([:positive])}@example.test"
      })

    {:ok, outsider_session} = Accounts.create_session(outsider["id"])

    legacy_device = target(ctx.session, "device")

    survivors = [
      target(ctx.session, "live_activity"),
      target(ctx.session, "push_to_start"),
      target(watch, "device"),
      target(second_phone, "device"),
      target(outsider_session, "device")
    ]

    assert Enum.all?([legacy_device | survivors], &is_nil(&1.bundle_id))
    assert %{status: 401} = request(nil)
    assert Repo.get(Target, legacy_device.id)
    assert %{status: 204, resp_body: ""} = request(ctx.session["token"])
    assert Repo.get(Target, legacy_device.id) == nil
    assert Enum.all?(survivors, &Repo.get(Target, &1.id))
    assert %{status: 204, resp_body: ""} = request(ctx.session["token"])
    assert Enum.all?(survivors, &Repo.get(Target, &1.id))
  end

  test "restricted or revoked credentials cannot erase an ordinary registration", ctx do
    {:ok, restricted} =
      Accounts.create_session(ctx.user["id"], restricted: true, session_source: "ops_api")

    restricted_target = target(restricted, "device")
    ordinary_target = target(ctx.session, "device")
    assert %{status: 403} = request(restricted["token"])
    assert Repo.get(Target, restricted_target.id)
    assert Repo.get(Target, ordinary_target.id)
    assert :ok = Accounts.revoke_session_token(ctx.session["token"])
    assert %{status: 401} = request(ctx.session["token"])
    assert Repo.get(Target, ordinary_target.id)
  end

  defp request(token) do
    conn = conn(:delete, @path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    CommaWeb.Router.call(conn, @opts)
  end

  defp target(session, kind) do
    Repo.insert!(%Target{
      auth_session_id: session["id"],
      kind: kind,
      token: String.duplicate("a", 64),
      environment: "sandbox",
      workspace_id: "wsp_unsubscribe",
      group_id: "group_unsubscribe",
      conversation_id: if(kind == "live_activity", do: "task_unsubscribe"),
      activity_id: if(kind == "live_activity", do: "activity_unsubscribe"),
      expires_at: DateTime.add(DateTime.utc_now(), 3_600)
    })
  end
end
