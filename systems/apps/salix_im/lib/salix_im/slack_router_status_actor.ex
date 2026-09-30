defmodule SalixIM.SlackRouterStatusActor do
  @moduledoc """
  Source-scoped Slack status projection modeled by `tla/salix/SlackRouterStatusScope.tla`.
  Provider retry settlement is modeled separately by
  `tla/salix/SlackRouterStatusDelivery.tla`.
  """

  use GenServer

  require Logger

  alias SalixIM.Ports.SessionActivity
  alias SalixIM.Provider.Slack
  alias SalixIM.SlackConversationStatus
  alias SalixIM.SlackRouterStatusPlacement
  alias SalixIM.{GroupDirectory, ProviderConnects}
  alias SalixStore.{CasRecord, Keys}

  import SalixIM.Provider.Util, only: [int_or: 2, str: 1]

  @router_source "router_session"
  @conversation_source "conversation"
  @max_targets 5
  @default_refresh_ms 90_000
  @default_retry_ms 5_000

  @record_fields ~w(record_type tenant_id group_id connect_id agent_id session_id last_inbound_at targets created_at updated_at)
  @target_fields ~w(channel_id thread_ts last_message_ts last_source_message_id last_inbound_at source_kind source_agent_id source_session_id source_sessions conversation_id excluded_agent_id last_status last_status_at rejected_projection)

  defstruct connect_id: nil,
            record: %{},
            persisted?: false,
            tick_ref: nil,
            retry_at: 0,
            subscribed_sessions: MapSet.new()

  def child_spec(opts) do
    connect_id = Keyword.fetch!(opts, :connect_id)

    %{
      id: key(connect_id),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link(opts) do
    connect_id = Keyword.fetch!(opts, :connect_id)
    GenServer.start_link(__MODULE__, opts, name: via(connect_id))
  end

  def key(connect_id), do: {:slack_router_status, connect_id}

  def activate(pid, connect, message, router_agent_id, session_id) do
    GenServer.cast(
      pid,
      {:activate, router_activation(connect, message, router_agent_id, session_id)}
    )
  end

  def activate_conversation(
        pid,
        connect,
        message,
        owner_agent_id,
        conversation_id
      ) do
    GenServer.cast(
      pid,
      {:activate,
       conversation_activation(
         connect,
         message,
         owner_agent_id,
         conversation_id
       )}
    )
  end

  def provider_reply_sent(pid, channel_id, thread_ts),
    do: GenServer.cast(pid, {:provider_reply_sent, {str(channel_id), str(thread_ts)}})

  @impl true
  def init(opts) do
    connect_id = Keyword.fetch!(opts, :connect_id)
    owner_agent_id = opts |> Keyword.get(:owner_agent_id) |> str()

    case load_window(connect_id) do
      {:ok, record, persisted?} ->
        state = %__MODULE__{connect_id: connect_id, record: record, persisted?: persisted?}

        if persisted? and str(record["agent_id"]) != "" and
             (owner_agent_id == "" or owner_agent_id == str(record["agent_id"])) do
          {:ok, state, {:continue, :recover}}
        else
          {:ok, state}
        end

      {:error, reason} ->
        {:stop, {:window_read_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:recover, state) do
    state = sync_window(state)

    if local_owner?(state.record) do
      force = target_keys(state.record)
      {:noreply, state |> run_tick(force) |> schedule_tick()}
    else
      handoff(state)
      {:stop, :normal, state}
    end
  end

  @impl true
  def handle_cast({:provider_reply_sent, key}, state) do
    state = sync_window(state)

    cond do
      not valid_key?(key) ->
        {:noreply, state}

      local_owner?(state.record) and target_present?(state.record, key) ->
        selected = MapSet.new([key])
        {:noreply, state |> run_tick(MapSet.new(), selected, selected) |> schedule_tick()}

      local_owner?(state.record) ->
        {:noreply, state}

      true ->
        forward_provider_reply(state, key)
        {:stop, :normal, state}
    end
  end

  def handle_cast({:activate, attrs}, state) do
    state = sync_window(state)
    owner_agent_id = str(attrs["agent_id"])

    cond do
      not valid_activation?(attrs) ->
        Logger.warning("slack status activation ignored: missing window fields")
        {:noreply, state}

      not SlackRouterStatusPlacement.local_owner?(owner_agent_id) ->
        forward_activation(state, attrs)
        {:stop, :normal, state}

      stale_inbound?(state.record, attrs["target"]) ->
        {:noreply, state}

      true ->
        {:noreply, activate_window(state, attrs)}
    end
  end

  @impl true
  def handle_info({:tick, token}, %{tick_ref: {_timer_ref, token}} = state) do
    state = state |> Map.put(:tick_ref, nil) |> sync_window()

    if local_owner?(state.record) do
      {:noreply,
       state
       |> run_tick(MapSet.new(), tick_target_keys(state))
       |> schedule_tick()}
    else
      handoff(state)
      {:stop, :normal, state}
    end
  end

  def handle_info({:tick, _token}, state), do: {:noreply, state}

  def handle_info({:session_activity_updated, agent_id, session_id}, state) do
    session_ref = {str(agent_id), str(session_id)}
    state = sync_window(state)
    affected_targets = target_keys_for_session(state.record, session_ref)

    if MapSet.member?(state.subscribed_sessions, session_ref) and
         MapSet.size(affected_targets) > 0 do
      if local_owner?(state.record) do
        {:noreply,
         state
         |> run_tick(MapSet.new(), affected_targets)
         |> schedule_tick()}
      else
        handoff(state)
        {:stop, :normal, state}
      end
    else
      {:noreply, state}
    end
  end

  defp activate_window(state, attrs) do
    timestamp = now()
    incoming = Map.put(attrs["target"], "last_inbound_at", timestamp)
    {targets, evicted} = upsert_target(window_targets(state.record), incoming)

    record =
      state.record
      |> Map.merge(Map.drop(attrs, ["target"]))
      |> Map.put("record_type", "slack_router_status_window")
      |> Map.put("last_inbound_at", timestamp)
      |> Map.put("targets", targets)
      |> Map.put_new("created_at", timestamp)

    case persist(state, record) do
      {:ok, state} ->
        clear_evicted(state.record, evicted)

        force =
          if evicted == [],
            do: MapSet.new([target_key(incoming)]),
            else: target_keys(state.record)

        state |> run_tick(force) |> schedule_tick()

      {:error, state, reason} ->
        Logger.warning(
          "slack status activation not persisted connect=#{state.connect_id}: #{inspect(reason)}"
        )

        schedule_tick(state)
    end
  end

  defp run_tick(state, force_targets),
    do: run_tick(state, force_targets, :all, MapSet.new())

  defp run_tick(state, force_targets, selected_targets),
    do: run_tick(state, force_targets, selected_targets, MapSet.new())

  defp run_tick(state, force_targets, selected_targets, cleared_targets) do
    previous = state.record

    {projections, subscribed_sessions} =
      project_targets(previous, selected_targets, state.subscribed_sessions)

    record = Map.put(previous, "targets", Enum.map(projections, &elem(&1, 0)))

    state =
      state
      |> Map.put(:record, record)
      |> Map.put(:subscribed_sessions, subscribed_sessions)
      |> sync_subscriptions(record_source_sessions(record))
      |> write_targets(projections, force_targets, cleared_targets)

    if state.record == previous do
      state
    else
      case persist(state, state.record) do
        {:ok, state} -> state
        {:error, state, _reason} -> state
      end
    end
  end

  defp project_targets(record, selected_targets, subscribed_sessions) do
    record
    |> window_targets()
    |> Enum.map_reduce(subscribed_sessions, fn target, subscribed ->
      if target_selected?(target, selected_targets) do
        {projection, projected_sessions, subscribed} =
          project_target(record, target, subscribed)

        target = put_source_sessions(target, projected_sessions)
        {{target, projection}, subscribed}
      else
        {{target, :skip}, subscribed}
      end
    end)
  end

  defp project_target(record, target, subscribed_sessions) do
    case source_kind(target) do
      @conversation_source ->
        case SlackConversationStatus.project(
               record["group_id"],
               target["conversation_id"],
               target["excluded_agent_id"],
               subscribed_sessions
             ) do
          {:ok, status, session_refs, subscribed} -> {status, session_refs, subscribed}
          {:unknown, session_refs, subscribed} -> {:unknown, session_refs, subscribed}
        end

      @router_source ->
        router_status(record, target, subscribed_sessions)
    end
  end

  defp router_status(record, target, subscribed_sessions) do
    agent_id = str(target["source_agent_id"] || record["agent_id"])
    session_id = str(target["source_session_id"] || record["session_id"])
    session_ref = {agent_id, session_id}
    projected_sessions = session_refs([session_ref])

    case subscribe_session(session_ref, subscribed_sessions) do
      {:ok, subscribed} ->
        case SessionActivity.get(agent_id, session_id) do
          {:ok, activity} when is_map(activity) ->
            {visible_router_status(activity, target), projected_sessions, subscribed}

          _unavailable ->
            {:unknown, projected_sessions, subscribed}
        end

      {:error, _reason} ->
        {:unknown, projected_sessions, subscribed_sessions}
    end
  end

  defp subscribe_session(session_ref, subscribed_sessions) do
    if MapSet.member?(subscribed_sessions, session_ref) do
      {:ok, subscribed_sessions}
    else
      {agent_id, session_id} = session_ref

      case SessionActivity.subscribe(agent_id, session_id) do
        :ok -> {:ok, MapSet.put(subscribed_sessions, session_ref)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp visible_router_status(%{"state" => "stopped"}, _target), do: ""

  defp visible_router_status(%{"state" => state, "status" => status} = activity, target)
       when state in ["active", "error"] and is_binary(status) and status != "" do
    source_message_id = str(target["last_source_message_id"])

    if source_message_id != "" and
         source_message_id in List.wrap(activity["_active_source_message_ids"]),
       do: status,
       else: ""
  end

  defp visible_router_status(_activity, _target), do: :unknown

  defp write_targets(state, projections, force_targets, cleared_targets) do
    timestamp = now()

    {targets, retry_at} =
      Enum.map_reduce(projections, state.retry_at, fn
        {target, :skip}, retry_at ->
          {target, retry_at}

        {target, desired}, retry_at ->
          target =
            if MapSet.member?(cleared_targets, target_key(target)),
              do: abandon_assertion(target, timestamp),
              else: target

          {target, rejected?} = reconcile_rejected_projection(target, desired)

          last = str(target["last_status"])
          force? = MapSet.member?(force_targets, target_key(target))

          cond do
            rejected? ->
              {target, retry_at}

            retry_at > timestamp ->
              {target, retry_at}

            desired == :unknown and last != "" and
                (force? or
                   timestamp - int_or(target["last_status_at"], 0) >= refresh_ms()) ->
              write_target(state.record, target, "", timestamp)

            desired == :unknown ->
              {target, retry_at}

            desired == "" and last == "" ->
              {target, retry_at}

            not force? and desired == last and
                timestamp - int_or(target["last_status_at"], 0) < refresh_ms() ->
              {target, retry_at}

            true ->
              write_target(state.record, target, desired, timestamp)
          end
      end)

    %{state | record: Map.put(state.record, "targets", targets), retry_at: retry_at}
  end

  defp abandon_assertion(target, timestamp) do
    target
    |> Map.put("last_status", "")
    |> Map.put("last_status_at", timestamp)
  end

  defp write_target(record, target, status, timestamp) do
    case call_slack(record, target, status) do
      {:ok, _response} ->
        Logger.info(
          "slack status updated connect=#{record["connect_id"]} channel=#{target["channel_id"]} thread=#{target["thread_ts"]} status=#{inspect(status)}"
        )

        {target
         |> Map.put("last_status", status)
         |> Map.put("last_status_at", timestamp)
         |> Map.delete("rejected_projection"), 0}

      {:error, error} ->
        Logger.warning(
          "slack status update failed connect=#{record["connect_id"]} channel=#{target["channel_id"]} thread=#{target["thread_ts"]} operation=#{if(status == "", do: "clear", else: "set")} status_chars=#{String.length(status)} status_bytes=#{byte_size(status)} validation=#{inspect(if(is_map(error), do: Map.get(error, :validation, []), else: []))}: #{error_message(error)}"
        )

        if permanent_status_rejection?(error) do
          # FORMAL-SPEC: tla/salix/SlackRouterStatusDelivery.tla PermanentReject.
          # Slack rejected this exact projection target. Retrying the same
          # immutable arguments cannot converge and creates an unbounded loop.
          {Map.put(target, "rejected_projection", %{"status" => status}), 0}
        else
          # FORMAL-SPEC: tla/salix/SlackRouterStatusDelivery.tla TransientReject.
          {target, timestamp + retry_delay(error)}
        end
    end
  end

  defp call_slack(record, target, status) do
    with true <- local_owner?(record),
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(
             record["group_id"],
             record["connect_id"],
             "slack"
           ) do
      Slack.set_assistant_thread_status(
        connect["tenant_id"],
        connect,
        target["channel_id"],
        target["thread_ts"],
        status
      )
    else
      false -> {:error, "status writer lost ownership"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_evicted(_record, []), do: :ok

  defp clear_evicted(record, targets) do
    Enum.each(targets, fn target ->
      if str(target["last_status"]) != "" do
        case call_slack(record, target, "") do
          {:ok, _response} ->
            :ok

          {:error, error} ->
            Logger.warning("slack evicted status clear failed: #{error_message(error)}")
        end
      end
    end)
  end

  defp sync_subscriptions(state, desired) do
    desired = MapSet.new(desired)
    removed = MapSet.difference(state.subscribed_sessions, desired)

    Enum.each(removed, fn {agent_id, session_id} ->
      SessionActivity.unsubscribe(agent_id, session_id)
    end)

    %{state | subscribed_sessions: MapSet.intersection(state.subscribed_sessions, desired)}
  end

  defp schedule_tick(state) do
    case next_tick_delay(state) do
      nil ->
        cancel_tick(state)

      delay ->
        token = make_ref()
        state = cancel_tick(state)
        %{state | tick_ref: {Process.send_after(self(), {:tick, token}, delay), token}}
    end
  end

  defp next_tick_delay(state) do
    timestamp = now()
    active_targets = Enum.filter(window_targets(state.record), &refreshable_assertion?/1)

    cond do
      state.retry_at > timestamp ->
        max(state.retry_at - timestamp, 1)

      active_targets == [] ->
        nil

      true ->
        active_targets
        |> Enum.map(&target_reconcile_at/1)
        |> Enum.min()
        |> then(&max(&1 - timestamp, 1))
    end
  end

  defp target_reconcile_at(target) do
    int_or(target["last_status_at"], 0) + refresh_ms()
  end

  defp cancel_tick(%{tick_ref: nil} = state), do: state

  defp cancel_tick(state) do
    {timer_ref, _token} = state.tick_ref
    Process.cancel_timer(timer_ref)
    %{state | tick_ref: nil}
  end

  defp router_activation(connect, message, router_agent_id, session_id) do
    %{
      "tenant_id" => str(connect["tenant_id"]),
      "group_id" => str(connect["group_id"]),
      "connect_id" => str(connect["connect_id"]),
      "agent_id" => str(router_agent_id),
      "session_id" => str(session_id),
      "target" =>
        target_from_message(message)
        |> Map.merge(%{
          "source_kind" => @router_source,
          "source_agent_id" => str(router_agent_id),
          "source_session_id" => str(session_id)
        })
    }
  end

  defp conversation_activation(
         connect,
         message,
         owner_agent_id,
         conversation_id
       ) do
    group_id = str(connect["group_id"])

    %{
      "tenant_id" => str(connect["tenant_id"]),
      "group_id" => group_id,
      "connect_id" => str(connect["connect_id"]),
      "agent_id" => str(owner_agent_id),
      "session_id" => "",
      "target" =>
        target_from_message(message)
        |> Map.merge(%{
          "source_kind" => @conversation_source,
          "conversation_id" => str(conversation_id),
          "excluded_agent_id" => group_router_agent_id(group_id)
        })
    }
  end

  defp target_from_message(message) do
    %{
      "channel_id" => message_value(message, :channel_id, "channel_id"),
      "thread_ts" => message_value(message, :thread_ts, "thread_ts"),
      "last_message_ts" => message_value(message, :message_ts, "message_ts"),
      "last_source_message_id" => message_value(message, :source_message_id, "source_message_id")
    }
  end

  defp group_router_agent_id(group_id) do
    case GroupDirectory.get_group(group_id) do
      {:ok, group} -> str(group["router_agent_id"])
      {:error, _reason} -> ""
    end
  end

  defp message_value(message, atom_key, string_key) when is_map(message),
    do: str(Map.get(message, atom_key) || Map.get(message, string_key))

  defp message_value(_message, _atom_key, _string_key), do: ""

  defp valid_activation?(attrs) do
    target = attrs["target"] || %{}

    Enum.all?(~w(tenant_id group_id connect_id agent_id), &(str(attrs[&1]) != "")) and
      Enum.all?(~w(channel_id thread_ts last_message_ts), &(str(target[&1]) != "")) and
      case source_kind(target) do
        @conversation_source -> str(target["conversation_id"]) != ""
        @router_source -> str(target["source_session_id"] || attrs["session_id"]) != ""
      end
  end

  defp stale_inbound?(record, incoming) do
    case Enum.find(window_targets(record), &(target_key(&1) == target_key(incoming))) do
      nil ->
        false

      current ->
        source_id = str(incoming["last_source_message_id"])

        (source_id != "" and source_id == str(current["last_source_message_id"])) or
          str(incoming["last_message_ts"]) <= str(current["last_message_ts"])
    end
  end

  defp upsert_target(targets, incoming) do
    key = target_key(incoming)

    target =
      case Enum.find(targets, &(target_key(&1) == key)) do
        nil ->
          normalize_target(incoming)

        current ->
          current
          |> Map.merge(incoming)
          |> normalize_target()
      end

    [target | Enum.reject(targets, &(target_key(&1) == key))]
    |> Enum.sort_by(&{str(&1["last_message_ts"]), int_or(&1["last_inbound_at"], 0)}, :desc)
    |> Enum.split(@max_targets)
  end

  defp target_key(target), do: {str(target["channel_id"]), str(target["thread_ts"])}
  defp valid_key?({channel_id, thread_ts}), do: channel_id != "" and thread_ts != ""

  defp target_selected?(_target, :all), do: true

  defp target_selected?(target, %MapSet{} = selected),
    do: MapSet.member?(selected, target_key(target))

  defp target_keys_for_session(record, session_ref) do
    record
    |> window_targets()
    |> Enum.filter(&MapSet.member?(target_source_sessions(&1), session_ref))
    |> MapSet.new(&target_key/1)
  end

  defp put_source_sessions(target, :preserve), do: target

  defp put_source_sessions(target, session_refs) do
    Map.put(
      target,
      "source_sessions",
      session_refs
      |> MapSet.new()
      |> Enum.sort()
      |> Enum.map(fn {agent_id, session_id} ->
        %{"agent_id" => agent_id, "session_id" => session_id}
      end)
    )
  end

  defp target_source_sessions(target) do
    target["source_sessions"]
    |> List.wrap()
    |> Enum.map(fn
      %{"agent_id" => agent_id, "session_id" => session_id} ->
        {str(agent_id), str(session_id)}

      _other ->
        {"", ""}
    end)
    |> MapSet.new()
    |> MapSet.delete({"", ""})
  end

  defp record_source_sessions(record) do
    record
    |> window_targets()
    |> Enum.reduce(MapSet.new(), &MapSet.union(target_source_sessions(&1), &2))
  end

  defp session_refs(refs) do
    refs
    |> Enum.filter(fn {agent_id, session_id} -> agent_id != "" and session_id != "" end)
    |> MapSet.new()
  end

  defp target_present?(record, key),
    do: Enum.any?(window_targets(record), &(target_key(&1) == key))

  defp active_target_keys(record) do
    record
    |> window_targets()
    |> Enum.filter(&refreshable_assertion?/1)
    |> MapSet.new(&target_key/1)
  end

  defp tick_target_keys(%{retry_at: retry_at, record: record}) when retry_at > 0,
    do: target_keys(record)

  defp tick_target_keys(%{record: record}), do: active_target_keys(record)

  defp target_keys(record), do: record |> window_targets() |> MapSet.new(&target_key/1)
  defp window_targets(record), do: record["targets"] |> List.wrap() |> Enum.filter(&is_map/1)

  defp source_kind(target) do
    if str(target["source_kind"]) == @conversation_source or
         str(target["conversation_id"]) != "",
       do: @conversation_source,
       else: @router_source
  end

  defp normalize_target(target) do
    last_status = str(target["last_status"])
    last_status_at = int_or(target["last_status_at"], 0)

    target
    |> Map.take(@target_fields)
    |> Map.merge(%{
      "channel_id" => str(target["channel_id"]),
      "thread_ts" => str(target["thread_ts"]),
      "last_message_ts" => str(target["last_message_ts"]),
      "last_source_message_id" => str(target["last_source_message_id"]),
      "last_inbound_at" => int_or(target["last_inbound_at"], 0),
      "source_kind" => source_kind(target),
      "source_sessions" =>
        target_source_sessions(target)
        |> Enum.sort()
        |> Enum.map(fn {agent_id, session_id} ->
          %{"agent_id" => agent_id, "session_id" => session_id}
        end),
      "last_status" => last_status,
      "last_status_at" => last_status_at
    })
    |> normalize_rejected_projection(target["rejected_projection"])
  end

  defp reconcile_rejected_projection(target, desired) when is_binary(desired) do
    case target["rejected_projection"] do
      %{"status" => ^desired} -> {target, true}
      %{"status" => _previous} -> {Map.delete(target, "rejected_projection"), false}
      _none -> {target, false}
    end
  end

  defp reconcile_rejected_projection(target, _desired), do: {target, false}

  defp refreshable_assertion?(target) do
    str(target["last_status"]) != "" and not is_map(target["rejected_projection"])
  end

  defp normalize_rejected_projection(target, %{"status" => status}) when is_binary(status),
    do: Map.put(target, "rejected_projection", %{"status" => status})

  defp normalize_rejected_projection(target, _invalid),
    do: Map.delete(target, "rejected_projection")

  defp normalize_record(record, connect_id) do
    targets =
      record
      |> window_targets()
      |> Enum.map(&normalize_target/1)
      |> Enum.filter(&valid_key?(target_key(&1)))
      |> Enum.sort_by(&{str(&1["last_message_ts"]), int_or(&1["last_inbound_at"], 0)}, :desc)
      |> Enum.uniq_by(&target_key/1)
      |> Enum.take(@max_targets)

    record
    |> Map.take(@record_fields)
    |> Map.merge(%{
      "record_type" => "slack_router_status_window",
      "tenant_id" => str(record["tenant_id"]),
      "group_id" => str(record["group_id"]),
      "connect_id" => str(record["connect_id"] || connect_id),
      "agent_id" => str(record["agent_id"]),
      "session_id" => str(record["session_id"]),
      "last_inbound_at" => int_or(record["last_inbound_at"], 0),
      "targets" => targets,
      "created_at" => int_or(record["created_at"], now()),
      "updated_at" => int_or(record["updated_at"], now())
    })
  end

  defp load_window(connect_id) do
    case CasRecord.get(window_key(connect_id)) do
      {:ok, record} -> {:ok, normalize_record(record, connect_id), true}
      {:error, :not_found} -> {:ok, new_record(connect_id), false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_window(state) do
    case CasRecord.get(window_key(state.connect_id)) do
      {:ok, record} ->
        %{state | record: normalize_record(record, state.connect_id), persisted?: true}

      {:error, _reason} ->
        state
    end
  end

  defp persist(state, record) do
    record = record |> normalize_record(state.connect_id) |> Map.put("updated_at", now())

    case CasRecord.update(window_key(state.connect_id), fn _current -> record end) do
      {:ok, saved} ->
        {:ok, %{state | record: saved, persisted?: true}}

      {:error, reason} ->
        {:error, %{state | record: record}, reason}
    end
  end

  defp local_owner?(record) do
    owner_agent_id = str(record["agent_id"])
    owner_agent_id != "" and SlackRouterStatusPlacement.local_owner?(owner_agent_id)
  end

  defp forward_activation(state, attrs) do
    case SlackRouterStatusPlacement.ensure_started(attrs["agent_id"], state.connect_id) do
      {:ok, pid} -> GenServer.cast(pid, {:activate, attrs})
      {:error, reason} -> Logger.warning("slack status owner unavailable: #{inspect(reason)}")
    end
  end

  defp forward_provider_reply(state, {channel_id, thread_ts}) do
    case SlackRouterStatusPlacement.ensure_started(state.record["agent_id"], state.connect_id) do
      {:ok, pid} -> provider_reply_sent(pid, channel_id, thread_ts)
      {:error, reason} -> Logger.warning("slack status owner unavailable: #{inspect(reason)}")
    end
  end

  defp handoff(state) do
    owner_agent_id = str(state.record["agent_id"])

    if owner_agent_id != "" do
      case SlackRouterStatusPlacement.ensure_started(owner_agent_id, state.connect_id) do
        {:ok, _pid} -> :ok
        {:error, reason} -> Logger.warning("slack status handoff failed: #{inspect(reason)}")
      end
    end
  end

  defp retry_delay(%{retry_after_ms: value}) when is_integer(value) and value > 0, do: value
  defp retry_delay(%{"retry_after_ms" => value}) when is_integer(value) and value > 0, do: value
  defp retry_delay(_error), do: @default_retry_ms

  defp permanent_status_rejection?(%{code: "invalid_arguments"}), do: true
  defp permanent_status_rejection?(%{"code" => "invalid_arguments"}), do: true
  defp permanent_status_rejection?(_error), do: false

  defp error_message(%{message: message}), do: str(message)
  defp error_message(%{"message" => message}), do: str(message)
  defp error_message(error), do: inspect(error)

  defp new_record(connect_id) do
    normalize_record(%{"connect_id" => connect_id, "targets" => []}, connect_id)
  end

  defp window_key(connect_id), do: Keys.ctl_im_slack_router_status_window(connect_id)

  defp via(connect_id),
    do: {:via, Registry, {SalixIM.SlackRouterStatusRegistry, key(connect_id)}}

  defp refresh_ms, do: config_ms(:slack_router_status_refresh_ms, @default_refresh_ms)

  defp config_ms(key, default) do
    case Application.get_env(:salix_im, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp now, do: System.system_time(:millisecond)
end
