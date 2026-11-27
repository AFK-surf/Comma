defmodule Salix.Control.ColabPluginContractTest do
  use SystemsClock.Case, async: false

  alias Salix.Control.{Groups, Plugins, PluginSetup, Tenants}
  alias SalixAgent.Colab.{Account, Leases}

  @client_id "test-colab-client-id"
  @colab_scope "https://www.googleapis.com/auth/colaboratory"

  setup do
    previous_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_oauth = SystemsRuntime.get_env(:salix_agent, :colab_oauth)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    {:ok, tenant} = Tenants.create(%{"name" => "Colab Contract Test"})
    {:ok, group} = Groups.create(%{"name" => "Colab Group"}, tenant["tenant_id"])

    on_exit(fn ->
      if previous_store,
        do: SystemsRuntime.put_env(:salix_store, :s3_backend, previous_store),
        else: SystemsRuntime.delete_env(:salix_store, :s3_backend)

      if previous_oauth,
        do: SystemsRuntime.put_env(:salix_agent, :colab_oauth, previous_oauth),
        else: SystemsRuntime.delete_env(:salix_agent, :colab_oauth)

      cleanup_colab_tables(tenant["tenant_id"], group["group_id"])
    end)

    %{tenant_id: tenant["tenant_id"], group_id: group["group_id"]}
  end

  test "google-colab system definition, cached plugin_enabled?/3, and PluginSetup contract", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    assert {:ok, definition} = Plugins.get_definition(tenant_id, group_id, "google-colab")
    assert definition["default_enabled"] == false
    assert definition["ui"]["brand"] == "google-colab"
    assert definition["ui"]["category"] == "Compute"
    assert definition["ui"]["requires"] == ["plugin-oauth-code"]
    assert get_in(definition, ["setup", "mcps"]) == []
    assert get_in(definition, ["refs", "tool_refs"]) == ["colab.*"]
    assert get_in(definition, ["refs", "skill_refs"]) == ["colab-gpu"]

    # credential_setup returns nil for oauth_code_paste
    assert PluginSetup.credential_setup(definition) == nil

    # prepare preserves %{"connection" => ..., "bindings" => []}
    assert {:ok, %{"connection" => conn, "bindings" => []}} =
             PluginSetup.prepare(tenant_id, group_id, definition, "google-colab-oauth")

    assert conn["kind"] == "oauth_code_paste"
    assert conn["provider"] == "google_colab"

    # plugin_enabled?/3 uses PluginCatalogCache and tracks enable/disable
    assert Plugins.plugin_enabled?(tenant_id, group_id, "google-colab") == false
    assert {:ok, _} = Plugins.enable_group(tenant_id, group_id, "google-colab")
    assert Plugins.plugin_enabled?(tenant_id, group_id, "google-colab") == true
    assert {:ok, _} = Plugins.disable_group(tenant_id, group_id, "google-colab")
    assert Plugins.plugin_enabled?(tenant_id, group_id, "google-colab") == false

    # resolve_statuses reflects Colab.Account.connection_state/2
    [before_connect] = PluginSetup.resolve_statuses([definition], tenant_id, group_id)

    assert get_in(before_connect, ["setup_status", "connections"]) |> hd() |> Map.get("state") ==
             "not_connected"

    configure_colab_oauth()

    {:ok, attempt} =
      Account.start_oauth_attempt(tenant_id, group_id, "usr_1", operation: :install)

    state = URI.decode_query(URI.parse(attempt.authorize_url).query)["state"]

    assert {:ok, _} =
             Account.complete_oauth_attempt(
               tenant_id,
               group_id,
               "usr_1",
               attempt.attempt_id,
               "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/ok&state=#{state}",
               operation: :install
             )

    [after_connect] = PluginSetup.resolve_statuses([definition], tenant_id, group_id)

    assert get_in(after_connect, ["setup_status", "connections"]) |> hd() |> Map.get("state") ==
             "connected"

    # disconnect_credentials delegates to Colab.Account.disconnect_all_for_group/2
    assert :ok =
             PluginSetup.disconnect_credentials(
               tenant_id,
               group_id,
               definition,
               "google-colab-oauth"
             )

    [after_disconnect] = PluginSetup.resolve_statuses([definition], tenant_id, group_id)

    assert get_in(after_disconnect, ["setup_status", "connections"]) |> hd() |> Map.get("state") ==
             "not_connected"
  end

  test "Groups.delete/1 retires group Colab state inside transaction without Google HTTP", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    configure_colab_oauth()

    {:ok, attempt} =
      Account.start_oauth_attempt(tenant_id, group_id, "usr_1", operation: :install)

    state = URI.decode_query(URI.parse(attempt.authorize_url).query)["state"]

    {:ok, %{binding_id: binding_id}} =
      Account.complete_oauth_attempt(
        tenant_id,
        group_id,
        "usr_1",
        attempt.attempt_id,
        "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/ok&state=#{state}",
        operation: :install
      )

    {:ok, lease, _} =
      Leases.insert_assigning(
        tenant_id,
        group_id,
        "session:ag:grpdel",
        nil,
        binding_id,
        %{variant: "GPU", accelerator: "G4", high_mem: false}
      )

    {:ok, _active} =
      Leases.promote_active(lease.vm_id, 1, "m-s-grpdel-1", "https://abc.prod.colab.dev")

    # Replace plug with one that fails if any HTTP request is made during Groups.delete
    SystemsRuntime.put_env(:salix_agent, :colab_oauth,
      req_options: [plug: fn _conn -> raise "no Google HTTP allowed inside Groups.delete tx" end]
    )

    assert :ok = Groups.delete(group_id)

    # Group retirement fence blocks new attempts
    assert {:error, :scope_retired} =
             Account.start_oauth_attempt(tenant_id, group_id, "usr_1", operation: :install)

    # Active lease transitioned to stopping for Reaper
    assert {:ok, stopped_lease} = Leases.get_by_id(lease.vm_id)
    assert stopped_lease.state == "stopping"
  end

  defp configure_colab_oauth do
    SystemsRuntime.put_env(:salix_agent, :colab_oauth,
      client_id: @client_id,
      client_secret: "test-secret",
      redirect_uri: "https://sdk.cloud.google.com/applicationdefaultauthcode.html",
      auth_uri: "https://accounts.google.com/o/oauth2/auth",
      token_uri: "https://oauth2.googleapis.com/token",
      userinfo_uri: "https://www.googleapis.com/oauth2/v2/userinfo",
      colab_base_url: "https://colab.research.google.com",
      req_options: [
        plug: fn conn ->
          now = SystemsClock.system_time(:second)

          case conn.request_path do
            "/token" ->
              header =
                Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}),
                  padding: false
                )

              payload =
                Base.url_encode64(
                  Jason.encode!(%{
                    "iss" => "https://accounts.google.com",
                    "aud" => @client_id,
                    "sub" => "sub-contract-1",
                    "email" => "contract@gmail.com",
                    "exp" => now + 3600
                  }),
                  padding: false
                )

              Plug.Conn.send_resp(
                conn |> Plug.Conn.put_resp_content_type("application/json"),
                200,
                Jason.encode!(%{
                  "access_token" => "ya29.contract",
                  "refresh_token" => "1//refresh-contract",
                  "expires_in" => 3600,
                  "token_type" => "Bearer",
                  "scope" =>
                    "openid https://www.googleapis.com/auth/userinfo.email #{@colab_scope}",
                  "id_token" => "#{header}.#{payload}.sig"
                })
              )

            "/tun/m/ccu-info" ->
              Plug.Conn.send_resp(
                conn |> Plug.Conn.put_resp_content_type("application/json"),
                200,
                ")]}\'\n" <>
                  Jason.encode!(%{"currentBalance" => 500.0, "consumptionRateHourly" => 1.0})
              )

            _ ->
              Plug.Conn.send_resp(conn, 404, "not found")
          end
        end
      ]
    )
  end

  defp cleanup_colab_tables(tenant_id, group_id) do
    for table <- [
          "colab_vm_leases",
          "colab_accounts",
          "colab_group_install_states",
          "colab_oauth_attempts"
        ] do
      _ = SalixStore.Repo.query("DELETE FROM #{table} WHERE tenant_id = $1", [tenant_id])
    end

    _ =
      SalixStore.Repo.query(
        "DELETE FROM colab_retired_scopes WHERE scope_key IN ($1, $2)",
        ["tenant:" <> tenant_id, "group:" <> group_id]
      )
  end
end
