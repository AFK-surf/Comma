defmodule SalixStore.Agent do
  @moduledoc """
  The claim / commit / renew / release protocol for an agent.

  The live commit point is a single compressed root object at
  `SalixStore.Keys.agent_state/1`. Its ETag is the fencing token. Runtime
  session state is owned by runtime session stores, not by this root object.

  Modeled in tla/salix/HeadCommit.tla; protocol changes here must move that
  spec. (The historical absorb composition spec is archived with the staged
  protocol, A2 §3.4-§3.5.)
  """

  alias SalixStore.{Codec, Head, Keys, S3, StateMachine}

  @ttl_ms 60_000
  @claim_retries 5

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
      :etag,
      :epoch,
      :head,
      :state,
      :next_seq,
      :since_snapshot_bytes,
      :prev_owner_node,
      ttl_ms: 60_000
    ]
  end

  @spec create(String.t(), String.t(), module(), keyword()) ::
          {:ok, Owned.t()} | {:error, :exists} | {:error, term()}
  def create(agent_id, node_id, sm, opts \\ []) do
    result = do_create(agent_id, node_id, sm, opts)

    CommaLog.log("store_create", %{
      agent_id: agent_id,
      node_id: node_id,
      result: result_label(result)
    })

    result
  end

  @doc "Discard a newly-created, still-uncommitted agent root owned by this handle."
  @spec discard_created(Owned.t()) :: :ok | {:error, term()}
  def discard_created(%Owned{} = owned) do
    case S3.delete(Keys.agent_state(owned.agent_id), if_match: owned.etag) do
      :ok ->
        _ = S3.delete(Keys.lease(owned.node_id, owned.agent_id))
        :ok

      {:ok, _} ->
        _ = S3.delete(Keys.lease(owned.node_id, owned.agent_id))
        :ok

      {:error, :not_found} ->
        _ = S3.delete(Keys.lease(owned.node_id, owned.agent_id))
        :ok

      {:error, :precondition_failed} ->
        {:error, :fenced}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Seed an agent with an already-materialized state. This is used by migration
  imports so imported agents use the same split-object layout as live agents.
  """
  @spec seed(String.t(), term(), module(), keyword()) :: :ok | {:error, term()}
  def seed(agent_id, state, sm, opts \\ []) do
    hwm = Keyword.get(opts, :hwm, 0)

    head = %Head{
      epoch: Keyword.get(opts, :epoch, 0),
      owner_node: nil,
      lease_until: nil,
      commit_uuid: nil,
      journal_tail: %{epoch: 0, seq: Keyword.get(opts, :seq, 0)},
      snapshot_seq: Keyword.get(opts, :seq, 0),
      message_id_hwm: max(hwm, 0),
      format_version: 2,
      hot: StateMachine.hot(sm, state),
      spill: []
    }

    with {:ok, payload, _cache} <- persist_state(agent_id, state),
         {:ok, body} <- encode_root(head, sm, payload) do
      put_opts = if opts[:force], do: [], else: [if_none_match: "*"]

      case S3.put(Keys.agent_state(agent_id), body, put_opts) do
        {:ok, _} -> :ok
        {:error, :precondition_failed} -> {:error, :exists}
        other -> other
      end
    end
  end

  defp do_create(agent_id, node_id, sm, opts) do
    now = opts[:now] || now_ms()
    ttl = opts[:ttl_ms] || @ttl_ms
    state = sm.init(agent_id)

    head = %Head{
      epoch: 1,
      owner_node: node_id,
      lease_until: now + ttl,
      commit_uuid: uuid(),
      journal_tail: %{epoch: 1, seq: 0},
      snapshot_seq: 0,
      message_id_hwm: 0,
      format_version: 2,
      hot: StateMachine.hot(sm, state),
      spill: []
    }

    with {:ok, payload, _cache} <- persist_state(agent_id, state),
         {:ok, body} <- encode_root(head, sm, payload) do
      case S3.put(Keys.agent_state(agent_id), body, if_none_match: "*") do
        {:ok, %{etag: etag}} ->
          owned = %Owned{
            agent_id: agent_id,
            node_id: node_id,
            sm: sm,
            etag: etag,
            epoch: 1,
            head: head,
            state: state,
            next_seq: 1,
            since_snapshot_bytes: 0,
            ttl_ms: ttl
          }

          _ = put_lease_index(owned)
          {:ok, owned}

        {:error, :precondition_failed} ->
          {:error, :exists}

        {:error, {:ambiguous, _}} ->
          claim(agent_id, node_id, sm, opts)

        other ->
          other
      end
    end
  end

  @doc """
  `peek/1` served from the caller's `SalixStore.ReadScope` when one is
  active: one delivery observes the head once for placement and its owner
  fence, and a callback ahead of it can start the read with
  `SalixStore.ReadScope.prefetch/2` under `{:head, agent_id}`.
  """
  @spec peek_in_scope(String.t()) :: {:ok, Head.t()} | {:error, :not_found} | {:error, term()}
  def peek_in_scope(agent_id) do
    SalixStore.ReadScope.fetch({:head, agent_id}, fn -> peek(agent_id) end)
  end

  @spec peek(String.t()) :: {:ok, Head.t()} | {:error, :not_found} | {:error, term()}
  def peek(agent_id) do
    case read_root(agent_id) do
      {:ok, %{head: head}} -> {:ok, head}
      {:error, _} = err -> err
    end
  end

  @spec lease_expired?(Head.t(), integer()) :: boolean()
  def lease_expired?(%Head{} = head, now \\ System.system_time(:millisecond)) do
    lease_stale?(head, now)
  end

  @spec read_state(String.t(), module()) :: {:ok, term()} | {:error, term()}
  def read_state(agent_id, sm) do
    case read_root(agent_id) do
      {:ok, root} -> materialize_state(agent_id, sm, root.payload)
      {:error, _} = err -> err
    end
  end

  # ---- migration support (legacy split-runtime-state → whole) ----
  #
  # These two entrypoints exist solely for the one-shot
  # `SalixAgent.Migrations.SplitRuntimeState` data migration. They are NOT part
  # of the live claim/commit/read path: a live read of a legacy split root still
  # fails fast in `materialize_state/3`. They are kept here so the on-disk root
  # object format (head + payload envelope) has a single owner.

  @doc false
  @spec migration_read_root(String.t()) ::
          {:ok, %{etag: term(), sm: module(), head: Head.t(), payload: term()}}
          | {:error, term()}
  def migration_read_root(agent_id), do: read_root(agent_id)

  @doc false
  @spec migration_write_whole_root(String.t(), term(), module(), Head.t(), term()) ::
          {:ok, term()} | {:error, term()}
  def migration_write_whole_root(agent_id, etag, sm, %Head{} = head, state) do
    new_head = %Head{head | hot: StateMachine.hot(sm, state), spill: []}
    {:ok, body} = encode_root(new_head, sm, %{mode: :whole, state: state})

    case S3.put(Keys.agent_state(agent_id), body, if_match: etag) do
      {:ok, %{etag: new_etag}} -> {:ok, new_etag}
      other -> other
    end
  end

  @spec verify_owner(Owned.t()) :: :ok | {:error, :fenced} | {:error, term()}
  def verify_owner(%Owned{} = o) do
    case read_root(o.agent_id) do
      {:ok, root} ->
        if root.head.epoch == o.epoch and root.head.owner_node == o.node_id do
          :ok
        else
          {:error, :fenced}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Verifies both fencing ownership and that enough lease time remains to start
  one bounded unit of owner work.

  `guard_ms` must cover twice the deployment's maximum clock skew plus the
  maximum duration of that work unit. Callers must stop or passivate on
  `:lease_expiring`; an unchanged owner identity alone is not permission to
  start work near the steal boundary.
  """
  @spec verify_work_owner(Owned.t(), keyword()) ::
          :ok | {:error, :fenced | :lease_expiring} | {:error, term()}
  def verify_work_owner(%Owned{} = o, opts \\ []) do
    now = Keyword.get(opts, :now, now_ms())
    guard_ms = Keyword.get(opts, :guard_ms, 0)

    case read_root(o.agent_id) do
      {:ok, root} ->
        cond do
          root.head.epoch != o.epoch or root.head.owner_node != o.node_id ->
            {:error, :fenced}

          not is_integer(root.head.lease_until) or
              now + max(guard_ms, 0) >= root.head.lease_until ->
            {:error, :lease_expiring}

          true ->
            :ok
        end

      {:error, _} = err ->
        err
    end
  end

  @spec claim(String.t(), String.t(), module(), keyword()) ::
          {:ok, Owned.t()}
          | {:error, {:held_by, String.t() | nil, integer() | nil}}
          | {:error, :not_found}
          | {:error, term()}
  def claim(agent_id, node_id, sm, opts \\ []) do
    started = System.monotonic_time()
    result = do_claim(agent_id, node_id, sm, opts, @claim_retries)

    CommaLog.log("store_claim", %{
      agent_id: agent_id,
      node_id: node_id,
      steal: opts[:steal] == true,
      epoch:
        case result do
          {:ok, owned} -> owned.epoch
          _ -> nil
        end,
      result: result_label(result)
    })

    emit_runtime_operation("claim", result, started)

    result
  end

  defp do_claim(_agent_id, _node_id, _sm, _opts, 0), do: {:error, :claim_exhausted}

  defp do_claim(agent_id, node_id, sm, opts, retries) do
    now = opts[:now] || now_ms()
    ttl = opts[:ttl_ms] || @ttl_ms

    case read_root(agent_id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}

      {:ok, root} ->
        head = root.head

        if claimable?(head, node_id, now, opts[:steal] == true) do
          attempt_claim_cas(agent_id, node_id, sm, root, now, ttl, opts, retries)
        else
          {:error, {:held_by, head.owner_node, head.lease_until}}
        end
    end
  end

  defp claimable?(head, node_id, now, steal?) do
    steal? or is_nil(head.owner_node) or head.owner_node == node_id or lease_stale?(head, now)
  end

  defp lease_stale?(%Head{lease_until: nil}, _now), do: true
  defp lease_stale?(%Head{lease_until: until}, now), do: until <= now

  defp attempt_claim_cas(agent_id, node_id, sm, root, now, ttl, opts, retries) do
    my_uuid = uuid()
    %Head{} = head = root.head
    prev_owner = head.owner_node

    new_head = %Head{
      head
      | epoch: head.epoch + 1,
        owner_node: node_id,
        lease_until: now + ttl,
        commit_uuid: my_uuid
    }

    new_root = %{root | head: new_head}

    with {:ok, body} <- encode_existing_root(new_root) do
      case S3.put(Keys.agent_state(agent_id), body, if_match: root.etag) do
        {:ok, %{etag: new_etag}} ->
          finish_claim(agent_id, node_id, sm, %{new_root | etag: new_etag}, ttl, prev_owner, opts)

        {:error, :precondition_failed} ->
          do_claim(agent_id, node_id, sm, opts, retries - 1)

        {:error, {:ambiguous, _}} ->
          resolve_claim_ambiguity(
            agent_id,
            node_id,
            sm,
            my_uuid,
            root.head.epoch,
            ttl,
            opts,
            retries
          )

        other ->
          other
      end
    end
  end

  defp resolve_claim_ambiguity(agent_id, node_id, sm, my_uuid, prev_epoch, ttl, opts, retries) do
    case read_root(agent_id) do
      {:ok, root} ->
        cond do
          root.head.commit_uuid == my_uuid and root.head.owner_node == node_id ->
            finish_claim(agent_id, node_id, sm, root, ttl, nil, opts)

          root.head.epoch > prev_epoch ->
            do_claim(agent_id, node_id, sm, opts, retries - 1)

          true ->
            do_claim(agent_id, node_id, sm, opts, retries - 1)
        end

      other ->
        other
    end
  end

  # `opts[:on_claimed]` runs once the fenced head names this owner and before
  # the best-effort lease index write, so a caller can publish the claim
  # (its node-local ownership cell) one round trip earlier. The index write
  # was already unobserved by the claim's result.
  defp finish_claim(agent_id, node_id, sm, root, ttl, prev_owner_node, opts) do
    with {:ok, state} <- materialize_state(agent_id, sm, root.payload) do
      owned = %Owned{
        agent_id: agent_id,
        node_id: node_id,
        sm: sm,
        etag: root.etag,
        epoch: root.head.epoch,
        head: root.head,
        state: state,
        next_seq: root.head.journal_tail.seq + 1,
        since_snapshot_bytes: 0,
        prev_owner_node: prev_owner_node,
        ttl_ms: ttl
      }

      case opts[:on_claimed] do
        fun when is_function(fun, 1) -> fun.(owned)
        _ -> :ok
      end

      _ = put_lease_index(owned)
      {:ok, owned}
    end
  end

  @spec commit(Owned.t(), [map()], keyword()) ::
          {:ok, Owned.t()} | {:error, :fenced} | {:error, term()}
  def commit(%Owned{} = o, events, opts \\ []) when is_list(events) do
    started = System.monotonic_time(:millisecond)
    result = do_commit(o, events, opts)

    CommaLog.log("store_commit", %{
      agent_id: o.agent_id,
      epoch: o.epoch,
      seq: o.next_seq,
      event_count: length(events),
      event_types: Enum.map(events, &(&1["type"] || &1[:type])),
      hwm: opts[:hwm],
      duration_ms: System.monotonic_time(:millisecond) - started,
      result: result_label(result)
    })

    result
  end

  defp do_commit(%Owned{} = o, events, opts) do
    seq = o.next_seq
    canonical = events |> Codec.encode_segment() |> Codec.decode_segment()
    new_state = StateMachine.apply_events(o.sm, o.state, canonical)
    now = opts[:now] || now_ms()
    my_uuid = uuid()
    new_hwm = opts[:hwm] || o.head.message_id_hwm
    new_hot = opts[:hot] || StateMachine.hot(o.sm, new_state)
    %Head{} = head = o.head

    new_head = %Head{
      head
      | commit_uuid: my_uuid,
        journal_tail: %{epoch: o.epoch, seq: seq},
        snapshot_seq: seq,
        lease_until: now + o.ttl_ms,
        message_id_hwm: new_hwm,
        format_version: 2,
        hot: new_hot,
        spill: []
    }

    with {:ok, payload, cache} <- persist_state(o.agent_id, new_state),
         {:ok, body} <- encode_root(new_head, o.sm, payload) do
      cas_commit_root(o, body, new_head, my_uuid, new_state, seq, cache)
    end
  end

  defp cas_commit_root(%Owned{} = o, body, new_head, my_uuid, new_state, seq, cache) do
    case S3.put(Keys.agent_state(o.agent_id), body, if_match: o.etag) do
      {:ok, %{etag: new_etag}} ->
        {:ok,
         %Owned{
           o
           | etag: new_etag,
             head: new_head,
             state: new_state,
             next_seq: seq + 1,
             since_snapshot_bytes: 0
         }}

      {:error, :precondition_failed} ->
        resolve_commit_412(o, new_head, my_uuid, new_state, seq, cache)

      {:error, {:ambiguous, _}} ->
        resolve_commit_ambiguity(o, new_head, my_uuid, new_state, seq, cache)

      other ->
        other
    end
  end

  defp resolve_commit_412(%Owned{} = o, new_head, my_uuid, new_state, seq, cache) do
    case read_root(o.agent_id) do
      {:ok, root} ->
        cond do
          root.head.epoch > o.epoch or root.head.owner_node != o.node_id ->
            {:error, :fenced}

          root.head.commit_uuid == my_uuid ->
            adopt_commit(o, root.etag, new_head, new_state, seq, cache)

          true ->
            {:error, {:stale_etag, root.etag}}
        end

      other ->
        other
    end
  end

  defp resolve_commit_ambiguity(%Owned{} = o, new_head, my_uuid, new_state, seq, cache) do
    case read_root(o.agent_id) do
      {:ok, root} ->
        cond do
          root.head.commit_uuid == my_uuid and root.head.owner_node == o.node_id ->
            adopt_commit(o, root.etag, new_head, new_state, seq, cache)

          root.head.epoch > o.epoch or root.head.owner_node != o.node_id ->
            {:error, :fenced}

          true ->
            {:error, {:ambiguous_unresolved, root.etag}}
        end

      other ->
        other
    end
  end

  defp adopt_commit(%Owned{} = o, etag, new_head, new_state, seq, _cache) do
    {:ok,
     %Owned{
       o
       | etag: etag,
         head: new_head,
         state: new_state,
         next_seq: seq + 1,
         since_snapshot_bytes: 0
     }}
  end

  @spec renew(Owned.t(), keyword()) :: {:ok, Owned.t()} | {:error, :fenced} | {:error, term()}
  def renew(%Owned{} = o, opts \\ []) do
    started = System.monotonic_time()
    now = opts[:now] || now_ms()
    %Head{} = head = o.head
    new_head = %Head{head | lease_until: now + o.ttl_ms}
    result = put_root_head_from_memory(o, new_head)
    emit_runtime_operation("lease", result, started)
    result
  end

  # Renew is on the runtime keep-alive path (one call per owning agent per
  # ~ttl/3 while session work is live), so it must not read before writing:
  # the Owned handle already carries head, payload, and the fencing ETag, and
  # only the owner writes the root, so the in-memory copy is the durable copy.
  # The one GET happens only on the failure path, to distinguish a genuine
  # fence (stolen lease) from a stale local handle.
  defp put_root_head_from_memory(%Owned{} = o, %Head{} = new_head) do
    with {:ok, payload, _cache} <- persist_state(o.agent_id, o.state),
         {:ok, body} <- encode_root(new_head, o.sm, payload) do
      case S3.put(Keys.agent_state(o.agent_id), body, if_match: o.etag) do
        {:ok, %{etag: etag}} ->
          {:ok, %Owned{o | etag: etag, head: new_head}}

        {:error, :precondition_failed} ->
          case read_root(o.agent_id) do
            {:ok, live} ->
              if live.head.epoch > o.epoch or live.head.owner_node != o.node_id,
                do: {:error, :fenced},
                else: {:error, :stale_etag}

            other ->
              other
          end

        {:error, {:ambiguous, _}} ->
          # An ambiguous renew that actually APPLIED moved the ETag under our
          # own feet; without this resolve the retry would 412 on our own
          # write and abort a healthy runtime as :stale_etag. Matching
          # epoch+owner proves OWNERSHIP only — success additionally
          # requires the live head to prove the extension LANDED
          # (lease_until at or past what this renew wrote). An unextended
          # lease (ambiguous-before, write lost) is a retryable
          # :renew_unconfirmed: the handle's ETag still names the live
          # object, and the caller must NOT treat the lease as refreshed.
          case read_root(o.agent_id) do
            {:ok, live} ->
              cond do
                live.head.epoch != o.epoch or live.head.owner_node != o.node_id ->
                  {:error, :fenced}

                is_integer(live.head.lease_until) and
                    live.head.lease_until >= new_head.lease_until ->
                  {:ok, %Owned{o | etag: live.etag, head: live.head}}

                true ->
                  {:error, :renew_unconfirmed}
              end

            other ->
              other
          end

        other ->
          other
      end
    end
  end

  defp emit_runtime_operation(operation, result, started) do
    :telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: System.monotonic_time() - started},
      %{
        component: "salix_agent",
        operation: operation,
        surface: "system",
        outcome: if(match?({:ok, _}, result), do: "ok", else: "error")
      }
    )
  end

  @spec release(Owned.t(), keyword()) :: :ok | {:error, term()}
  def release(%Owned{} = o, _opts \\ []) do
    result = do_release(o)

    CommaLog.log("store_release", %{
      agent_id: o.agent_id,
      epoch: o.epoch,
      result: result_label(result)
    })

    result
  end

  defp do_release(%Owned{} = o) do
    %Head{} = head = o.head
    new_head = %Head{head | owner_node: nil, lease_until: nil}

    case update_root_head(o, new_head) do
      {:ok, _} ->
        _ = S3.delete(Keys.lease(o.node_id, o.agent_id))
        :ok

      {:error, :fenced} ->
        :ok

      other ->
        other
    end
  end

  defp update_root_head(%Owned{} = o, %Head{} = new_head) do
    with {:ok, root} <- read_root(o.agent_id),
         {:ok, body} <- encode_existing_root(%{root | head: new_head}) do
      case S3.put(Keys.agent_state(o.agent_id), body, if_match: o.etag) do
        {:ok, %{etag: etag}} ->
          {:ok, %Owned{o | etag: etag, head: new_head}}

        {:error, :precondition_failed} ->
          case read_root(o.agent_id) do
            {:ok, live} ->
              if live.head.epoch > o.epoch or live.head.owner_node != o.node_id,
                do: {:error, :fenced},
                else: {:error, :stale_etag}

            other ->
              other
          end

        other ->
          other
      end
    end
  end

  # ---- root encoding ----

  defp persist_state(_agent_id, state, cache \\ %{}),
    do: {:ok, %{mode: :whole, state: state}, cache}

  defp materialize_state(_agent_id, _sm, %{mode: :whole, state: state}), do: {:ok, state}

  defp materialize_state(agent_id, _sm, %{mode: :split} = payload),
    do: {:error, {:unsupported_agent_split_runtime_state, agent_id, payload}}

  defp encode_root(%Head{} = head, sm, payload) do
    {:ok,
     Codec.encode_snapshot(%{
       format: 2,
       sm: sm,
       head: head,
       payload: payload
     })}
  end

  defp encode_existing_root(root), do: encode_root(root.head, root.sm, root.payload)

  defp read_root(agent_id) do
    case S3.get(Keys.agent_state(agent_id)) do
      {:ok, %{body: body, etag: etag}} ->
        case Codec.decode_snapshot(body) do
          %{format: 2, sm: sm, head: %Head{} = head, payload: payload} ->
            {:ok, %{etag: etag, sm: sm, head: head, payload: payload}}

          other ->
            {:error, {:invalid_agent_state_root, other}}
        end

      {:error, :not_found} = err ->
        err

      other ->
        other
    end
  end

  defp result_label({:ok, _}), do: "ok"
  defp result_label(:ok), do: "ok"
  defp result_label({:error, reason}), do: "error: #{inspect(reason)}"
  defp result_label(other), do: inspect(other)

  defp put_lease_index(%Owned{} = o) do
    body = Jason.encode!(%{epoch: o.epoch, lease_until: o.head.lease_until, node: o.node_id})
    S3.put(Keys.lease(o.node_id, o.agent_id), body)
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp uuid do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
