defmodule Salix.Bindings.MeetingChannelTest do
  use ExUnit.Case, async: false

  alias Salix.Bindings.MeetingChannel
  alias Salix.Control.Store, as: ControlStore
  alias Salix.Control.Tenants
  alias SalixStore.{Ids, Keys}

  setup do
    previous_s3 = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    ensure_started!(SalixStore.S3.Fake)
    SalixStore.S3.Fake.reset()
    SalixAgent.TestSupport.stop_all_agents()

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    router_agent_id = Ids.new_agent_id(group_id)

    assert {:ok, _tenant} = Tenants.create_preallocated(%{"name" => "Channel tenant"}, tenant_id)

    router =
      SalixAgent.TestSupport.create_control_agent!(router_agent_id, %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "name" => "Router",
        "role" => "router"
      })

    assert {:ok, _group} =
             ControlStore.update_record(Keys.ctl_group(group_id), fn group ->
               Map.put(group, "router_agent_id", router["agent_id"])
             end)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore_env(:salix_store, :s3_backend, previous_s3)
    end)

    {:ok, tenant_id: tenant_id, group_id: group_id, router_agent_id: router_agent_id}
  end

  test "returns the resolved target when the connect is valid and router-visible", context do
    seed_connect(context, "slack-primary", "T-primary")

    assert {:ok,
            %{
              "connect_id" => "slack-primary",
              "workspace_id" => "T-primary",
              "channel_id" => "C-x"
            }} =
             MeetingChannel.resolve(group(context, "slack-primary", "T-primary", "C-x"))
  end

  test "rejects a group missing the resolved channel target", context do
    seed_connect(context, "slack-primary", "T-primary")

    assert {:error, :meeting_slack_target_not_configured} =
             MeetingChannel.resolve(%{
               "tenant_id" => context.tenant_id,
               "group_id" => context.group_id
             })
  end

  test "rejects a workspace that does not own the exact connect", context do
    seed_connect(context, "slack-primary", "T-actual")

    assert {:error, :meeting_slack_workspace_mismatch} =
             MeetingChannel.resolve(group(context, "slack-primary", "T-configured", "C-x"))
  end

  test "rejects a disabled connect", context do
    seed_connect(context, "slack-disabled", "T-primary", disabled_at: 100)

    assert {:error, _reason} =
             MeetingChannel.resolve(group(context, "slack-disabled", "T-primary", "C-x"))
  end

  test "rejects a connect that is not router-visible", context do
    worker_id = Ids.new_agent_id(context.group_id)

    _worker =
      SalixAgent.TestSupport.create_control_agent!(worker_id, %{
        "tenant_id" => context.tenant_id,
        "group_id" => context.group_id,
        "name" => "Worker",
        "role" => "worker"
      })

    seed_connect(context, "slack-worker", "T-primary", inbound_agent_id: worker_id)

    assert {:error, _reason} =
             MeetingChannel.resolve(group(context, "slack-worker", "T-primary", "C-x"))
  end

  defp group(context, connect_id, workspace_id, channel_id) do
    %{
      "tenant_id" => context.tenant_id,
      "group_id" => context.group_id,
      "connect_id" => connect_id,
      "workspace_id" => workspace_id,
      "channel_id" => channel_id
    }
  end

  defp seed_connect(context, connect_id, workspace_id, opts \\ []) do
    record = %{
      "tenant_id" => context.tenant_id,
      "group_id" => context.group_id,
      "connect_id" => connect_id,
      "provider" => "slack",
      "workspace_id" => workspace_id,
      "workspace_name" => workspace_id,
      "bot_token" => "xoxb-#{connect_id}",
      "oauth_completed_at" => 1,
      "inbound_agent_id" => Keyword.get(opts, :inbound_agent_id, context.router_agent_id),
      "disabled_at" => Keyword.get(opts, :disabled_at),
      "created_at" => 100,
      "updated_at" => 100
    }

    assert {:ok, _record} =
             SalixStore.CasRecord.create(
               Keys.ctl_im_connect(context.group_id, connect_id),
               record
             )
  end

  defp ensure_started!(module) do
    case Process.whereis(module) do
      nil -> start_supervised!(module)
      _pid -> :ok
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
