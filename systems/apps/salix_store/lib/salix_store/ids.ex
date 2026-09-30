defmodule SalixStore.Ids do
  @moduledoc """
  Canonical Salix object ids.

  Public ids use `<type><version>_<body>`. Most bodies are one 19 digit decimal
  snowflake. Group and agent ids carry their canonical parent body before their
  own snowflake body.
  """

  use GenServer
  import Bitwise

  # Version 1 IDs already use this epoch. A different epoch requires a new ID
  # version so separately deployed writers never create overlapping bodies.
  @epoch_ms 1_288_834_974_657
  @sequence_bits 12
  @worker_bits 10
  @max_sequence (1 <<< @sequence_bits) - 1
  @max_worker_id (1 <<< @worker_bits) - 1
  @worker_shift @sequence_bits
  @timestamp_shift @sequence_bits + @worker_bits

  @prefixes %{
    tenant: "ten1",
    private_template: "ptm1",
    group: "grp1",
    agent: "agt1",
    session: "ses1",
    tool_result_ref: "trf1",
    schedule: "sch1",
    loop: "lop1",
    conversation: "cnv1",
    participant: "ptp1",
    message: "msg1",
    workflow_activation: "wfa1",
    connect: "imc1",
    capability_request: "cap1",
    calendar: "cal1",
    calendar_source: "csrc1",
    calendar_item: "cit1",
    calendar_feed: "cfd1",
    scheduling_link: "sln1",
    meeting_plan: "mpl1",
    calendar_change: "cchg1",
    device: "dev1",
    env: "env1",
    plugin: "plg1",
    mcp_definition: "mcp1",
    mcp_binding: "mpb1",
    task_label: "tlb1",
    task_label_proposal: "tlp1"
  }

  @snowflake_body_regex ~r/^[0-9]{19}$/
  @body_regexes %{
    tenant: @snowflake_body_regex,
    private_template: @snowflake_body_regex,
    group: ~r/^[0-9]{19}_[0-9]{19}$/,
    agent: ~r/^[0-9]{19}_[0-9]{19}_[0-9]{19}$/,
    session: @snowflake_body_regex,
    tool_result_ref: @snowflake_body_regex,
    schedule: @snowflake_body_regex,
    loop: @snowflake_body_regex,
    conversation: @snowflake_body_regex,
    participant: @snowflake_body_regex,
    message: @snowflake_body_regex,
    workflow_activation: @snowflake_body_regex,
    connect: @snowflake_body_regex,
    capability_request: @snowflake_body_regex,
    calendar: @snowflake_body_regex,
    calendar_source: @snowflake_body_regex,
    calendar_item: @snowflake_body_regex,
    calendar_feed: @snowflake_body_regex,
    scheduling_link: @snowflake_body_regex,
    meeting_plan: @snowflake_body_regex,
    calendar_change: @snowflake_body_regex,
    device: @snowflake_body_regex,
    env: @snowflake_body_regex,
    plugin: @snowflake_body_regex,
    mcp_definition: @snowflake_body_regex,
    mcp_binding: @snowflake_body_regex,
    task_label: @snowflake_body_regex,
    task_label_proposal: @snowflake_body_regex
  }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    {:ok, %{last_ms: -1, sequence: -1, worker_id: configured_worker_id(opts)}}
  end

  def new_private_template_id, do: new(:private_template)
  def valid_private_template_id?(id), do: valid?(:private_template, id)

  def new_tenant_id, do: new(:tenant)
  def new_group_id(tenant_id), do: new_with_parent(:group, :tenant, tenant_id)
  def new_agent_id(group_id), do: new_with_parent(:agent, :group, group_id)
  def new_session_id, do: new(:session)
  def new_tool_result_ref, do: new(:tool_result_ref)
  def new_schedule_id, do: new(:schedule)
  def new_loop_id, do: new(:loop)
  def new_conversation_id, do: new(:conversation)
  def new_participant_id, do: new(:participant)
  def new_message_id, do: new(:message)
  def new_workflow_activation_id, do: new(:workflow_activation)
  def new_connect_id, do: new(:connect)
  def new_capability_request_id, do: new(:capability_request)
  def new_task_label_id, do: new(:task_label)
  def new_task_label_proposal_id, do: new(:task_label_proposal)
  def new_calendar_id, do: new(:calendar)
  def new_calendar_source_id, do: new(:calendar_source)
  def new_calendar_item_id, do: new(:calendar_item)
  def new_calendar_feed_id, do: new(:calendar_feed)
  def new_scheduling_link_id, do: new(:scheduling_link)
  def new_meeting_plan_id, do: new(:meeting_plan)
  def new_calendar_change_id, do: new(:calendar_change)
  def new_device_id, do: new(:device)
  def new_env_id, do: new(:env)
  def new_plugin_id, do: new(:plugin)
  def new_mcp_definition_id, do: new(:mcp_definition)
  def new_mcp_binding_id, do: new(:mcp_binding)

  def valid_tenant_id?(id), do: valid?(:tenant, id)
  def valid_group_id?(id), do: valid?(:group, id)
  def valid_agent_id?(id), do: valid?(:agent, id)
  def valid_session_id?(id), do: valid?(:session, id)
  def valid_tool_result_ref?(id), do: valid?(:tool_result_ref, id)
  def valid_schedule_id?(id), do: valid?(:schedule, id)
  def valid_loop_id?(id), do: valid?(:loop, id)
  def valid_conversation_id?(id), do: valid?(:conversation, id)
  def valid_participant_id?(id), do: valid?(:participant, id)
  def valid_message_id?(id), do: valid?(:message, id)
  def valid_workflow_activation_id?(id), do: valid?(:workflow_activation, id)
  def valid_connect_id?(id), do: valid?(:connect, id)
  def valid_capability_request_id?(id), do: valid?(:capability_request, id)
  def valid_task_label_id?(id), do: valid?(:task_label, id)
  def valid_task_label_proposal_id?(id), do: valid?(:task_label_proposal, id)
  def valid_calendar_id?(id), do: valid?(:calendar, id)
  def valid_calendar_source_id?(id), do: valid?(:calendar_source, id)
  def valid_calendar_item_id?(id), do: valid?(:calendar_item, id)
  def valid_calendar_feed_id?(id), do: valid?(:calendar_feed, id)
  def valid_scheduling_link_id?(id), do: valid?(:scheduling_link, id)
  def valid_meeting_plan_id?(id), do: valid?(:meeting_plan, id)
  def valid_calendar_change_id?(id), do: valid?(:calendar_change, id)
  def valid_device_id?(id), do: valid?(:device, id)
  def valid_env_id?(id), do: valid?(:env, id)
  def valid_plugin_id?(id), do: valid?(:plugin, id)
  def valid_mcp_definition_id?(id), do: valid?(:mcp_definition, id)
  def valid_mcp_binding_id?(id), do: valid?(:mcp_binding, id)

  def valid_group_id_for_tenant?(group_id, tenant_id) do
    valid_group_id?(group_id) and valid_tenant_id?(tenant_id) and
      String.starts_with?(body!(:group, group_id), body!(:tenant, tenant_id) <> "_")
  end

  def valid_agent_id_for_group?(agent_id, group_id) do
    valid_agent_id?(agent_id) and valid_group_id?(group_id) and
      String.starts_with?(body!(:agent, agent_id), body!(:group, group_id) <> "_")
  end

  def group_id_prefix_for_tenant!(tenant_id),
    do: prefix!(:group) <> "_" <> body!(:tenant, tenant_id) <> "_"

  def agent_id_prefix_for_tenant!(tenant_id),
    do: prefix!(:agent) <> "_" <> body!(:tenant, tenant_id) <> "_"

  def agent_id_prefix_for_group!(group_id),
    do: prefix!(:agent) <> "_" <> body!(:group, group_id) <> "_"

  @doc "Canonical tenant id encoded in a group id."
  def tenant_id_from_group!(group_id) do
    [tenant_body, _group_body] = group_id |> then(&body!(:group, &1)) |> String.split("_")
    prefix!(:tenant) <> "_" <> tenant_body
  end

  @doc "Canonical group id encoded in an agent id."
  def group_id_from_agent!(agent_id) do
    [tenant_body, group_body, _agent_body] =
      agent_id |> then(&body!(:agent, &1)) |> String.split("_")

    prefix!(:group) <> "_" <> tenant_body <> "_" <> group_body
  end

  @doc "Canonical tenant id encoded in an agent id."
  def tenant_id_from_agent!(agent_id),
    do: agent_id |> group_id_from_agent!() |> tenant_id_from_group!()

  @doc "Validated numeric body of a canonical agent id."
  def agent_body!(agent_id), do: body!(:agent, agent_id)

  @doc "Restore a canonical agent id from its validated numeric body."
  def agent_id_from_body(body) when is_binary(body) do
    if Regex.match?(body_regex!(:agent), body) do
      {:ok, prefix!(:agent) <> "_" <> body}
    else
      {:error, :invalid_agent_id}
    end
  end

  def agent_id_from_body(_body), do: {:error, :invalid_agent_id}

  defp new(kind) when kind in [:group, :agent] do
    raise ArgumentError, "#{kind} id requires parent id"
  end

  defp new(kind), do: prefix!(kind) <> "_" <> next_body()

  defp new_with_parent(kind, parent_kind, parent_id) do
    prefix!(kind) <> "_" <> body!(parent_kind, parent_id) <> "_" <> next_body()
  end

  defp prefix!(kind) do
    Map.fetch!(@prefixes, kind)
  end

  defp valid?(kind, id) when is_binary(id) do
    prefix = prefix!(kind)

    case String.split(id, "_", parts: 2) do
      [^prefix, body] -> Regex.match?(body_regex!(kind), body)
      _ -> false
    end
  end

  defp valid?(_kind, _id), do: false

  defp body!(kind, id) when is_binary(id) do
    prefix = prefix!(kind)

    case String.split(id, "_", parts: 2) do
      [^prefix, body] ->
        if Regex.match?(body_regex!(kind), body) do
          body
        else
          raise ArgumentError, "invalid #{kind} id"
        end

      _ ->
        raise ArgumentError, "invalid #{kind} id"
    end
  end

  defp body_regex!(kind), do: Map.fetch!(@body_regexes, kind)

  defp next_body, do: GenServer.call(__MODULE__, :next_body)

  @impl true
  def handle_call(:next_body, _from, state) do
    {body, state} = next_snowflake_body(state)
    {:reply, body, state}
  end

  defp next_snowflake_body(state) do
    now = current_ms()
    last = state.last_ms

    {ms, sequence} =
      cond do
        now < last ->
          {last, state.sequence + 1}

        now == last ->
          {now, state.sequence + 1}

        true ->
          {now, 0}
      end

    if sequence > @max_sequence do
      wait_next_ms(ms)
      next_snowflake_body(%{state | last_ms: ms, sequence: 0})
    else
      id =
        (ms - @epoch_ms) <<< @timestamp_shift |||
          state.worker_id <<< @worker_shift |||
          sequence

      body =
        id
        |> Integer.to_string()
        |> String.pad_leading(19, "0")

      {body, %{state | last_ms: ms, sequence: sequence}}
    end
  end

  defp wait_next_ms(ms) do
    if current_ms() <= ms do
      Process.sleep(1)
      wait_next_ms(ms)
    else
      :ok
    end
  end

  defp current_ms, do: System.system_time(:millisecond)

  defp configured_worker_id(opts) do
    worker_id =
      opts[:worker_id]
      |> fallback(Application.get_env(:salix_store, :snowflake_worker_id))

    case worker_id do
      nil -> raise ArgumentError, "SALIX_SNOWFLAKE_WORKER_ID is required"
      "" -> raise ArgumentError, "SALIX_SNOWFLAKE_WORKER_ID is required"
      value -> normalize_worker_id!(value)
    end
  end

  defp fallback(nil, value), do: value
  defp fallback("", value), do: value
  defp fallback(value, _fallback), do: value

  defp normalize_worker_id!(value)
       when is_integer(value) and value >= 0 and value <= @max_worker_id,
       do: value

  defp normalize_worker_id!(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> normalize_worker_id!(int)
      _ -> raise ArgumentError, "invalid SALIX_SNOWFLAKE_WORKER_ID"
    end
  end

  defp normalize_worker_id!(_value) do
    raise ArgumentError,
          "snowflake worker id must be an integer or decimal string between 0 and #{@max_worker_id}"
  end
end
