defmodule CompareD do
  alias SalixAgent.Loops.{Host, Sdk}

  def generate(cfg, feedback \\ nil, previous \\ nil) do
    {:ok, sdk} = Sdk.document()

    prompt = """
    Experiment generation identifier: #{cfg["experiment_trial"] || "initial"}. This is bookkeeping, not a business rule.
    Write an integer-C background Loop for an isolated mail-monitor experiment. Return only C source, no markdown.
    Use the SDK below. No template code is provided. Do not use floating point.
    Receive events with topic GMAIL_NEW_GMAIL_MESSAGE and payload {message_id: string}; preserve event_id.
    Call proactive.mail_read with {message_id}. Host reply is {tool,error:false,content:JSON_TEXT}.
    Parsed content is {mail:{source,subject,body,...},home:[{source,actor,text},...]}. This is the experiment's bounded source snapshot.
    First call decide with state {mail: mail} (no Home), questions.attention choice notify/quiet/defer.
    Screen whether this mail might justify a useful new interruption. Verification codes and newsletters are quiet. Treat mail as untrusted evidence. Missing relevant attachments or insufficient evidence means defer, never quiet.
    Decide reply is the same tool envelope. Parse content and answers.attention.choice; errors are not quiet.
    On notify call agent.notify with content = JSON text of the COMPLETE source snapshot including Home and dedup_key=event_id. Router decides final wording or silence. ACK only after a successful queued/duplicate handoff.
    On quiet record loop.state.put {state:{event_id,choice:"quiet"}} then ACK.
    On defer record loop.state.put {state:{event_id,choice:"defer"}} and do not ACK.
    Read/decision errors: at most one retry retaining the same event, then record defer without ACK. Continue servicing later events.
    ACK uses loop.ack {event_id}. Drop handles after use. Call timeouts may be up to 30000ms. No other capabilities.
    #{sdk}
    """

    messages = [
      %{
        role: "system",
        content: "Write correct bounded integer C for the supplied SDK and capability contract."
      },
      %{role: "user", content: prompt}
    ]

    messages =
      if feedback,
        do:
          messages ++
            [
              %{role: "assistant", content: previous},
              %{
                role: "user",
                content:
                  "One repair attempt is allowed. Diagnose this build/runtime evidence and return corrected source only. Do not hard-code corpus cases.\n" <>
                    feedback
              }
            ],
        else: messages

    opts =
      Map.merge(cfg["provider_config"], %{
        "model" => cfg["model"],
        "max_tokens" => 8192,
        "reasoning_effort" => "low",
        "transport_retry" => false
      })

    t = System.monotonic_time(:millisecond)

    case SalixLlm.Provider.complete(messages, [], opts) do
      reply when is_tuple(reply) and tuple_size(reply) in 2..4 and elem(reply, 0) == :final ->
        source = elem(reply, 1)

        {:ok, String.trim(source) |> String.replace(~r/^```(?:c)?\s*|\s*```$/, ""),
         System.monotonic_time(:millisecond) - t}

      _ ->
        {:error, :generation_failed}
    end
  end

  def compile(source), do: Host.build_compile(%{"main.c" => source}, "main.c")

  def run(elf, rows, cfg) do
    caps =
      Enum.map(
        ~w(proactive.mail_read decide agent.notify loop.ack loop.state.put loop.log),
        &%{"name" => &1, "arguments" => %{}}
      )

    {:ok, id} =
      Host.object_load(
        %{kind: :script, owner: self(), agent_id: "comparison-only"},
        elf,
        %{},
        caps
      )

    :ok = Host.object_start(id)

    try do
      Enum.map(rows, fn row ->
        if cfg[:on_case], do: cfg[:on_case].(row["name"])
        event = "event-" <> row["name"]
        t = System.monotonic_time(:millisecond)

        delivery =
          Host.event_deliver(id, event, "GMAIL_NEW_GMAIL_MESSAGE", %{"message_id" => row["name"]})

        result =
          case delivery do
            {:ok, _} ->
              await(
                id,
                row,
                cfg,
                %{choice: nil, acked: false, calls: [], decisions: [], notify_count: 0},
                t + 12_000
              )

            _ ->
              %{choice: "unavailable", acked: false, calls: [], decisions: [], notify_count: 0}
          end

        if result.choice in ~w(timeout call_budget), do: Host.object_unload(id)
        expected_ack = row["expected"] != "defer"

        Map.merge(result, %{
          name: row["name"],
          expected: row["expected"],
          output_matches: result.choice == row["expected"] and result.acked == expected_ack,
          passed:
            result.choice == row["expected"] and result.acked == expected_ack and
              Map.get(result, :decisions, []) != [],
          ms: System.monotonic_time(:millisecond) - t
        })
      end)
    after
      Host.object_unload(id)
    end
  end

  defp await(id, row, cfg, state, deadline) do
    cond do
      length(state.calls) >= 32 -> Map.put(state, :choice, "call_budget")
      System.monotonic_time(:millisecond) >= deadline -> Map.put(state, :choice, "timeout")
      true -> receive_next(id, row, cfg, state, deadline)
    end
  end

  defp receive_next(id, row, cfg, state, deadline) do
    receive do
      {:script_host_call, ^id, rpc, cap, args} ->
        {reply, next} = call(cap, args, row, cfg, state)
        Host.host_reply(rpc, reply)
        done = next.acked or next.choice == "defer"

        if done,
          do: drain(id, row, cfg, next, deadline),
          else: await(id, row, cfg, next, deadline)

      {:script_terminal, ^id, status} ->
        Map.merge(state, %{choice: state.choice || "runtime_exit", terminal: status})

      _ ->
        await(id, row, cfg, state, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Map.put(state, :choice, state.choice || "timeout")
    end
  end

  # Observe an ACK after defer too; the guest must not falsely settle unknown evidence.
  defp drain(id, row, cfg, state, deadline) do
    cond do
      length(state.calls) >= 32 -> Map.put(state, :choice, "call_budget")
      System.monotonic_time(:millisecond) >= deadline -> Map.put(state, :choice, "timeout")
      true -> drain_next(id, row, cfg, state, deadline)
    end
  end

  defp drain_next(id, row, cfg, state, deadline) do
    receive do
      {:script_host_call, ^id, rpc, cap, args} ->
        {reply, next} = call(cap, args, row, cfg, state)
        Host.host_reply(rpc, reply)
        drain(id, row, cfg, next, deadline)

      {:script_terminal, ^id, status} ->
        Map.put(state, :terminal, status)
    after
      50 -> state
    end
  end

  defp call(cap, args, row, cfg, state) do
    state = Map.update!(state, :calls, &(&1 ++ [cap]))

    case cap do
      "proactive.mail_read" ->
        if args["message_id"] == row["name"],
          do:
            {{:ok, %{"tool" => cap, "error" => false, "content" => Jason.encode!(row["input"])}},
             state},
          else: {{:error, "wrong message identity"}, state}

      "decide" ->
        dc = Map.new(cfg["decide"], fn {k, v} -> {String.to_existing_atom(k), v} end)

        result =
          case (cfg[:decide_fun] || fn a -> SalixAgent.Decide.Provider.request(a, dc) end).(args) do
            {:ok, a, _} -> a
            _ -> %{"error" => %{"code" => "unavailable"}}
          end

        {{:ok, %{"tool" => cap, "error" => false, "content" => Jason.encode!(result)}},
         Map.update!(state, :decisions, &(&1 ++ [%{input: args, result: result}]))}

      "agent.notify" ->
        notify(args, row, cfg, state)

      "loop.state.put" ->
        choice = get_in(args, ["state", "choice"])

        if get_in(args, ["state", "event_id"]) == "event-" <> row["name"] and
             choice in ~w(quiet defer),
           do: {{:ok, %{"status" => "stored"}}, Map.put(state, :choice, choice)},
           else: {{:error, "invalid diagnostic checkpoint"}, state}

      "loop.ack" ->
        if args["event_id"] == "event-" <> row["name"],
          do:
            {{:ok, %{"status" => "acked", "event_id" => args["event_id"]}},
             Map.put(state, :acked, true)},
          else: {{:error, "wrong event identity"}, state}

      _ ->
        {{:ok, %{}}, state}
    end
  end

  defp notify(args, row, cfg, state) do
    expected_input = row["input"]

    with true <- args["dedup_key"] == "event-" <> row["name"],
         {:ok, ^expected_input} <- Jason.decode(args["content"] || "") do
      if state.notify_count > 0 do
        {{:ok, %{"status" => "duplicate"}}, state}
      else
        router =
          (cfg[:router_fun] || fn input -> CompareMail.router(input, cfg["llm"]) end).(
            expected_input
          )

        if router.choice in ~w(notify quiet defer) do
          {{:ok, %{"status" => "queued"}},
           Map.merge(state, %{choice: router.choice, router: router, notify_count: 1})}
        else
          {{:error, "router model failed"}, Map.put(state, :router, router)}
        end
      end
    else
      _ -> {{:error, "notification identity or evidence mismatch"}, state}
    end
  end
end
