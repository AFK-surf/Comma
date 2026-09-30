defmodule SalixIM.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The scan-permit table is owned by THIS process — the
    # application-start callback process, which has application
    # lifetime (linked into the application master pair, hosting no
    # supervised work): occupancy can only vanish with the application
    # itself, never with any crashable worker (round-11 shape).
    SalixIM.ProviderIdentityScanLimiter.create_table!()
    SalixIM.IFC.AudiencePlacement.create_table!()
    SalixIM.Triage.SourceSpeakerLabels.create_table!()
    # Same ownership shape: the Triage admission-config table lets ingress read
    # a Runtime's static mode/namespace without a call into its mailbox.
    SalixIM.Triage.Runtime.create_table!()
    Supervisor.start_link(children(), strategy: :one_for_one, name: SalixIM.Supervisor)
  end

  defp children do
    [
      SalixIM.ProviderIdentityScanLimiter,
      SalixIM.SlackUserProfileCache,
      SalixIM.Provider.Feishu.API,
      # Inbound control commands run off the provider callback process: a
      # compaction can outlast the webhook ACK budget several times over.
      # Bounded, because a `compact` task waits through the dependency budget
      # and result settlement allowance: unbounded, a spammed chat would pile up parked
      # processes and staged control deliveries with no back-pressure. Over
      # the cap `start_child` returns `{:error, :max_children}`, which
      # `SalixIM.ControlCommand` turns into a reply to the sender.
      {Task.Supervisor,
       name: SalixIM.ControlCommandTaskSupervisor,
       max_children: control_command_max_children(:control_command_max_children, 32)},
      # That reply needs its own pool: it is one bounded API call that never
      # parks, so it must not queue behind the long-running work it is
      # apologising for, and it must not run on the webhook process.
      {Task.Supervisor,
       name: SalixIM.ControlCommandReplySupervisor,
       max_children: control_command_max_children(:control_command_reply_max_children, 64)},
      # Search hot admission is correctness-independent and must not share the
      # Conversation owner restart domain. A stalled projection database can
      # fill only this bounded pool; it cannot block or restart owners.
      SalixIM.ConversationSearchEnqueuer,
      {Task.Supervisor, name: SalixIM.ConversationNotificationTasks, max_children: 64},
      {Task.Supervisor, name: SalixIM.ConversationProjectionTasks, max_children: 64},
      conversation_owner_supervisor()
    ] ++
      conversation_recovery_children() ++
      private_chat_status_children() ++
      slack_router_status_children() ++
      slack_triage_clickhouse_patrol_children() ++
      conversation_search_children() ++
      provider_runtime_children() ++
      slack_message_mirror_children()
  end

  defp conversation_recovery_children do
    if Application.get_env(:salix_im, :conversation_log_recovery, true) do
      [SalixIM.ConversationLogRecovery]
    else
      []
    end
  end

  defp slack_triage_clickhouse_patrol_children do
    case {
      Application.get_env(:salix_im, :slack_triage_clickhouse_reader_mod),
      Application.get_env(:salix_im, :slack_triage_clickhouse_patrol, false)
    } do
      {reader, opts} when is_atom(reader) and is_list(opts) ->
        [{SalixIM.Triage.ClickHousePatrolWorker, Keyword.put_new(opts, :reader, reader)}]

      _disabled ->
        []
    end
  end

  # Tunable like every other bounded pool in the umbrella: the docs promise
  # back-pressure at this cap, and an operator must be able to move it without
  # a deploy.
  @doc false
  def control_command_max_children(key, default) do
    case Application.get_env(:salix_im, key, default) do
      n when is_integer(n) and n > 0 -> n
      :infinity -> :infinity
      _ -> default
    end
  end

  defp conversation_owner_supervisor do
    %{
      id: SalixIM.ConversationOwnerSupervisor,
      start:
        {Supervisor, :start_link,
         [
           conversation_owner_children(),
           [strategy: :rest_for_one, name: SalixIM.ConversationOwnerSupervisor]
         ]}
    }
  end

  defp conversation_owner_children do
    [
      {Registry,
       keys: :unique, name: SalixIM.ConversationRegistry, partitions: System.schedulers_online()},
      {DynamicSupervisor, name: SalixIM.ConversationFleetSup, strategy: :one_for_one}
    ]
  end

  defp slack_router_status_children do
    case Application.get_env(:salix_im, :slack_router_status, true) do
      false -> []
      _ -> [slack_router_status_supervisor()]
    end
  end

  defp private_chat_status_children do
    if Application.get_env(:salix_im, :private_chat_status, true) do
      children = [
        {Registry, keys: :unique, name: SalixIM.PrivateChatStatusRegistry},
        {DynamicSupervisor,
         name: SalixIM.PrivateChatStatusFleetSup, strategy: :one_for_one, max_children: 1_024},
        {Task.Supervisor, name: SalixIM.PrivateChatStatusTaskSupervisor, max_children: 64}
      ]

      [
        %{
          id: SalixIM.PrivateChatStatusSupervisor,
          start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]}
        }
      ]
    else
      []
    end
  end

  defp conversation_search_children do
    enabled? = Application.get_env(:salix_im, :conversation_search_worker, true) != false
    repo? = Application.get_env(:salix_store, :start_repo, false)

    if enabled? and repo?,
      do: [SalixIM.ConversationSearchWorker, SalixIM.ConversationSearchDiscovery],
      else: []
  end

  defp slack_router_status_supervisor do
    children = [
      {Registry,
       keys: :unique,
       name: SalixIM.SlackRouterStatusRegistry,
       partitions: System.schedulers_online()},
      {DynamicSupervisor, name: SalixIM.SlackRouterStatusFleetSup, strategy: :one_for_one},
      {Task.Supervisor, name: SalixIM.SlackRouterStatusTaskSupervisor}
    ]

    %{
      id: SalixIM.SlackRouterStatusSupervisor,
      start:
        {Supervisor, :start_link,
         [children, [strategy: :rest_for_one, name: SalixIM.SlackRouterStatusSupervisor]]}
    }
  end

  defp provider_runtime_children do
    case Application.get_env(:salix_im, :provider_runtime, true) do
      false -> []
      opts when is_list(opts) -> [{SalixIM.ProviderRuntime, opts}]
      _ -> [SalixIM.ProviderRuntime]
    end
  end

  # The two Slack mirror writers run wherever the mirror has a store to write
  # to, one of each per Pod. Neither holds correctness: the outbox and the
  # backfill ledger in PostgreSQL decide what is written and by whom, so a
  # second Pod is more throughput and not a conflict. Each drains or walks in
  # a Task under its own supervisor so a raising write reschedules rather
  # than restarting the scheduler.
  defp slack_message_mirror_children do
    workers? = Application.get_env(:salix_im, :slack_message_mirror_workers, true) != false

    if workers? and SalixIM.SlackMessageMirror.enabled?() do
      [
        {Task.Supervisor, name: SalixIM.SlackMessageMirror.OutboxDrainer.task_supervisor_name()},
        SalixIM.SlackMessageMirror.OutboxDrainer,
        {Task.Supervisor, name: SalixIM.SlackMessageMirror.BackfillRunner.task_supervisor_name()},
        SalixIM.SlackMessageMirror.BackfillRunner
      ]
    else
      []
    end
  end
end
