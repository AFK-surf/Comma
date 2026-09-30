defmodule SalixIM.TriageEngineFixtures do
  @moduledoc """
  Durable fixtures for the native Triage engine suites.

  These source-independent engine tests use a test-only historical v2 writer so
  they can control event ids and timestamps exactly. Current ingress coverage
  uses ClickHouse v3 fixtures in the patrol and acceptance suites. Both paths
  still pass through current authority verification and
  `Runtime.accept_current/3`.
  """

  import ExUnit.Assertions

  alias SalixIM.ProviderConnects
  alias SalixIM.TestSupport.LegacyCallbackReceipts
  alias SalixIM.Triage.Runtime
  alias SalixStore.{CasRecord, Ids, Keys, ULID}

  @root_thread_ts "1787019000.000000"

  @doc "Builds and durably seeds one verifiable Slack Triage authority."
  def authority!(opts \\ []) do
    unless Process.whereis(Ids), do: ExUnit.Callbacks.start_supervised!(Ids)

    tenant_id = Keyword.get(opts, :tenant_id, Ids.new_tenant_id())
    group_id = Keyword.get(opts, :group_id, Ids.new_group_id(tenant_id))

    authority = %{
      "provider" => "slack",
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => Keyword.get(opts, :connect_id, Ids.new_connect_id()),
      "connect_generation" => Keyword.get(opts, :connect_generation, ULID.generate()),
      "workspace_id" => Keyword.get(opts, :workspace_id, "T_ATLAS"),
      "approved_channel_id" => Keyword.get(opts, :approved_channel_id, "C_ATLAS"),
      "inbound_agent_id" => Keyword.get(opts, :inbound_agent_id, Ids.new_agent_id(group_id)),
      "app_id" => "A_BFT",
      "bot_user_id" => "U_BFT",
      "bot_id" => "B_BFT",
      "oauth_completed_at" => 1,
      "triage_enabled" => true
    }

    seed_authority!(authority)
    authority
  end

  @doc "Writes the durable group and connect records one authority is read from."
  def seed_authority!(authority) do
    group = %{
      "tenant_id" => authority["tenant_id"],
      "group_id" => authority["group_id"],
      "router_agent_id" => authority["inbound_agent_id"],
      "router_conversation_id" => "conv-#{authority["group_id"]}"
    }

    connect =
      authority
      |> Map.put("bot_token", "xoxb-private")
      |> Map.put("disabled_at", nil)
      |> Map.put("deleted_at", nil)

    case CasRecord.create(Keys.ctl_group(authority["group_id"]), group) do
      {:ok, _created} -> :ok
      {:error, :exists} -> :ok
    end

    case CasRecord.create(
           Keys.ctl_im_connect(authority["group_id"], authority["connect_id"]),
           connect
         ) do
      {:ok, _created} -> :ok
      {:error, :exists} -> :ok
    end

    assert {:ok, _channel} =
             SalixStore.SlackTriageChannels.provision(%{
               "tenant_id" => authority["tenant_id"],
               "group_id" => authority["group_id"],
               "connect_id" => authority["connect_id"],
               "channel_id" => authority["approved_channel_id"],
               "installation_generation" => authority["connect_generation"],
               "workspace_id" => authority["workspace_id"],
               "channel_name" => "triage",
               # This is the release materialization shape: the legacy alpha
               # retains its authority generation across the PG cutover.
               "channel_generation" => authority["connect_generation"]
             })

    assert {:ok, ^authority} =
             ProviderConnects.get_slack_triage_authority(
               authority["tenant_id"],
               authority["group_id"],
               authority["connect_id"]
             )

    :ok
  end

  @doc "One historical verified callback envelope for engine-only fixtures."
  def verified_root(authority, event_id, opts \\ []) do
    %{
      "provider_event_id" => event_id,
      "callback_app_id" => authority["app_id"],
      "workspace_id" => authority["workspace_id"],
      "channel_id" => authority["approved_channel_id"],
      "root_thread_ts" => Keyword.get(opts, :thread_ts, @root_thread_ts),
      "message_ts" => Keyword.get(opts, :message_ts, @root_thread_ts),
      "event_type" => "message",
      "actor_id" => Keyword.get(opts, :actor_id, "U_HUMAN"),
      "actor_kind" => Keyword.get(opts, :actor_kind, "human"),
      "text" => Keyword.get(opts, :text, "please review this update")
    }
  end

  @doc "Writes one durable typed receipt for the given authority."
  def receipt!(authority, event_id, opts \\ []) do
    assert {:ok, _kind, receipt} =
             LegacyCallbackReceipts.record_root(
               authority,
               verified_root(authority, event_id, opts),
               Keyword.take(opts, [:created_at])
             )

    receipt
  end

  @doc """
  Writes one durable typed receipt for a message inside an existing thread.

  Bucketing, debounce, and seal are per-thread by contract. A directed reply
  may be the first admitted receipt for a historical thread, so this helper
  deliberately does not require a root receipt to exist first.
  """
  def thread_receipt!(authority, event_id, message_ts, opts \\ []) do
    verified =
      authority
      |> verified_root(event_id, opts)
      |> Map.put("message_ts", message_ts)

    assert {:ok, _kind, receipt} =
             LegacyCallbackReceipts.record_reply(
               authority,
               verified,
               Keyword.take(opts, [:created_at])
             )

    receipt
  end

  @doc "Admits one durable typed receipt and asserts the exact admission status."
  def accept!(server, authority, receipt, expected \\ :accepted) do
    assert {:ok, ^expected} = Runtime.accept_current(server, authority, receipt)
    receipt
  end

  @doc "Writes one durable typed receipt and admits it in a single step."
  def admit!(server, authority, event_id, opts \\ []) do
    receipt = receipt!(authority, event_id, opts)
    accept!(server, authority, receipt, Keyword.get(opts, :expect, :accepted))
  end

  @doc "The generation-scoped bucket key one receipt belongs to."
  def scope_key(receipt), do: SalixIM.Triage.Bucketing.scope_key(receipt)

  @doc "Polls `fun` until it returns a non-empty value or the attempts run out."
  def eventually(fun, attempts \\ 100)
  def eventually(fun, 0), do: fun.()

  def eventually(fun, attempts) do
    case fun.() do
      [] ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      false ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      nil ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end
end
