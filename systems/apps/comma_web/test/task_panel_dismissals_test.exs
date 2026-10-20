defmodule CommaWeb.TaskPanelDismissalsTest do
  use SystemsClock.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias Comma.Accounts
  @opts CommaWeb.Router.init([])
  @path "/v1/comma/me/task-panel-dismissals"

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    on_exit(fn -> CommaWeb.TestRepoSandbox.stop_owner(owner) end)
    {user, session} = signed_in("dismissals")
    %{user: user, session: session}
  end

  test "a dismissal made on one device is listed with its Task version on every session", ctx do
    {:ok, other_device} = Accounts.create_session(ctx.user["id"])
    assert listed(request(:get, @path, other_device)) == []

    assert %{status: 200} = dismiss(ctx.session, [{"cnv_a", 10}])

    assert %{status: 200} = dismiss(ctx.session, [{"cnv_b", 20}, {"cnv_b", 25}])

    assert listed(request(:get, @path, other_device)) == [{"cnv_b", 25}, {"cnv_a", 10}]

    # A dismissal never moves back to an older version, and moves to the front.
    assert listed(dismiss(other_device, [{"cnv_a", 5}])) == [{"cnv_a", 10}, {"cnv_b", 25}]
    assert listed(dismiss(other_device, [{"cnv_a", 30}])) == [{"cnv_a", 30}, {"cnv_b", 25}]
  end

  test "keeps the 300 most recently dismissed", ctx do
    first = Enum.map(1..300, &{"cnv_#{&1}", &1})
    assert %{status: 200} = dismiss(ctx.session, first)
    assert %{status: 200} = dismiss(ctx.session, [{"cnv_new", 1}])

    kept = listed(request(:get, @path, ctx.session))
    assert length(kept) == 300
    assert hd(kept) == {"cnv_new", 1}
    assert length(kept -- first) == 1
  end

  test "rejects malformed requests", ctx do
    assert %{status: 400} = request(:post, @path, ctx.session, %{})
    assert %{status: 400} = request(:post, @path, ctx.session, %{"dismissals" => []})
    assert %{status: 400} = dismiss(ctx.session, [{"", 1}])
    assert %{status: 400} = dismiss(ctx.session, [{String.duplicate("x", 257), 1}])
    assert %{status: 400} = dismiss(ctx.session, [{"cnv_a", -1}])
    assert %{status: 400} = dismiss(ctx.session, [{"cnv_a", 1.5}])

    assert %{status: 400} =
             request(:post, @path, ctx.session, %{"dismissals" => [%{"task_id" => "cnv_a"}]})

    assert %{status: 400} = dismiss(ctx.session, Enum.map(1..301, &{"cnv_#{&1}", 1}))
  end

  test "another account, a restricted session and a revoked session see none of them", ctx do
    assert %{status: 200} = dismiss(ctx.session, [{"cnv_a", 1}])

    {_other, other_session} = signed_in("dismissals-other")
    assert listed(request(:get, @path, other_session)) == []

    {:ok, restricted} =
      Accounts.create_session(ctx.user["id"], restricted: true, session_source: "ops_api")

    assert %{status: 403} = request(:get, @path, restricted)
    assert %{status: 403} = dismiss(restricted, [{"cnv_x", 1}])

    assert :ok = Accounts.revoke_session_token(ctx.session["token"])
    assert %{status: 401} = request(:get, @path, ctx.session)
  end

  defp signed_in(prefix) do
    {:ok, user} =
      Accounts.create_user(%{
        "email" => "#{prefix}-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, session} = Accounts.create_session(user["id"])
    {user, session}
  end

  defp dismiss(session, dismissals) do
    body =
      Enum.map(dismissals, fn {id, revision} -> %{"task_id" => id, "revision" => revision} end)

    request(:post, @path, session, %{"dismissals" => body})
  end

  defp listed(%{status: 200, resp_body: body}),
    do: Enum.map(Jason.decode!(body)["data"], &{&1["task_id"], &1["revision"]})

  defp request(method, path, session, body \\ nil) do
    conn =
      if body,
        do:
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    conn
    |> put_req_header("authorization", "Bearer " <> session["token"])
    |> then(&CommaWeb.Router.call(&1, @opts))
  end
end
