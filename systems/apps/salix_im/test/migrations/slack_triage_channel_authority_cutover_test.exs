defmodule SalixIM.Migrations.SlackTriageChannelAuthorityCutoverTest do
  use ExUnit.Case, async: false

  alias SalixIM.Migrations.SlackTriageChannelAuthorityCutover
  alias SalixIM.ProviderConnects

  alias SalixStore.{
    CasRecord,
    Ids,
    Keys,
    Repo,
    S3,
    SlackTriageChannelCutover,
    SlackTriageChannels,
    ULID
  }

  defmodule LeakyErrorS3 do
    @behaviour SalixStore.S3

    alias SalixStore.S3.Fake

    def fail_next_list(body), do: Process.put({__MODULE__, :list_error}, body)
    def fail_get(key, body), do: Process.put({__MODULE__, :get_error, key}, body)

    @impl true
    def list(prefix, opts) do
      case Process.delete({__MODULE__, :list_error}) do
        nil -> Fake.list(prefix, opts)
        body -> {:error, {:http, 503, body}}
      end
    end

    @impl true
    def get(key, opts) do
      case Process.delete({__MODULE__, :get_error, key}) do
        nil -> Fake.get(key, opts)
        body -> {:error, {:http, 503, body}}
      end
    end

    @impl true
    defdelegate put(key, body, opts), to: Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: Fake

    @impl true
    defdelegate stream(key, opts), to: Fake

    @impl true
    defdelegate head(key), to: Fake

    @impl true
    defdelegate delete(key, opts), to: Fake

    @impl true
    defdelegate multipart_create(key, opts), to: Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body), to: Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: Fake

    @impl true
    defdelegate multipart_uploads(prefix, opts), to: Fake
  end

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    Repo.query!("""
    DELETE FROM salix_cutover_markers
    WHERE name IN ('slack_triage_channels_v1', 'slack_triage_channels_v1_preparing')
    """)

    Repo.query!("DELETE FROM slack_triage_channels")

    on_exit(fn ->
      restore(:salix_store, :s3_backend, previous_backend)

      Repo.query!("""
      DELETE FROM salix_cutover_markers
      WHERE name IN ('slack_triage_channels_v1', 'slack_triage_channels_v1_preparing')
      """)

      Repo.query!("DELETE FROM slack_triage_channels")

      Repo.query!("""
      INSERT INTO salix_cutover_markers (name, completed_at, evidence)
      VALUES ('slack_triage_channels_v1', now(), '{"mode":"test-baseline"}'::jsonb)
      ON CONFLICT (name) DO NOTHING
      """)
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    router_agent_id = Ids.new_agent_id(group_id)

    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Slack cutover"})

    router =
      SalixAgent.TestSupport.create_control_agent!(router_agent_id, %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "name" => "Router",
        "role" => "router"
      })

    {:ok, _group} =
      CasRecord.update(Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router["agent_id"])
      end)

    {:ok, tenant_id: tenant_id, group_id: group_id, router_agent_id: router["agent_id"]}
  end

  test "publishes projected authority without inventing a channel for an uninitialized source",
       %{tenant_id: tenant_id, group_id: group_id, router_agent_id: router_agent_id} do
    legacy =
      create_slack_connect!(tenant_id, group_id, router_agent_id, "legacy", %{
        "approved_channel_id" => "C-legacy",
        "approved_channel_name" => "triage",
        "triage_enabled" => true,
        "triage_provisioned_at" => 1
      })

    legacy_without_setup_marker =
      create_slack_connect!(tenant_id, group_id, router_agent_id, "legacy-no-marker", %{
        "approved_channel_id" => "C-legacy-no-marker",
        "approved_channel_name" => "triage-legacy-no-marker",
        "triage_enabled" => false
      })

    uninitialized =
      create_slack_connect!(tenant_id, group_id, router_agent_id, "uninitialized", %{
        "triage_enabled" => false
      })

    assert {:ok, _rogue_dark_row} =
             SlackTriageChannels.provision(%{
               "tenant_id" => tenant_id,
               "group_id" => group_id,
               "connect_id" => uninitialized["connect_id"],
               "channel_id" => "C-invented",
               "installation_generation" => uninitialized["connect_generation"],
               "workspace_id" => uninitialized["workspace_id"],
               "channel_name" => "must-not-publish",
               "channel_generation" => ULID.generate()
             })

    assert {:ok, captured} =
             ProviderConnects.get_slack_triage_authority(
               tenant_id,
               group_id,
               legacy["connect_id"],
               legacy["approved_channel_id"]
             )

    assert {:ok, %{materialized: 2, verified: 2, already_projected: false}} =
             SlackTriageChannelAuthorityCutover.run()

    assert :projected = SlackTriageChannelCutover.mode()

    assert {:ok, channel} =
             SlackTriageChannels.get(
               tenant_id,
               group_id,
               legacy["connect_id"],
               legacy["approved_channel_id"]
             )

    assert channel["installation_generation"] == legacy["connect_generation"]
    assert channel["workspace_id"] == legacy["workspace_id"]
    assert channel["channel_name"] == legacy["approved_channel_name"]

    assert channel["channel_generation"] ==
             ULID.derive("comma.slack-triage-legacy-authority.v1", [
               legacy["connect_generation"],
               legacy["triage_activation_generation"]
             ])

    assert {:ok, ^captured} =
             ProviderConnects.get_slack_triage_authority(
               tenant_id,
               group_id,
               legacy["connect_id"],
               legacy["approved_channel_id"]
             )

    assert {:ok, preserved_legacy_channel} =
             SlackTriageChannels.get(
               tenant_id,
               group_id,
               legacy_without_setup_marker["connect_id"],
               legacy_without_setup_marker["approved_channel_id"]
             )

    assert preserved_legacy_channel["channel_name"] ==
             legacy_without_setup_marker["approved_channel_name"]

    assert :ok =
             ProviderConnects.set_slack_triage_enabled(
               tenant_id,
               group_id,
               legacy_without_setup_marker["connect_id"],
               true
             )

    assert {:ok, reenabled_legacy} =
             ProviderConnects.fetch_im_connect(
               group_id,
               legacy_without_setup_marker["connect_id"]
             )

    assert reenabled_legacy["triage_enabled"] == true

    assert {:error, :not_found} =
             SlackTriageChannels.get(
               tenant_id,
               group_id,
               uninitialized["connect_id"],
               "C-invented"
             )

    assert {:ok,
            %{
              channels: [],
              scan_complete: true,
              channel_controls_available?: true,
              authority_valid?: false
            }} =
             ProviderConnects.list_configured_slack_triage_channels(
               tenant_id,
               group_id,
               uninitialized["connect_id"]
             )

    assert {:ok, %{already_projected: true}} = SlackTriageChannelAuthorityCutover.run()
  end

  test "materializes a legacy authority without its presentation-only channel name",
       %{tenant_id: tenant_id, group_id: group_id, router_agent_id: router_agent_id} do
    legacy =
      create_slack_connect!(tenant_id, group_id, router_agent_id, "legacy-no-name", %{
        "approved_channel_id" => "C-legacy-no-name",
        "triage_enabled" => false,
        "triage_provisioned_at" => 1
      })

    assert {:ok, %{materialized: 1, verified: 1, already_projected: false}} =
             SlackTriageChannelAuthorityCutover.run()

    assert {:ok, channel} =
             SlackTriageChannels.get(
               tenant_id,
               group_id,
               legacy["connect_id"],
               legacy["approved_channel_id"]
             )

    assert channel["channel_name"] == "Slack"
  end

  test "keeps the final marker closed and resumes the same preparation after an S3 scan failure",
       %{tenant_id: tenant_id, group_id: group_id, router_agent_id: router_agent_id} do
    legacy =
      create_slack_connect!(tenant_id, group_id, router_agent_id, "retry", %{
        "approved_channel_id" => "C-retry",
        "approved_channel_name" => "triage-retry",
        "triage_enabled" => true,
        "triage_provisioned_at" => 1
      })

    assert :ok =
             S3.Fake.set_fault({:fail, 503, :list, Keys.ctl_im_connects_all_prefix()})

    assert {:error, {:slack_triage_channel_scan_failed, _reason}} =
             SlackTriageChannelAuthorityCutover.run()

    assert :legacy = SlackTriageChannelCutover.mode()

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT 1 FROM salix_cutover_markers WHERE name = 'slack_triage_channels_v1_preparing'"
             )

    assert %{rows: []} =
             Repo.query!(
               "SELECT 1 FROM salix_cutover_markers WHERE name = 'slack_triage_channels_v1'"
             )

    assert {:ok, %{materialized: 1, verified: 1, already_projected: false}} =
             SlackTriageChannelAuthorityCutover.run()

    assert {:ok, _channel} =
             SlackTriageChannels.get(
               tenant_id,
               group_id,
               legacy["connect_id"],
               legacy["approved_channel_id"]
             )
  end

  test "redacts raw S3 LIST and GET error bodies before release logging",
       %{tenant_id: tenant_id, group_id: group_id, router_agent_id: router_agent_id} do
    secret_coordinate =
      ~s({"tenant_id":"#{tenant_id}","group_id":"#{group_id}","connect_id":"private"})

    Application.put_env(:salix_store, :s3_backend, LeakyErrorS3)
    LeakyErrorS3.fail_next_list(secret_coordinate)

    assert {:error, {:slack_triage_channel_scan_failed, list_reason}} =
             SlackTriageChannelAuthorityCutover.run()

    assert list_reason == {:http, 503}
    refute inspect(list_reason) =~ tenant_id
    refute inspect(list_reason) =~ group_id

    legacy =
      create_slack_connect!(tenant_id, group_id, router_agent_id, "leaky-get", %{
        "approved_channel_id" => "C-leaky-get",
        "approved_channel_name" => "triage-leaky-get",
        "triage_enabled" => false
      })

    connect_key = Keys.ctl_im_connect(group_id, legacy["connect_id"])
    LeakyErrorS3.fail_get(connect_key, secret_coordinate)

    assert {:error, {:slack_triage_connect_unavailable, _safe_key, get_reason}} =
             SlackTriageChannelAuthorityCutover.run()

    assert get_reason == {:http, 503}
    refute inspect(get_reason) =~ tenant_id
    refute inspect(get_reason) =~ group_id
  end

  defp create_slack_connect!(tenant_id, group_id, router_agent_id, label, extra) do
    connect_id = Ids.new_connect_id()

    record =
      Map.merge(
        %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "connect_id" => connect_id,
          "provider" => "slack",
          "app_id" => "A-#{label}",
          "bot_token" => "xoxb-#{label}",
          "bot_id" => "B-#{label}",
          "bot_user_id" => "U-#{label}",
          "workspace_id" => "T-#{label}",
          "workspace_name" => "Workspace #{label}",
          "inbound_agent_id" => router_agent_id,
          "connect_generation" => ULID.generate(),
          "triage_activation_generation" => ULID.generate(),
          "oauth_completed_at" => 1,
          "triage_enabled" => false,
          "created_at" => 1,
          "updated_at" => 1
        },
        extra
      )

    assert {:ok, ^record} = CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), record)
    record
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
