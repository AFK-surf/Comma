defmodule SalixAgent.Loops do
  @moduledoc """
  Background Loops: durable, Agent-owned eBPF programs that spinfoam runs on
  the node holding the Agent's lease (docs/salix/tasks-background-execution.md,
  "Background loops").

  This module owns the domain rules over `SalixStore.Loops` rows:

    * quotas (`max_active_per_agent/0`, `max_active_per_group/0`);
    * the closed capability allowlist every Loop may call (`SalixAgent.Loops.Capabilities`);
    * the incarnation fence: every load bumps `incarnation`, and a host call
      whose object does not carry the current incarnation is refused;
    * the notification budget (`admit_notification/2`), a fixed window per
      Loop that turns a chatty Loop into `paused(budget)` instead of a
      round storm;
    * the restart budget (`record_failure/3`), which reloads a faulted Loop
      from its checkpoint a bounded number of times before marking it
      `failed`;
    * archive pause and unarchive resume, mirroring Schedules.

  Programs come from exactly one place: spinfoam's embedded compiler
  (`build/4`). There are no packaged templates. The compiled ELF is stored
  once, as a file in the Agent's workspace (VFS); the durable Loop row
  records only that path and the file's SHA-256, and every load reads the
  file back and verifies the hash (`artifact/1`).

  Placement, loading and unloading are `SalixAgent.Loops.Reconciler`'s;
  the spinfoam process is `SalixAgent.Loops.Host`'s. This module never
  talks to the child process directly except through those two.
  """

  alias SalixAgent.Control
  alias SalixAgent.{AgentWorkspace, FileBackend, StorageAuthorization}
  alias SalixAgent.Loops.{Capabilities, Host, Reconciler}
  alias SalixAgent.Spinfoam.Build
  alias SalixStore.Ids
  alias SalixStore.Loops, as: Store

  @default_max_active_per_agent 20
  @default_max_active_per_group 100
  @max_config_bytes 16 * 1024
  @max_checkpoint_bytes 16 * 1024
  @max_name_chars 80
  @max_elf_bytes 64 * 1024

  # Notification budget: a fixed window of `@notify_window_ms` admits at most
  # `@notify_window_limit` wakes; a Loop that keeps hitting the limit for
  # `@notify_limited_pause_ms` is paused with reason `budget`.
  @notify_window_ms :timer.minutes(10)
  @notify_window_limit 6
  @notify_limited_pause_ms :timer.hours(1)

  # Restart budget: at most `@restart_limit` automatic reloads per
  # `@restart_window_ms` after a guest fault, then `failed`.
  @restart_window_ms :timer.hours(1)
  @restart_limit 3

  @type ctx :: %{required(:agent_id) => String.t(), optional(atom()) => term()}

  # ---- limits ---------------------------------------------------------------

  def max_active_per_agent,
    do:
      Application.get_env(
        :salix_agent,
        :loops_max_active_per_agent,
        @default_max_active_per_agent
      )

  def max_active_per_group,
    do:
      Application.get_env(
        :salix_agent,
        :loops_max_active_per_group,
        @default_max_active_per_group
      )

  def max_config_bytes, do: @max_config_bytes
  def max_checkpoint_bytes, do: @max_checkpoint_bytes
  def notify_window_limit, do: @notify_window_limit
  def notify_window_ms, do: @notify_window_ms
  def restart_limit, do: @restart_limit

  # ---- build ----------------------------------------------------------------

  @doc """
  Compile agent-authored C through spinfoam's embedded compiler on this
  node and stage the resulting ELF as the workspace file `path`.

  Returns the terminal build report and, on success, the `vfs_write` event
  that lands the file: the caller's round commits it like any other file
  write, with the round's own audience label. The compile itself is
  `SalixAgent.Spinfoam.Build`, shared with `script.run`; there is no other
  compile path.
  """
  @spec build(ctx(), %{String.t() => String.t()}, String.t(), String.t()) ::
          {:ok, map(), map() | nil} | {:error, term()}
  def build(ctx, files, entry, path)
      when is_map(ctx) and is_map(files) and is_binary(entry) and is_binary(path) do
    with :ok <- valid_artifact_path(path) do
      case Build.compile(files, entry) do
        {:ok, report} -> finish_build(ctx, report, path)
        {:error, {:build_failed, failure}} -> failed_build(failure)
        {:error, _} = error -> error
      end
    end
  end

  defp finish_build(ctx, %{elf: elf} = report, path) do
    with {:ok, event} <-
           FileBackend.prepare_write(StorageAuthorization.replacing_content(ctx), path, elf) do
      emit("loop_build", "ok")

      {:ok,
       %{
         "state" => "succeeded",
         "path" => path,
         "artifact_sha256" => sha256_hex(elf),
         "elf_bytes" => byte_size(elf),
         "diagnostics" => report.diagnostics,
         "diagnostics_truncated" => report.diagnostics_truncated,
         "sdk_version" => report.sdk_version
       }, event}
    end
  end

  # A failed build is a bounded report with the compiler's diagnostics, not
  # an error: the agent reads it and fixes its program.
  defp failed_build(failure) do
    emit("loop_build", "error")

    {:ok,
     %{
       "state" => failure.state,
       "error" => failure.error,
       "kind" => failure.kind,
       "diagnostics" => failure.diagnostics,
       "diagnostics_truncated" => failure.diagnostics_truncated
     }, nil}
  end

  # The ELF is an ordinary workspace file: any writable path the Agent can
  # see, never a runtime, skill or mount path.
  defp valid_artifact_path(path) do
    cond do
      not String.starts_with?(path, "/") -> {:error, {:invalid, "path"}}
      byte_size(path) > 512 -> {:error, {:invalid, "path"}}
      not FileBackend.normal_path?(path) -> {:error, {:invalid, "path"}}
      true -> :ok
    end
  end

  # ---- create / list / get / pause / resume / delete ------------------------

  @doc """
  Create a Loop from a built artifact and start it on this node.

  `attrs` keys: `path` (required: the workspace file `build/4` wrote),
  `name`, `config` (JSON object <= 16 KiB). The row records the path and
  the file's SHA-256; the bytes stay in the workspace. There is no per-Loop
  capability list: the program may call the whole Loop allowlist
  (`SalixAgent.Loops.Capabilities`) under its creator's authority.
  """
  @spec create(ctx(), map()) :: {:ok, map()} | {:error, term()}
  def create(%{agent_id: agent_id} = ctx, attrs) when is_map(attrs) do
    now = now_ms()

    with {:ok, agent} <- Control.get(agent_id),
         {:ok, session_id} <- require_session_id(ctx),
         {:ok, path} <- required_text(attrs, "path"),
         :ok <- valid_artifact_path(path),
         {:ok, elf} <- read_artifact(ctx, path),
         {:ok, name} <- optional_name(attrs["name"]),
         {:ok, config} <- validate_config(attrs["config"]) do
      record = %{
        "id" => Ids.new_loop_id(),
        "tenant_id" => agent["tenant_id"],
        "group_id" => agent["group_id"],
        "agent_id" => agent_id,
        "session_id" => session_id,
        "name" => name,
        "elf_sha256" => sha256_hex(elf),
        "elf_path" => path,
        "config" => config,
        "status" => "active",
        "ifc" => ifc_authority(ctx),
        "created_at" => now,
        "updated_at" => now
      }

      case admit(agent, {:create, record}) do
        {:ok, created} ->
          Reconciler.adopt(agent_id)
          {:ok, public(created)}

        {:error, _} = error ->
          error
      end
    end
  end

  @spec list(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(agent_id) when is_binary(agent_id) do
    with {:ok, records} <- Store.list_by_agent(agent_id) do
      {:ok, Enum.map(records, &public/1)}
    end
  end

  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(agent_id, loop_id) when is_binary(agent_id) and is_binary(loop_id) do
    with {:ok, record} <- Store.get_agent_owned(loop_id, agent_id) do
      {:ok, record |> public() |> Map.merge(runtime_view(record))}
    end
  end

  @spec pause(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def pause(agent_id, loop_id) do
    with {:ok, _} <- Store.get_agent_owned(loop_id, agent_id),
         {:ok, record} <- set_status(loop_id, "paused", "user") do
      Reconciler.release_loop(agent_id, loop_id)
      {:ok, public(record)}
    end
  end

  # Resume bumps the incarnation itself: a late notice from the object the
  # pause or fault retired can then never match the resumed row, even before
  # adoption records the next load.
  @spec resume(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resume(agent_id, loop_id) do
    with {:ok, current} <- Store.get_agent_owned(loop_id, agent_id),
         :ok <- resumable(current),
         {:ok, record} <-
           admit(current, {:update, loop_id, &activate(&1, resumable(&1), %{"failure" => nil})}) do
      Reconciler.adopt(agent_id)
      {:ok, public(record)}
    end
  end

  defp resumable(%{"status" => "active"}), do: {:error, :already_active}
  defp resumable(%{"status" => "paused", "paused_by" => "archive"}), do: {:error, :agent_archived}
  defp resumable(_), do: :ok

  # Every transition into `active` goes through `Store.admit_active/4`: the
  # count and the write commit under one Group lock, so create, resume and
  # unarchive cannot exceed the quota by interleaving.
  defp admit(%{"agent_id" => agent_id, "group_id" => group_id}, mutation) do
    Store.admit_active(
      agent_id,
      group_id,
      {max_active_per_agent(), max_active_per_group()},
      mutation
    )
  end

  # The row is re-read under the lock; the caller's precondition is
  # re-checked there so a concurrent change cannot slip through. Retiring
  # the old incarnation keeps a late exit or fault notice of the previous
  # object from landing on the resumed Loop.
  defp activate(current, :ok, extra) do
    {:ok,
     current
     |> Map.merge(%{
       "status" => "active",
       "paused_by" => nil,
       "object_id" => nil,
       "incarnation" => (current["incarnation"] || 0) + 1,
       "updated_at" => now_ms(),
       "pending_events" =>
         Map.new(current["pending_events"] || %{}, fn {id, event} ->
           {id, Map.put(event, "deadline_ms", now_ms() + :timer.minutes(15))}
         end)
     })
     |> Map.merge(extra)}
  end

  defp activate(_current, {:error, _} = error, _extra), do: error

  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(agent_id, loop_id) do
    Reconciler.release_loop(agent_id, loop_id)

    with :ok <- Store.delete_agent_owned(loop_id, agent_id) do
      _ = Store.delete_acks(loop_id)
      :ok
    end
  end

  @doc "Enable, rotate, or revoke the owning Agent's secret inbound URL."
  def configure_webhook(agent_id, loop_id, action)
      when action in ["enable", "rotate", "revoke"] do
    with {:ok, record} <-
           Store.update(loop_id, fn record ->
             if record["agent_id"] == agent_id do
               secret =
                 case action do
                   "revoke" -> nil
                   "enable" -> record["webhook_secret"] || new_webhook_secret()
                   "rotate" -> new_webhook_secret()
                 end

               {:ok, Map.merge(record, %{"webhook_secret" => secret, "updated_at" => now_ms()})}
             else
               {:error, :not_found}
             end
           end) do
      {:ok, public(record)}
    end
  end

  def configure_webhook(_agent_id, _loop_id, _action), do: {:error, {:invalid, "action"}}

  defp new_webhook_secret, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp webhook_url(%{"webhook_secret" => secret}) when is_binary(secret) do
    case Application.get_env(:salix_agent, :loop_webhook_url_builder) do
      builder when is_function(builder, 1) -> builder.(secret)
      _ -> nil
    end
  end

  defp webhook_url(_record), do: nil

  @doc "Deliver data to the Loop selected by a secret URL."
  def deliver_webhook_event(secret, event) when is_map(event) do
    started = System.monotonic_time()

    result =
      with {:ok, record} <- Store.get_by_webhook_secret(secret),
           {:ok, normalized} <- normalize_event(event) do
        deliver_to_owner(record, normalized)
      end

    emit("loop_event", event_outcome(result), System.monotonic_time() - started)
    result
  end

  @doc "Deliver an event from the owning Agent itself (the `loop.send` tool)."
  @spec send_event(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def send_event(agent_id, loop_id, event) when is_map(event) do
    with {:ok, record} <- Store.get_agent_owned(loop_id, agent_id),
         {:ok, normalized} <- normalize_event(event) do
      deliver_to_owner(record, normalized)
    end
  end

  @doc "Deliver an event from an external system authenticated for `group_id`."
  @spec deliver_external_event(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def deliver_external_event(group_id, loop_id, event) when is_map(event) do
    started = System.monotonic_time()

    result =
      with {:ok, record} <- Store.get_group_owned(loop_id, group_id),
           {:ok, normalized} <- normalize_event(event) do
        deliver_to_owner(record, normalized)
      end

    emit("loop_event", event_outcome(result), System.monotonic_time() - started)
    result
  end

  @doc "Deliver only while the current Loop still owns the captured Composio binding."
  def deliver_composio_event(id, binding, event) do
    started = System.monotonic_time()

    result =
      with {:ok, row} <- Store.get(id),
           true <- row["composio_trigger"] == binding,
           {:ok, normalized} <- normalize_event(event) do
        deliver_to_owner(row, normalized)
      else
        false -> {:error, :binding_changed}
        error -> error
      end

    emit("loop_event", event_outcome(result), System.monotonic_time() - started)
    result
  end

  # The PostgreSQL receipt owns accepted work. Placement/runtime failure after
  # this commit cannot turn it back into an unaccepted event.
  @max_pending_events 32
  @event_deadline_ms :timer.minutes(15)
  defp deliver_to_owner(%{"status" => "active"} = record, event) do
    with {:ok, reply} <-
           Store.admit_event(record, event, now_ms(), @max_pending_events, @event_deadline_ms) do
      Reconciler.adopt(record["agent_id"])
      {:ok, reply}
    end
  end

  defp deliver_to_owner(%{"status" => status}, _event), do: {:error, {:not_active, status}}

  @max_event_id_bytes 128
  @max_topic_bytes 128
  @max_event_bytes 16 * 1024

  defp normalize_event(event) do
    topic = text(event["topic"] || event[:topic])
    payload = event["payload"] || event[:payload] || %{}
    supplied = text(event["event_id"] || event[:event_id])

    event_id =
      if supplied == "",
        do: "sha256:" <> (payload |> Jason.encode!() |> sha256_hex()),
        else: supplied

    cond do
      topic == "" or byte_size(topic) > @max_topic_bytes ->
        {:error, {:invalid_event, "topic"}}

      byte_size(event_id) > @max_event_id_bytes ->
        {:error, {:invalid_event, "event_id"}}

      not (is_map(payload) or is_list(payload) or is_binary(payload) or is_number(payload) or
               is_boolean(payload)) ->
        {:error, {:invalid_event, "payload"}}

      byte_size(Jason.encode!(payload)) > @max_event_bytes ->
        {:error, {:invalid_event, "payload_too_large"}}

      true ->
        {:ok, %{"event_id" => event_id, "topic" => topic, "payload" => payload}}
    end
  end

  # Finite `Salix.Telemetry` outcomes: a duplicate is `already`, a full
  # mailbox is `dropped`, a malformed event is `rejected`, an unknown Loop is
  # `unroutable`.
  defp event_outcome({:ok, %{"duplicate" => true}}), do: "already"
  defp event_outcome({:ok, _}), do: "ok"
  defp event_outcome({:error, :mailbox_full}), do: "dropped"
  defp event_outcome({:error, {:invalid_event, _}}), do: "rejected"
  defp event_outcome({:error, :not_found}), do: "unroutable"
  defp event_outcome({:error, _}), do: "error"

  # ---- runtime callbacks (Host / Reconciler / Capabilities) -----------------

  @doc """
  Record a new incarnation for `loop_id` on `node` in spinfoam session
  `host_session`. Bumps `incarnation` and clears the object; the object is
  attached once loaded (`attach_object/3`). Refused for a Loop that is not
  active.
  """
  @spec begin_incarnation(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def begin_incarnation(loop_id, node, host_session) do
    Store.update(loop_id, fn current ->
      if current["status"] == "active" do
        {:ok,
         Map.merge(current, %{
           "incarnation" => (current["incarnation"] || 0) + 1,
           "incarnation_node" => node,
           "incarnation_session" => host_session,
           "object_id" => nil,
           "updated_at" => now_ms()
         })}
      else
        {:error, :not_active}
      end
    end)
  end

  @doc "Attach the loaded object to `incarnation`; a newer incarnation refuses."
  @spec attach_object(String.t(), integer(), String.t()) :: :ok | {:error, term()}
  def attach_object(loop_id, incarnation, object_id) do
    Store.update(loop_id, fn current ->
      if current["incarnation"] == incarnation,
        do: {:ok, Map.merge(current, %{"object_id" => object_id, "updated_at" => now_ms()})},
        else: {:error, :stale_incarnation}
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "Forget the object of `incarnation`; a newer incarnation is left alone."
  @spec end_incarnation(String.t(), integer()) :: :ok
  def end_incarnation(loop_id, incarnation) do
    _ =
      Store.update(loop_id, fn current ->
        if current["incarnation"] == incarnation,
          do: {:ok, Map.merge(current, %{"object_id" => nil, "updated_at" => now_ms()})},
          else: {:unchanged, current}
      end)

    :ok
  end

  @doc "Whether `incarnation` is still the row's current one."
  @spec current_incarnation?(String.t(), integer()) :: boolean()
  def current_incarnation?(loop_id, incarnation) do
    case Store.get(loop_id) do
      {:ok, %{"incarnation" => ^incarnation, "status" => "active"}} -> true
      _ -> false
    end
  end

  @spec put_checkpoint(String.t(), integer(), term()) :: :ok | {:error, term()}
  def put_checkpoint(loop_id, incarnation, state) do
    with :ok <- bounded_json(state, @max_checkpoint_bytes, :checkpoint_too_large) do
      Store.update(loop_id, fn current ->
        if current["incarnation"] == incarnation,
          do: {:ok, Map.merge(current, %{"checkpoint" => state, "updated_at" => now_ms()})},
          else: {:error, :stale_incarnation}
      end)
      |> case do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  @spec get_checkpoint(String.t()) :: {:ok, term()} | {:error, term()}
  def get_checkpoint(loop_id) do
    with {:ok, record} <- Store.get(loop_id), do: {:ok, record["checkpoint"]}
  end

  @spec ack_event(String.t(), integer(), String.t()) :: :ok | {:error, term()}
  def ack_event(loop_id, incarnation, event_id) when is_binary(event_id) and event_id != "" do
    Store.settle_event(loop_id, incarnation, event_id, now_ms())
  end

  def ack_event(_loop_id, _incarnation, _event_id), do: {:error, :invalid_event_id}

  @doc """
  Admit one `agent.notify`. A fixed window of #{@notify_window_limit} per
  #{div(@notify_window_ms, 60_000)} minutes; past it the call is rate limited,
  and after #{div(@notify_limited_pause_ms, 60_000)} minutes of continuous
  limiting the Loop is paused with reason `budget`.
  """
  @spec admit_notification(String.t(), integer()) ::
          :ok | {:error, :rate_limited} | {:error, :budget_paused} | {:error, term()}
  def admit_notification(loop_id, incarnation) do
    now = now_ms()

    Store.update(loop_id, fn current ->
      cond do
        current["incarnation"] != incarnation ->
          {:error, :stale_incarnation}

        current["status"] != "active" ->
          {:error, :not_active}

        true ->
          window_start = current["notify_window_start_ms"] || 0
          count = current["notify_window_count"] || 0

          {window_start, count} =
            if now - window_start >= @notify_window_ms, do: {now, 0}, else: {window_start, count}

          if count < @notify_window_limit do
            {:ok,
             Map.merge(current, %{
               "notify_window_start_ms" => window_start,
               "notify_window_count" => count + 1,
               "notify_limited_since_ms" => nil,
               "last_notified_at" => now,
               "updated_at" => now
             })}
          else
            since = current["notify_limited_since_ms"] || now

            if now - since >= @notify_limited_pause_ms do
              {:ok,
               Map.merge(current, %{
                 "status" => "paused",
                 "paused_by" => "budget",
                 "notify_limited_since_ms" => since,
                 "updated_at" => now
               })}
            else
              {:ok,
               Map.merge(current, %{"notify_limited_since_ms" => since, "updated_at" => now})}
            end
          end
      end
    end)
    |> case do
      {:ok, %{"status" => "paused", "paused_by" => "budget"} = record} ->
        Reconciler.release_loop(record["agent_id"], loop_id)
        notify_lifecycle(record, "budget", "paused: notification budget exhausted")
        {:error, :budget_paused}

      {:ok, %{"notify_limited_since_ms" => since}} when is_integer(since) ->
        {:error, :rate_limited}

      {:ok, _} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc "The guest returned from `main`: pause with reason `exited` and tell the Session once."
  @spec record_exit(String.t(), integer(), integer() | nil) :: :ok
  def record_exit(loop_id, incarnation, exit_code) do
    case Store.update(loop_id, fn current ->
           if current["incarnation"] == incarnation and current["status"] == "active" do
             {:ok,
              Map.merge(current, %{
                "status" => "paused",
                "paused_by" => "exited",
                "exit_code" => exit_code,
                "object_id" => nil,
                "updated_at" => now_ms()
              })}
           else
             {:error, :stale_incarnation}
           end
         end) do
      {:ok, record} ->
        notify_lifecycle(
          record,
          "exited:#{incarnation}",
          "exited with code #{inspect(exit_code)}"
        )

        :ok

      {:error, _} ->
        :ok
    end
  end

  @doc """
  The guest faulted. Within the restart budget the Loop is reloaded from its
  checkpoint (`{:ok, :restart}`); past it the Loop is `failed` and the
  Session is told once (`{:ok, :failed}`).
  """
  @spec record_failure(String.t(), integer(), String.t()) ::
          {:ok, :restart | :failed} | {:error, term()}
  def record_failure(loop_id, incarnation, diagnostic) do
    now = now_ms()
    diagnostic = diagnostic |> text() |> String.slice(0, 2_000)

    Store.update(loop_id, fn current ->
      cond do
        current["incarnation"] != incarnation or current["status"] != "active" ->
          {:error, :stale_incarnation}

        true ->
          window_start = current["restart_window_start_ms"] || 0
          count = current["restart_count"] || 0

          {window_start, count} =
            if now - window_start >= @restart_window_ms, do: {now, 0}, else: {window_start, count}

          if count < @restart_limit do
            {:ok,
             Map.merge(current, %{
               "restart_window_start_ms" => window_start,
               "restart_count" => count + 1,
               "failure" => diagnostic,
               "object_id" => nil,
               "updated_at" => now
             })}
          else
            {:ok,
             Map.merge(current, %{
               "status" => "failed",
               "paused_by" => nil,
               "failure" => diagnostic,
               "object_id" => nil,
               "updated_at" => now
             })}
          end
      end
    end)
    |> case do
      {:ok, %{"status" => "failed"} = record} ->
        notify_lifecycle(
          record,
          "failed:#{incarnation}",
          "failed and will not restart: " <> diagnostic
        )

        {:ok, :failed}

      {:ok, _} ->
        {:ok, :restart}

      {:error, _} = error ->
        error
    end
  end

  @doc "Replay retained events on the owning node, or retain them in an actionable failed Loop."
  def reconcile_events(loop_id) do
    with {:ok, record} <- Store.get(loop_id),
         true <- live_incarnation?(record),
         events = record["pending_events"] || %{} do
      if Enum.any?(events, fn {_id, event} -> event["deadline_ms"] <= now_ms() end) do
        fail_pending_events(record)
      else
        events
        |> Enum.sort_by(fn {id, event} -> {event["deadline_ms"], id} end)
        |> Enum.reduce_while(:ok, fn {_id, event}, _ ->
          case Host.deliver_loop_event(loop_id, Map.take(event, ~w(event_id topic payload))) do
            {:ok, _} -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end)
      end
    else
      _ -> :ok
    end
  end

  defp live_incarnation?(record) do
    record["status"] == "active" and
      match?({:ok, _}, SalixAgent.OwnershipCell.fetch(record["agent_id"]))
  end

  defp fail_pending_events(record) do
    Store.update(record["id"], fn current ->
      if current["status"] == "active" and current["incarnation"] == record["incarnation"] and
           Enum.any?(current["pending_events"] || %{}, fn {_id, event} ->
             event["deadline_ms"] <= now_ms()
           end) do
        {:ok,
         Map.merge(current, %{
           "status" => "failed",
           "failure" =>
             "Event acknowledgement deadline exceeded; pending events retained. Resume to retry, or delete the Loop to discard.",
           "updated_at" => now_ms()
         })}
      else
        {:error, :stale_incarnation}
      end
    end)
    |> case do
      {:ok, failed} ->
        _ = Host.object_unload(record["object_id"])
        notify_lifecycle(failed, "event-deadline:#{record["incarnation"]}", failed["failure"])
        emit("loop_event", "error", 0)
        :ok

      _ ->
        :ok
    end
  end

  @doc "The notification target Session cannot be resolved: pause with reason `undeliverable`."
  @spec mark_undeliverable(String.t()) :: :ok
  def mark_undeliverable(loop_id) do
    case set_status(loop_id, "paused", "undeliverable") do
      {:ok, record} -> Reconciler.release_loop(record["agent_id"], loop_id)
      _ -> :ok
    end

    :ok
  end

  @doc "Archive: every active Loop of the Agent becomes `paused(archive)`."
  @spec pause_for_archive(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def pause_for_archive(agent_id) do
    Reconciler.release(agent_id)
    Store.transition_by_agent(agent_id, "active", nil, "paused", "archive", now_ms())
  end

  @doc """
  Unarchive: every `paused(archive)` Loop of the Agent becomes active again,
  oldest first, each admitted against the quota. A Loop the quota no longer
  admits stays paused with reason `quota` until `loop.resume` finds room.
  """
  @spec resume_for_unarchive(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def resume_for_unarchive(agent_id) do
    with {:ok, records} <- Store.list_by_agent(agent_id) do
      archived =
        Enum.filter(records, &(&1["status"] == "paused" and &1["paused_by"] == "archive"))

      count =
        Enum.count(archived, fn record ->
          precondition = fn current ->
            if current["status"] == "paused" and current["paused_by"] == "archive",
              do: :ok,
              else: {:error, :not_archived}
          end

          case admit(record, {:update, record["id"], &activate(&1, precondition.(&1), %{})}) do
            {:ok, _} ->
              true

            {:error, {:quota, _, _}} ->
              _ = set_status(record["id"], "paused", "quota")
              false

            {:error, _} ->
              false
          end
        end)

      if count > 0, do: Reconciler.adopt(agent_id)
      {:ok, count}
    end
  end

  @doc """
  Whether the Agent's Server must stay resident: an active Loop runs only
  while its Agent's lease is held here, so the idle park timeout renews the
  lease instead of passivating while any Loop is active.
  """
  @spec retains_owner?(String.t()) :: boolean()
  def retains_owner?(agent_id) when is_binary(agent_id), do: Store.any_active?(agent_id)

  # ---- projections ----------------------------------------------------------

  @doc """
  The ELF of a Loop, read back from the Agent's workspace and verified
  against the hash recorded at `create/2`. A file that is gone or changed
  is a load failure, never a silent substitution.
  """
  @spec artifact(map()) ::
          {:ok, binary()} | {:error, :artifact_missing | :artifact_changed | term()}
  def artifact(%{"agent_id" => agent_id, "elf_path" => path, "elf_sha256" => sha}) do
    case AgentWorkspace.read(agent_id, path) do
      {:ok, elf} -> if sha256_hex(elf) == sha, do: {:ok, elf}, else: {:error, :artifact_changed}
      {:error, :not_found} -> {:error, :artifact_missing}
      {:error, _} = error -> error
    end
  end

  @doc "The reader projection: everything but the budget counters."
  @spec public(map()) :: map()
  def public(record) when is_map(record) do
    %{
      "loop_id" => record["id"],
      "webhook_url" => webhook_url(record),
      "composio_trigger" => record["composio_trigger"],
      "agent_id" => record["agent_id"],
      "session_id" => record["session_id"],
      "name" => record["name"],
      "path" => record["elf_path"],
      "artifact_sha256" => record["elf_sha256"],
      "config" => record["config"] || %{},
      "status" => record["status"],
      "paused_by" => record["paused_by"],
      "failure" => record["failure"],
      "exit_code" => record["exit_code"],
      "incarnation" => record["incarnation"] || 0,
      "node" => record["incarnation_node"],
      "restart_count" => record["restart_count"] || 0,
      "created_at" => record["created_at"],
      "updated_at" => record["updated_at"],
      "last_notified_at" => record["last_notified_at"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp runtime_view(%{"object_id" => object_id, "incarnation_node" => node} = record)
       when is_binary(object_id) do
    checkpoint = %{"checkpoint" => record["checkpoint"]}

    if node == Atom.to_string(node()) do
      case Host.object_get(object_id) do
        {:ok, status} -> Map.merge(checkpoint, %{"runtime" => status})
        {:error, _} -> Map.merge(checkpoint, %{"runtime" => %{"state" => "detached"}})
      end
    else
      Map.merge(checkpoint, %{"runtime" => %{"state" => "remote", "node" => node}})
    end
  end

  defp runtime_view(record), do: %{"checkpoint" => record["checkpoint"]}

  # ---- helpers --------------------------------------------------------------

  defp notify_lifecycle(record, dedup_suffix, text) do
    label =
      if record["name"] in [nil, ""],
        do: record["id"],
        else: "#{record["name"]} (#{record["id"]})"

    Capabilities.deliver_notification(
      record,
      "Background loop #{label} #{text}.",
      "lifecycle:" <> dedup_suffix,
      lifecycle: true
    )
  end

  defp set_status(loop_id, status, paused_by, extra \\ %{}) do
    Store.update(loop_id, fn current ->
      {:ok,
       current
       |> Map.merge(%{"status" => status, "paused_by" => paused_by, "updated_at" => now_ms()})
       |> Map.merge(extra)}
    end)
  end

  # `create/2` reads the file the way the Agent sees it (visibility rules
  # included) and checks it is an ELF of the size the runtime accepts.
  defp read_artifact(ctx, path) do
    case FileBackend.read(ctx, path) do
      {:ok, <<0x7F, "ELF", _::binary>> = elf, _} when byte_size(elf) <= @max_elf_bytes ->
        {:ok, elf}

      {:ok, _, _} ->
        {:error, :invalid_artifact}

      {:error, :not_found} ->
        {:error, :artifact_not_found}

      {:error, _} = error ->
        error
    end
  end

  defp require_session_id(ctx) do
    case Map.get(ctx, :session_id) || Map.get(ctx, "session_id") do
      sid when is_binary(sid) ->
        sid = String.trim(sid)
        if Ids.valid_session_id?(sid), do: {:ok, sid}, else: {:error, :invalid_session_id}

      _ ->
        {:error, :missing_session_id}
    end
  end

  defp required_text(attrs, key) do
    case text(attrs[key] || attrs[String.to_atom(key)]) do
      "" -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp optional_name(nil), do: {:ok, nil}

  defp optional_name(value) do
    name = value |> text() |> String.trim()

    cond do
      name == "" -> {:ok, nil}
      String.length(name) > @max_name_chars -> {:error, {:invalid, "name"}}
      true -> {:ok, name}
    end
  end

  defp validate_config(nil), do: {:ok, %{}}

  defp validate_config(config) when is_map(config) do
    with :ok <- bounded_json(config, @max_config_bytes, {:invalid, "config_too_large"}) do
      {:ok, config}
    end
  end

  defp validate_config(_), do: {:error, {:invalid, "config"}}

  defp bounded_json(value, limit, error) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= limit -> :ok
      {:ok, _} -> {:error, error}
      {:error, _} -> {:error, error}
    end
  end

  # Who asked for this Loop and what its inputs were labelled: recorded at
  # creation exactly as `schedule.create` records it, because at run time
  # there is no activation to ask (docs/verification.md §8).
  defp ifc_authority(ctx) do
    case Map.get(ctx, :ifc_evidence) do
      %{} = evidence ->
        %{}
        |> put_present("creator", evidence["requester"])
        |> put_present("label", evidence["sources_label"])

      _absent ->
        %{}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: value
  defp text(value), do: to_string(value)

  defp now_ms, do: System.system_time(:millisecond)

  defp emit(operation, outcome, duration \\ 0) do
    Salix.Telemetry.emit_operation("salix_agent", operation, "loop", outcome, duration)
  end
end
