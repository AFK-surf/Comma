defmodule SalixWeb.SignalTest do
  @moduledoc """
  Signal numbers and bindings (docs/messaging-voice.md): the platform number
  and a tenant's own number choose registered accounts by scope, a claim
  code created through the runtime API binds the Signal sender who sends it,
  and only bound peers ring. Also the Signal dashboard page and Group tab.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SalixSignal.{IMHandler, Settings}
  alias SalixSignal.Messaging.Inbound
  alias SalixSignalProto.Message.Content

  @endpoint SalixWeb.DashboardEndpoint

  setup do
    prev_api_token = Application.get_env(:salix_web, :api_token)
    Application.put_env(:salix_web, :api_token, "test-token")
    {:ok, _} = Settings.set_platform_number(nil)

    on_exit(fn ->
      _ = Settings.set_platform_number(nil)

      if prev_api_token,
        do: Application.put_env(:salix_web, :api_token, prev_api_token),
        else: Application.delete_env(:salix_web, :api_token)
    end)

    tenant_id = req(:post, "/v1/admin/tenants", json: %{name: "Signal"}).body["tenant_id"]

    tenant_key =
      req(:post, "/v1/admin/tenants/#{tenant_id}/api-keys", json: %{name: "test"}).body["key"]

    group = req_as(tenant_key, :post, "/v1/runtime/agent-groups", json: %{name: "Signal"}).body

    {:ok, tenant_id: tenant_id, tenant_key: tenant_key, group_id: group["group_id"]}
  end

  # A registered account with Comma-chosen identifiers; removed after the test.
  defp account!(scope, state \\ :active) do
    n = :rand.uniform(9_999_999)
    aci = "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
    number = "+1555" <> String.pad_leading(Integer.to_string(n), 7, "0")
    identity = SalixSignalProto.Keys.ec_keypair()

    {:ok, id} =
      SalixSignal.Accounts.create(%{
        aci: aci,
        pni: nil,
        e164: number,
        device_id: 1,
        password: "device-password",
        identities: %{aci: identity, pni: nil},
        registration_ids: %{aci: 1, pni: 0},
        profile_key: :binary.copy(<<7>>, 32),
        pre_keys: %{},
        scope: scope,
        environment: :staging,
        state: state
      })

    on_exit(fn ->
      SalixStore.Repo.query("DELETE FROM signal_accounts WHERE id = $1", [Ecto.UUID.dump!(id)])
    end)

    %{id: id, aci: aci, number: number}
  end

  defp sender,
    do: "00000000-0000-4000-8000-0000000000" <> Integer.to_string(10 + :rand.uniform(88))

  defp text_inbound(sender, text, timestamp) do
    %Inbound{
      guid: "guid-#{timestamp}",
      outcome: :message,
      sender: sender,
      sender_device: 1,
      destination: :aci,
      timestamp: timestamp,
      server_timestamp: timestamp + 5,
      content_kind: :data,
      content: Content.text(timestamp, text)
    }
  end

  test "the platform number and a tenant number select accounts by scope", ctx do
    platform = account!(:platform)
    own = account!({:organization, ctx.tenant_id})
    foreign = account!({:organization, "ten_other"})
    retired = account!(:platform, :retired)

    assert %{status: 200, body: %{"platform" => nil}} = req(:get, "/v1/admin/signal/settings")

    for {number, error} <- [
          {"+15559999999", "signal_account_not_found"},
          {own.number, "signal_account_scope"},
          {retired.number, "signal_account_inactive"},
          {"5550100", "number must be an E.164 number such as +15551234567"}
        ] do
      assert %{body: %{"error" => ^error}} =
               req(:put, "/v1/admin/signal/settings", json: %{number: number})
    end

    assert %{status: 200, body: %{"platform" => %{"e164" => e164, "state" => "active"}}} =
             req(:put, "/v1/admin/signal/settings", json: %{number: platform.number})

    assert e164 == platform.number

    assert %{status: 200, body: %{"effective" => %{"e164" => ^e164}, "override" => nil}} =
             req_as(ctx.tenant_key, :get, "/v1/runtime/signal/number")

    # A tenant may use its own organization's account, not another's.
    assert %{status: 422, body: %{"error" => "signal_account_scope"}} =
             req_as(ctx.tenant_key, :put, "/v1/runtime/signal/number",
               json: %{number: foreign.number}
             )

    assert %{status: 200, body: %{"effective" => %{"e164" => own_number}}} =
             req_as(ctx.tenant_key, :put, "/v1/runtime/signal/number",
               json: %{number: own.number}
             )

    assert own_number == own.number

    # The admin view of the same tenant shows the override; clearing it
    # falls back to the platform number.
    assert %{body: %{"override" => %{"e164" => ^own_number}}} =
             req(:get, "/v1/admin/tenants/#{ctx.tenant_id}/signal-number")

    assert %{status: 200, body: %{"override" => nil, "effective" => %{"e164" => ^e164}}} =
             req(:put, "/v1/admin/tenants/#{ctx.tenant_id}/signal-number", json: %{number: ""})
  end

  test "a claim code binds its sender; only bound peers ring", ctx do
    platform = account!(:platform)
    base = "/v1/runtime/agent-groups/#{ctx.group_id}/im-connects/signal"

    # Without a number there is nothing to message.
    assert %{status: 503, body: %{"error" => "signal_not_configured"}} =
             req_as(ctx.tenant_key, :post, base <> "/claims")

    {:ok, _} = Settings.set_platform_number(platform.number)

    response = req_as(ctx.tenant_key, :post, base <> "/claims")
    assert response.status == 200
    assert Req.Response.get_header(response, "cache-control") == ["no-store"]
    claim = response.body["claim"]
    assert claim["number"] == platform.number
    assert claim["command"] =~ ~r/\Acomma connect \S{4}-\S{4}\z/

    # The status shows the pending claim, never its code.
    status = req_as(ctx.tenant_key, :get, base).body
    assert [%{"claim_id" => claim_id}] = status["pending_claims"]
    assert claim_id == claim["claim_id"]
    refute inspect(status) =~ claim["code"]

    alice = sender()
    assert :needs_permission = IMHandler.incoming_call(platform.id, %{peer_aci: alice})

    assert :ok =
             IMHandler.handle_inbound(
               platform.id,
               1,
               text_inbound(alice, claim["command"], 1_700_000_000_000)
             )

    status = req_as(ctx.tenant_key, :get, base).body

    assert [%{"binding_id" => binding_id, "peer" => ^alice, "kind" => "user"} = binding] =
             status["bindings"]

    assert binding["number"] == platform.number
    assert status["pending_claims"] == []
    assert :ring = IMHandler.incoming_call(platform.id, %{peer_aci: alice})

    assert :needs_permission =
             IMHandler.incoming_call(platform.id, %{peer_aci: sender_other(alice)})

    # Another tenant's key cannot see or change the Group's bindings.
    other = req(:post, "/v1/admin/tenants", json: %{name: "Other"}).body["tenant_id"]
    other_key = req(:post, "/v1/admin/tenants/#{other}/api-keys", json: %{name: "t"}).body["key"]
    assert %{status: 404} = req_as(other_key, :delete, base <> "/bindings/#{binding_id}")

    assert %{status: 200, body: %{"bindings" => []}} =
             req_as(ctx.tenant_key, :delete, base <> "/bindings/#{binding_id}")

    assert :needs_permission = IMHandler.incoming_call(platform.id, %{peer_aci: alice})
  end

  test "the Signal page sets the platform number and the Group tab creates a code", ctx do
    platform = account!(:platform)

    conn =
      Plug.Test.init_test_session(build_conn(), %{
        "admin_authed" => true,
        "current_tenant" => ctx.tenant_id
      })

    {:ok, view, html} = live(conn, "/dash/signal")
    assert html =~ "not set"
    assert html =~ platform.number

    html =
      view |> form("#signal-platform-number", %{"number" => platform.number}) |> render_submit()

    assert html =~ "Platform Signal number saved."
    assert {:ok, %{"e164" => number}} = Settings.platform()
    assert number == platform.number

    {:ok, view, html} = live(conn, "/dash/groups/#{ctx.group_id}?tab=signal")
    assert html =~ "No connected Signal chats"

    html = render_click(element(view, "#signal-start-claim"))
    assert html =~ "comma connect "
    assert html =~ platform.number

    html = render_click(element(view, "button[phx-click=dismiss-signal-claim]"))
    refute html =~ "comma connect "
    assert html =~ "Pending codes"

    {:ok, view, _html} = live(conn, "/dash/tenants/#{ctx.tenant_id}")
    html = view |> form("#tenant-signal-number", %{"number" => "+15559999999"}) |> render_submit()
    assert html =~ "signal_account_not_found"
  end

  defp sender_other(aci), do: String.replace(aci, ~r/..\z/, "99")

  defp req(method, path, opts \\ []), do: req_as("test-token", method, path, opts)

  defp req_as(token, method, path, opts \\ []) do
    Req.request!(
      [
        method: method,
        url: SalixWeb.Application.base_url() <> path,
        headers: [{"authorization", "Bearer " <> token}],
        retry: false
      ] ++ opts
    )
  end
end
