defmodule SalixIM.TaskLoop do
  @moduledoc """
  A Loop Task is a Task that shows one Background Loop. The Loop is the
  only record of the work's cadence, limits, runs and state
  (`SalixAgent.Loops`, through `SalixIM.Ports.TaskLoops`); the Task holds
  its Messages, its Router and its Worker.

  The Router requests `loop` at Task creation, or for an ended Loop after a
  new human request. The request writes the Loop `pending` before the Task's
  command reaches the Worker, which gives it its program and reports each
  run in the Task. Wakes and lifecycle notices of the Loop reach the Worker
  as private `agent_input` Messages in the Task.

  The Loop never follows the Task's status. The Task ending (completed,
  cancelled or failed), or its archive, ends the Loop first. A Loop that
  ends on its own (run limit, end time) completes the Task once. A Loop that
  stops on its own (exited, failed, budget, quota) keeps the Task active and
  shows why; its Worker says so in the Task.

  See docs/architecture/DOMAIN_CONCEPTS.md, "Loop Tasks".
  """

  require Logger

  alias SalixIM.Ports.TaskLoops

  @ended_statuses ~w(completed cancelled failed)
  @request_keys ~w(cadence max_runs ends_at until)
  @cadence_keys ~w(every_minutes cron timezone events)
  @every_minutes 5..1440
  @max_runs 1..1000
  # Clients show the events text as the Loop's trigger rule: a short label that
  # names the source and the change. The limit counts graphemes, so a Chinese
  # label gets the same budget as an English label. The tool schema's
  # maxLength counts code points, never fewer than graphemes, so a label that
  # fits the schema always passes here.
  @events_chars 32
  @until_bytes 500
  @cron_bytes 120
  @message_type "task_loop"

  def message_type, do: @message_type

  # ---- the Router's request --------------------------------------------------

  @doc """
  Validate the Router's `loop` request and answer its stored form: `cadence`
  as one of `%{"every_minutes" => n}`, `%{"cron" => c, "timezone" => tz}` or
  `%{"events" => text}`, `max_runs`, `ends_at` (unix ms) and `until` when
  given. Options: `:now` (unix ms) that `ends_at` must follow, and
  `:timezone`, the timezone of the request the round serves, used when a cron
  cadence names none.
  """
  @spec request(term(), keyword()) :: {:ok, map() | nil} | {:error, String.t()}
  def request(nil, _opts), do: {:ok, nil}

  def request(params, opts) when is_map(params) do
    with :ok <- known_keys(params, @request_keys, "loop"),
         {:ok, cadence} <- cadence(params["cadence"], opts[:timezone]),
         {:ok, max_runs} <- max_runs(params["max_runs"]),
         {:ok, ends_at} <- ends_at(params["ends_at"], Keyword.fetch!(opts, :now)),
         {:ok, until} <- until(params["until"]) do
      {:ok,
       %{"cadence" => cadence}
       |> put_present("max_runs", max_runs)
       |> put_present("ends_at", ends_at)
       |> put_present("until", until)}
    end
  end

  def request(_params, _opts), do: {:error, "loop must be an object"}

  defp cadence(%{} = cadence, default_timezone) do
    with :ok <- known_keys(cadence, @cadence_keys, "loop.cadence") do
      case Map.take(cadence, ~w(every_minutes cron events)) |> Map.keys() do
        ["every_minutes"] -> every_minutes(cadence)
        ["cron"] -> cron(cadence, default_timezone)
        ["events"] -> events(cadence)
        _ -> {:error, cadence_shape()}
      end
    end
  end

  defp cadence(_cadence, _default_timezone), do: {:error, cadence_shape()}

  defp cadence_shape,
    do:
      "loop.cadence needs exactly one of every_minutes, cron (with timezone) or events; " <>
        "if the user gave no cadence, ask once and propose a concrete one"

  defp every_minutes(%{"every_minutes" => minutes} = cadence) do
    cond do
      Map.has_key?(cadence, "timezone") ->
        {:error, "loop.cadence.timezone goes only with cron"}

      is_integer(minutes) and minutes in @every_minutes ->
        {:ok, %{"every_minutes" => minutes}}

      true ->
        {:error, "loop.cadence.every_minutes must be a whole number from 5 to 1440"}
    end
  end

  defp cron(%{"cron" => cron} = cadence, default_timezone) do
    cron = text(cron)
    timezone = text(cadence["timezone"])
    timezone = if timezone == "", do: text(default_timezone), else: timezone

    cond do
      not valid_cron?(cron) ->
        {:error, "loop.cadence.cron must be a standard 5-field cron expression"}

      timezone == "" ->
        {:error,
         "loop.cadence.timezone is required with cron (an IANA name such as Asia/Shanghai); " <>
           "ask the user if it is unclear"}

      not valid_timezone?(timezone) ->
        {:error, "loop.cadence.timezone must be an IANA timezone name such as Asia/Shanghai"}

      true ->
        {:ok, %{"cron" => cron, "timezone" => timezone}}
    end
  end

  defp events(%{"events" => events} = cadence) do
    events = text(events)

    cond do
      Map.has_key?(cadence, "timezone") ->
        {:error, "loop.cadence.timezone goes only with cron"}

      events == "" or String.length(events) > @events_chars ->
        {:error,
         "loop.cadence.events must be a label of 1 to #{@events_chars} characters. " <>
           "Name only the source and the change, such as New comments on PR #12. " <>
           "Put the conditions, the people and the work in content or command, " <>
           "and the stop condition in until."}

      true ->
        {:ok, %{"events" => events}}
    end
  end

  # The Loop runtime parses the cron fully when the request writes the Loop
  # (`SalixAgent.Loops.request_task_loop/1`); here it only has to be one.
  defp valid_cron?(cron) do
    fields = String.split(cron)

    byte_size(cron) in 1..@cron_bytes and length(fields) == 5 and
      Enum.all?(fields, &Regex.match?(~r/\A[0-9A-Za-z*,\/\-?#]+\z/, &1))
  end

  defp valid_timezone?(timezone) do
    match?({:ok, _now}, DateTime.now(timezone))
  rescue
    _ -> false
  end

  defp max_runs(nil), do: {:ok, nil}
  defp max_runs(runs) when is_integer(runs) and runs in @max_runs, do: {:ok, runs}
  defp max_runs(_runs), do: {:error, "loop.max_runs must be a whole number from 1 to 1000"}

  defp ends_at(nil, _now), do: {:ok, nil}

  defp ends_at(value, now) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, at, _offset} ->
        at_ms = DateTime.to_unix(at, :millisecond)

        if at_ms > now,
          do: {:ok, at_ms},
          else: {:error, "loop.ends_at must be in the future"}

      {:error, :missing_offset} ->
        {:error,
         "loop.ends_at needs a UTC offset, such as 2026-11-02T18:00:00+08:00; " <>
           "use the user's timezone"}

      {:error, _reason} ->
        {:error, "loop.ends_at must be an RFC 3339 time with a UTC offset"}
    end
  end

  defp ends_at(_value, _now),
    do: {:error, "loop.ends_at must be an RFC 3339 time with a UTC offset"}

  defp until(nil), do: {:ok, nil}

  defp until(value) when is_binary(value) do
    case text(value) do
      "" -> {:error, "loop.until must not be empty"}
      until when byte_size(until) > @until_bytes -> {:error, "loop.until is over 500 bytes"}
      until -> {:ok, until}
    end
  end

  defp until(_value), do: {:error, "loop.until must be text"}

  defp known_keys(map, keys, name) do
    case Map.keys(map) -- keys do
      [] -> :ok
      unknown -> {:error, "#{name} does not take #{Enum.join(Enum.sort(unknown), ", ")}"}
    end
  end

  # ---- the Task's Loop --------------------------------------------------------

  @doc """
  Write the Loop that a validated `request` asks for, `pending` until the
  Worker `worker_agent_id` binds its program. A Task whose Loop ended gets a
  new Loop; a repeated request keeps the pending one.
  """
  @spec request_loop(map(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def request_loop(scope, worker_agent_id, conversation_id, %{"cadence" => cadence} = request) do
    TaskLoops.request_task_loop(%{
      "tenant_id" => scope.tenant_id,
      "group_id" => scope.group_id,
      "agent_id" => worker_agent_id,
      "task_conversation_id" => conversation_id,
      "trigger" => cadence,
      "max_runs" => request["max_runs"],
      "ends_at" => request["ends_at"],
      "stop_condition" => request["until"]
    })
  end

  @doc "The Task's Loop (`SalixIM.Ports.TaskLoops` view), or nil. One indexed read."
  @spec get(String.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def get(group_id, conversation_id) when is_binary(group_id) and is_binary(conversation_id) do
    with {:ok, loops} <- TaskLoops.task_loops(group_id, [conversation_id]),
         do: {:ok, loops[conversation_id]}
  end

  def get(_group_id, _conversation_id), do: {:ok, nil}

  @doc "Whether `view` is a Task's requested Loop that has not ended."
  def running?(%{"trigger" => %{}, "status" => status}), do: status != "ended"
  def running?(_view), do: false

  @doc """
  The Router may not move a Task whose requested Loop has not ended to
  `ready_for_review`: one report is one run, not the end of the work. Reads
  the Task's Loop only for that update.
  """
  def status_allowed(
        %{"kind" => "agent_task", "agent_group_id" => group_id, "conversation_id" => id},
        %{"status" => "ready_for_review"}
      ) do
    case get(group_id, id) do
      {:ok, view} ->
        if running?(view),
          do:
            {:error,
             {:forbidden,
              "This Task runs a Loop, and one report is one run, not the end of the work. " <>
                "Keep it active while the Loop runs, or end the Task (completed, cancelled or failed)"}},
          else: :ok

      {:error, reason} ->
        {:error, {:task_loops, reason}}
    end
  end

  def status_allowed(_conversation, _updates), do: :ok

  @doc """
  The Router may restart the Loop of its own Task after a new human request.
  The caller has checked that the Task's Loop ended, and wrote the new Loop.
  """
  def restart_allowed(record, router_id, human_at) do
    cond do
      record["kind"] != "agent_task" ->
        {:error, {:bad_request, "This Task has no Loop to restart"}}

      record["created_by_agent_id"] != router_id ->
        {:error, {:forbidden, "Only the Task's Router can restart its Loop"}}

      record["status"] == "archived" or
          get_in(record, ["schedule", "schedule_id"]) not in [nil, ""] ->
        {:error, {:conflict, "Restore this Task before restarting its Loop"}}

      not is_integer(human_at) ->
        {:error, {:forbidden, "A later user message must request the new Loop"}}

      true ->
        SalixIM.TaskManualStatus.router_update(
          record,
          %{"status" => "active"},
          router_id,
          human_at
        )
    end
  end

  @doc """
  An ended Task ends its requested Loop, with the status as the reason, at
  each status publication (retried with it); a Loop the Task did not
  request is deleted. An archived Task cancels its requested Loop. The Loop
  holds the end; restoring the Task does not run it again.
  """
  @spec converge(map()) :: :ok | {:error, term()}
  def converge(
        %{"kind" => "agent_task", "agent_group_id" => group_id, "conversation_id" => id} =
          record
      )
      when is_binary(group_id) and is_binary(id) do
    case record["status"] do
      status when status in @ended_statuses -> end_loops(group_id, id, status)
      "archived" -> end_loops(group_id, id, "archived")
      _status -> :ok
    end
  end

  def converge(_record), do: :ok

  defp end_loops(group_id, conversation_id, reason) do
    case TaskLoops.end_task_loops(group_id, conversation_id, reason) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "task loops #{conversation_id} end failed: #{inspect(reason) |> String.slice(0, 256)}"
        )

        {:error, {:task_loops, reason}}
    end
  end

  @doc "Delete the Loops of a Task that is gone."
  def delete_loops(group_id, conversation_id) do
    case TaskLoops.delete_task_loops(group_id, conversation_id) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, {:task_loops, reason}}
    end
  end

  @doc """
  The status a Task takes when its Loop ended on its own or after the Task
  ended it: the run limit and the end time complete it.
  """
  def ended_status(reason) when reason in @ended_statuses, do: reason
  def ended_status(_reason), do: "completed"

  @doc "The Router's notice for a Loop that ended at its run limit or end time, or nil."
  def ended_notice("max_runs", view),
    do:
      "This Task's Loop reached its run limit of #{view["max_runs"]} runs, so the server " <>
        "ended it and completed the Task. When the Worker has reported the last run, " <>
        "deliver the result if it is needed. Do not start another Loop."

  def ended_notice("ends_at", view),
    do:
      "This Task's Loop reached its end time (#{iso(view["ends_at"])}), so the server " <>
        "ended it and completed the Task. When the Worker has reported the last run, " <>
        "deliver the result if it is needed. Do not start another Loop."

  def ended_notice(_reason, _view), do: nil

  @doc """
  Whether the Task's requested Loop runs now. One indexed read; a failed read
  counts as running.
  """
  def loop_runs?(%{"agent_group_id" => group_id, "conversation_id" => id}) do
    case get(group_id, id) do
      {:ok, %{"status" => "active"} = view} -> running?(view)
      {:ok, _view} -> false
      {:error, _reason} -> true
    end
  end

  def loop_runs?(_record), do: false

  # ---- what the Router and the Worker read ----------------------------------

  @doc "The compact `loop` of a Task in the Router's `task.list`, from its Loop's view."
  def summary(%{"trigger" => %{} = cadence} = view) do
    %{"cadence" => cadence, "runs" => view["run_count"] || 0}
    |> put_present("max_runs", view["max_runs"])
    |> put_present("ends_at", iso(view["ends_at"]))
    |> put_present("until", view["stop_condition"])
    |> put_present("last_run_at", iso(view["last_run_at"]))
    |> put_present("ended", view["ended_reason"])
  end

  def summary(_view), do: nil

  @doc "The compact `loop` that `task.create` and a restart answer for a validated request."
  def request_summary(%{"cadence" => cadence} = request) do
    %{"cadence" => cadence, "runs" => 0}
    |> put_present("max_runs", request["max_runs"])
    |> put_present("ends_at", iso(request["ends_at"]))
    |> put_present("until", request["until"])
  end

  @doc "How the Worker runs a Loop Task, in the command that starts each Loop request."
  def worker_guidance(%{"cadence" => cadence} = loop, conversation_id) do
    limits =
      [
        loop["max_runs"] && "at most #{loop["max_runs"]} runs",
        loop["ends_at"] && "until #{iso(loop["ends_at"])}",
        loop["until"] && "stopping when: #{loop["until"]}"
      ]
      |> Enum.reject(&(&1 in [nil, false]))

    limits = if limits == [], do: "", else: " (" <> Enum.join(limits, "; ") <> ")"

    "This Task is a Loop Task: the requester asked for work that repeats " <>
      worker_cadence(cadence) <>
      limits <>
      ". The server already holds this Task's Background Loop with that cadence and those " <>
      "limits. Give it its program: read loop.sdk, write the program, build it with " <>
      "loop.build and create it with loop.create, passing no cadence" <>
      timed_guidance(cadence) <>
      ". Each agent.notify of the program is one run and wakes you in this Task. Report each " <>
      "run as exactly one result Message in this Task with im_api.internal.send_message" <>
      if(loop["until"],
        do: ", and say in it when the stop condition holds",
        else: ""
      ) <>
      ". Never change the Task status; the Router does. The server ends the Loop at its run " <>
      "limit or end time, and when the Task ends. If the Loop stops on its own, say why in " <>
      "one Message in this Task. If you cannot create the Loop, publish one failure Message " <>
      "that says why. The source Task conversation_id is #{conversation_id}."
  end

  defp worker_cadence(%{"every_minutes" => minutes}), do: "every #{minutes} minutes"

  defp worker_cadence(%{"cron" => cron, "timezone" => timezone}),
    do: "on the cron schedule \"#{cron}\" in #{timezone}"

  defp worker_cadence(%{"events" => events}), do: "whenever this happens: #{events}"

  defp timed_guidance(%{"events" => _events}),
    do:
      ". The program waits for its events with sf_event_next (a secret URL from loop.webhook, " <>
        "a Composio trigger, or loop.send)"

  defp timed_guidance(_cadence),
    do:
      ". The program asks loop.next_run for the time of each run and waits until then; " <>
        "the server does the clock and timezone math"

  defp iso(ms) when is_integer(ms),
    do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp iso(_ms), do: nil

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""
end
