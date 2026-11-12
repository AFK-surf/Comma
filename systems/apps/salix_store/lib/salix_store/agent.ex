defmodule SalixStore.Agent do
  @moduledoc """
  Agent configuration, root-state and ownership access.

  PostgreSQL is the online authority. Root revisions fence concurrent root
  writes; the Agent owner epoch fences Session commits. Head lease values are
  milliseconds at the API boundary and use the PostgreSQL clock for decisions.
  """

  alias SalixStore.{AgentPGStore, Codec, Head, Keys, S3, StateMachine}

  defmodule Owned do
    @moduledoc """
    In-memory commit handle for a claimed agent.

    `prev_owner_node` is transient claim provenance: the `owner_node` the head
    carried immediately before this claim landed (nil for a create or an
    unowned head). Runtime layers use it to nudge a superseded owner node;
    it never participates in fencing.
    """
    defstruct [
      :agent_id,
      :node_id,
      :sm,
      :root_revision,
      :epoch,
      :head,
      :state,
      :next_seq,
      :since_snapshot_bytes,
      :prev_owner_node,
      ttl_ms: 60_000
    ]
  end

  def create(agent_id, node_id, sm, opts \\ []) do
    with {:ok, config} <- complete_config(opts) do
      AgentPGStore.create(agent_id, node_id, sm, config, opts)
    end
  end

  def seed(agent_id, state, sm, opts \\ []) do
    with {:ok, config} <- complete_config(opts) do
      AgentPGStore.seed(agent_id, state, sm, config, opts)
    end
  end

  defdelegate discard_created(owned), to: AgentPGStore
  defdelegate read_state(agent_id, sm), to: AgentPGStore
  defdelegate peek(agent_id), to: AgentPGStore
  defdelegate verify_owner(owned), to: AgentPGStore
  defdelegate verify_work_owner(owned, opts \\ []), to: AgentPGStore
  defdelegate claim(agent_id, node_id, sm, opts \\ []), to: AgentPGStore
  defdelegate commit(owned, events, opts \\ []), to: AgentPGStore
  defdelegate settle(pending), to: AgentPGStore

  def renew(owned, _opts \\ []), do: AgentPGStore.renew(owned)

  def release(owned, _opts \\ []) do
    case AgentPGStore.release(owned) do
      {:error, :fenced} -> :ok
      result -> result
    end
  end

  def peek_in_scope(agent_id) do
    SalixStore.ReadScope.fetch({:head, agent_id}, fn -> peek(agent_id) end)
  end

  def lease_expired?(%Head{lease_until: nil}, _now), do: true
  def lease_expired?(%Head{lease_until: until}, now), do: until <= now

  def lease_expired?(%Head{} = head),
    do: lease_expired?(head, SystemsClock.system_time(:millisecond))

  defp complete_config(opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, %{} = config} -> {:ok, config}
      _ -> {:error, :missing_configuration}
    end
  end

  # The old split-state migration owns these offline source operations. No
  # online reader or writer calls them. G1 replaces the import workflow.
  @doc false
  def migration_read_root(agent_id) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(Keys.agent_state(agent_id)) do
      case Codec.decode_snapshot(body) do
        %{format: 2, sm: sm, head: %Head{} = head, payload: payload} ->
          {:ok, %{etag: etag, sm: sm, head: head, payload: payload}}

        other ->
          {:error, {:invalid_agent_state_root, other}}
      end
    end
  end

  @doc false
  def migration_write_whole_root(agent_id, etag, sm, %Head{} = head, state) do
    new_head = %Head{head | hot: StateMachine.hot(sm, state), spill: []}

    body =
      Codec.encode_snapshot(%{
        format: 2,
        sm: sm,
        head: new_head,
        payload: %{mode: :whole, state: state}
      })

    case S3.put(Keys.agent_state(agent_id), body, if_match: etag) do
      {:ok, %{etag: next}} -> {:ok, next}
      error -> error
    end
  end
end
