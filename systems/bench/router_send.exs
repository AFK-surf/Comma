# MIX_ENV=test mix run bench/router_send.exs
# A resident Router with about 400,000 estimated tokens of history sends a real visible Message
# while a participant status read waits five seconds. This injects a slow reader
# to reproduce mailbox contention; it does not measure staging storage latency.
# PROBE_STATUS_DELAY_MS=0 isolates the send without concurrent status traffic.
# PROBE_STATUS_BURST=30 replaces the held read with queued activity invalidations.
defmodule RouterSendProbe do
  alias SalixStore.{Ids, Keys}

  def stamp(kind, data \\ nil) do
    if config = :persistent_term.get(__MODULE__, nil) do
      send(config.owner, {:probe, kind, System.system_time(:microsecond), data})
    end

    :ok
  end

  def run do
    Logger.configure(level: :warning)
    SalixStore.RepoTestSetup.ensure!()
    SalixAgent.TestSupport.stop_all_agents()
    SalixIM.TestSupport.Fleet.stop_all!()
    SalixStore.S3.Fake.start_link([])
    SalixStore.S3.Fake.reset()
    Application.put_env(:salix_store, :s3_backend, RouterSendProbe.Storage)
    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)
    Application.put_env(:salix_im, :session_activity_mod, RouterSendProbe.Status)
    Application.put_env(:salix_agent, :conversation_source_mod, SalixIM.ConversationSource)
    Application.put_env(:salix_agent, :llm, RouterSendProbe.Provider)
    Application.put_env(:salix_agent, :im_provider_mod, SalixIM.Provider)

    :telemetry.attach(
      :send_probe,
      [:salix, :operation, :stop],
      fn _, m, meta, _ ->
        if String.starts_with?(to_string(meta[:operation]), "im_send"),
          do:
            stamp(
              :send_stage,
              {meta[:operation],
               System.convert_time_unit(m.duration, :native, :microsecond) / 1000}
            )
      end,
      nil
    )

    Application.put_env(:salix_agent, :agent_observability_mod, RouterSendProbe.Observer)
    count = String.to_integer(System.get_env("PROBE_SAMPLES", "5"))
    delay = String.to_integer(System.get_env("PROBE_STORAGE_DELAY_MS", "40"))

    samples =
      for index <- 0..count do
        :persistent_term.erase(__MODULE__)
        tenant = Ids.new_tenant_id()
        group = Ids.new_group_id(tenant)
        SalixAgent.TestSupport.create_control_group!(group)

        router =
          SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
            "name" => "Timing Router",
            "role" => "router",
            "context_tokens" => 1_000_000
          })

        agent = router["agent_id"]
        session = router["router_session_id"]

        {:ok, _} =
          SalixStore.CasRecord.update(
            Keys.ctl_group(group),
            &Map.put(&1, "router_agent_id", agent)
          )

        {:ok, conversation} = SalixIM.RouterConversationInput.ensure(group)
        {:ok, _} = SalixAgent.InternalSessionStore.prepare_create(agent, session)

        size = String.to_integer(System.get_env("PROBE_HISTORY_MESSAGES", "400"))

        if size > 0 do
          {:ok, state} = SalixAgent.InternalSessionStore.read(agent, session)
          data = SalixAgent.InternalSession.export(state)

          messages =
            for n <- 1..size,
                do: %{
                  id: n,
                  seq: n,
                  role: "user",
                  content:
                    String.duplicate(
                      "abc ",
                      String.to_integer(System.get_env("PROBE_WORDS_PER_MESSAGE", "1000"))
                    ),
                  created_at: System.system_time(:second)
                }

          data =
            Map.merge(data, %{
              messages: messages,
              last_seq: size,
              next_message_id: size + 1,
              last_ack_message_id: size,
              live_context_bytes: Enum.sum(Enum.map(messages, &byte_size(&1.content)))
            })

          key = Keys.agent_internal_runtime_session(agent, session)
          {:ok, _} = SalixStore.S3.put(key, SalixStore.Codec.encode_session_snapshot(data))
        end

        :persistent_term.put(
          {RouterSendProbe.Provider, :conversation},
          conversation["conversation_id"]
        )

        :persistent_term.put(
          {RouterSendProbe.Provider, :participant},
          {group, conversation["conversation_id"], conversation["router_participant_id"]}
        )

        {:ok, actor} =
          SalixAgent.InternalSessionFleet.ensure_started(agent, session, process_on_init: false)

        {:ok, revision} = SalixAgent.InternalSessionStore.read_revision(agent, session)
        :sys.replace_state(actor, fn state -> %{state | revision: revision} end)

        if System.get_env("PROBE_CONFIG", "warm") in ["warm", "changed"] do
          {:ok, snapshot} = SalixAgent.RoundConfig.build_round_snapshot(agent)

          :sys.replace_state(actor, fn state ->
            %{
              state
              | round_config_cache: %SalixAgent.RoundConfigCache{
                  current: snapshot,
                  built_at_ms: System.monotonic_time(:millisecond)
                }
            }
          end)
        end

        if String.to_integer(System.get_env("PROBE_STATUS_BURST", "0")) > 0 do
          {:ok, %{"owner_pid" => participant_pid}} =
            SalixIM.ConversationServer.subscribe_group_conversation_participant(
              group,
              conversation["conversation_id"],
              conversation["router_participant_id"],
              self()
            )

          :persistent_term.put(
            {RouterSendProbe.Status, :participant},
            {participant_pid, agent, session}
          )
        end

        history_tokens = SalixAgent.Compaction.context_tokens_used(revision.state)
        drain([])
        :persistent_term.put({RouterSendProbe.Provider, :step}, 0)
        :persistent_term.put(__MODULE__, %{owner: self(), delay: delay})
        stamp(:append)

        {:ok, _} =
          SalixIM.RouterConversationInput.append_user_message(group, %{
            "content" => [%{"type" => "text", "text" => "搜一下今天上海天气"}]
          })

        events = await_continuation([])
        :sys.get_state(actor)
        # A fast send may finish while the independent status reader still waits.
        # Join it before removing the fixture, outside the measured interval.
        case :persistent_term.get({RouterSendProbe.Status, :task}, nil) do
          pid when is_pid(pid) ->
            ref = Process.monitor(pid)

            receive do
              {:DOWN, ^ref, :process, ^pid, _} -> :ok
            after
              15_000 -> raise "status reader did not finish"
            end

          nil ->
            :ok
        end

        if String.to_integer(System.get_env("PROBE_STATUS_BURST", "0")) > 0 do
          {participant_pid, _, _} = :persistent_term.get({RouterSendProbe.Status, :participant})
          :sys.get_state(participant_pid)
        end

        events = drain(events)
        :persistent_term.erase(__MODULE__)

        sample =
          summarize(events, agent, session, conversation)
          |> Map.put(:history_tokens, history_tokens)

        IO.puts(Jason.encode!(%{sample: index, measurements: sample}))
        SalixAgent.TestSupport.stop_all_agents()
        SalixIM.TestSupport.Fleet.stop_all!()
        if index > 0, do: sample
      end
      |> Enum.reject(&is_nil/1)

    summary =
      Map.new(Map.keys(hd(samples).intervals_ms), fn key ->
        values = Enum.map(samples, & &1.intervals_ms[key]) |> Enum.sort()
        {key, %{p50: percentile(values, 0.5), p95: percentile(values, 0.95)}}
      end)

    IO.puts(
      Jason.encode!(%{
        summary: summary,
        samples: count,
        storage_delay_ms: delay,
        provider_delay_ms: 100,
        history_messages: String.to_integer(System.get_env("PROBE_HISTORY_MESSAGES", "400")),
        words_per_message: String.to_integer(System.get_env("PROBE_WORDS_PER_MESSAGE", "1000")),
        status_delay_ms:
          if(String.to_integer(System.get_env("PROBE_STATUS_BURST", "0")) > 0,
            do: 0,
            else: String.to_integer(System.get_env("PROBE_STATUS_DELAY_MS", "5000"))
          ),
        status_burst: String.to_integer(System.get_env("PROBE_STATUS_BURST", "0")),
        config: System.get_env("PROBE_CONFIG", "warm")
      })
    )
  end

  defp percentile(values, p), do: Enum.at(values, ceil(length(values) * p) - 1)

  defp await_continuation(events) do
    receive do
      {:probe, :provider_dispatch, _, 2} = event -> [event | events]
      event -> await_continuation([event | events])
    after
      120_000 -> raise "send workload did not reach continuation"
    end
  end

  defp drain(events) do
    receive do
      event -> drain([event | events])
    after
      0 -> events
    end
  end

  defp summarize(events, agent, session, conversation) do
    times = for {:probe, :provider_dispatch, t, n} <- events, into: %{}, do: {n, t}
    [complete] = for {:probe, :provider_complete, t, 1} <- events, do: t

    stages =
      Map.new(for {:probe, :send_stage, _, {name, duration}} <- events, do: {name, duration})

    true = Map.has_key?(stages, "im_send_total")

    {:ok, messages} =
      SalixIM.Conversations.list_group_conversation_messages(
        conversation["agent_group_id"],
        conversation["conversation_id"]
      )

    true =
      Enum.any?(messages, fn message ->
        message["actor_type"] == "agent" && inspect(message["content"]) =~ "The answer is ready."
      end)

    %{
      intervals_ms: Map.put(stages, "response_to_continuation", (times[2] - complete) / 1000),
      phases:
        for({:probe, :phase, _, fact} <- events, do: Map.take(fact, [:phase, :duration_ms])),
      status_call_ms: List.first(for {:probe, :status_call, _, ms} <- events, do: ms),
      status_reads: length(for {:probe, :status_read, _, _} <- events, do: :read),
      session_reads:
        Enum.count(events, fn
          {:probe, :storage, _, {:get, key, _}} ->
            key == Keys.agent_internal_runtime_session(agent, session)

          _ ->
            false
        end)
    }
  end
end

defmodule RouterSendProbe.Storage do
  for {operation, arity} <- [
        get: 2,
        put: 3,
        head: 1,
        delete: 2,
        list: 2,
        put_stream: 3,
        stream: 2,
        multipart_create: 2,
        multipart_upload_part: 4,
        multipart_complete: 3,
        multipart_abort: 2,
        multipart_uploads: 2
      ] do
    args = Macro.generate_arguments(arity, __MODULE__)

    def unquote(operation)(unquote_splicing(args)) do
      started = System.system_time(:microsecond)
      if config = :persistent_term.get(RouterSendProbe, nil), do: Process.sleep(config.delay)

      result = apply(SalixStore.S3.Fake, unquote(operation), [unquote_splicing(args)])

      RouterSendProbe.stamp(
        :storage,
        {unquote(operation), hd([unquote_splicing(args)]), started}
      )

      result
    end
  end
end

defmodule RouterSendProbe.Provider do
  def complete(messages, tools), do: complete_stream(messages, tools, fn _ -> :ok end)

  def complete_stream(_messages, _, _) do
    step = :persistent_term.get({__MODULE__, :step}) + 1
    :persistent_term.put({__MODULE__, :step}, step)
    RouterSendProbe.stamp(:provider_dispatch, step)

    if step == 1 do
      Process.sleep(100)
      delay = String.to_integer(System.get_env("PROBE_STATUS_DELAY_MS", "5000"))

      burst = String.to_integer(System.get_env("PROBE_STATUS_BURST", "0"))

      if delay > 0 or burst > 0 do
        if burst > 0 do
          {pid, agent, session} = :persistent_term.get({RouterSendProbe.Status, :participant})
          for _ <- 1..burst, do: send(pid, {:session_activity_updated, agent, session})
        else
          :persistent_term.put({RouterSendProbe.Status, :block}, {self(), delay})
        end

        {group, conversation, participant} = :persistent_term.get({__MODULE__, :participant})

        {:ok, task} =
          Task.start(fn ->
            started = System.monotonic_time(:microsecond)

            {:ok, _} =
              SalixIM.ConversationServer.get_group_conversation_participant_status(
                group,
                conversation,
                participant
              )

            RouterSendProbe.stamp(
              :status_call,
              (System.monotonic_time(:microsecond) - started) / 1000
            )
          end)

        :persistent_term.put({RouterSendProbe.Status, :task}, task)

        if burst == 0 do
          receive do
            :status_read_started -> :ok
          after
            10_000 -> raise "status read did not start"
          end
        end
      end

      RouterSendProbe.stamp(:provider_complete, step)

      {:assistant, "",
       [
         %{
           id: "visible-send",
           name: "call",
           args: %{
             "reply_mode" => "progress",
             "tool" => "im_api.internal.send_message",
             "params" => %{
               "connect_id" => "internal",
               "conversation_id" => :persistent_term.get({__MODULE__, :conversation}),
               "content" => [%{"type" => "text", "text" => "The answer is ready."}]
             }
           }
         }
       ]}
    else
      receive do
        :finish -> {:error, :probe_finished}
      after
        60_000 -> {:error, :probe_timeout}
      end
    end
  end
end

defmodule RouterSendProbe.Observer do
  def round_phase(fact) do
    if System.get_env("PROBE_PROFILE") == "true",
      do:
        RouterSendProbe.stamp(
          :queue,
          {fact.phase, inspect(Process.info(self(), :messages), limit: :infinity)}
        )

    RouterSendProbe.stamp(:phase, fact)
  end

  def agent_run(_), do: :ok
  def tool_call(_), do: :ok
end

defmodule RouterSendProbe.Status do
  def get(agent, session) do
    case :persistent_term.get({__MODULE__, :block}, nil) do
      {owner, delay} ->
        :persistent_term.erase({__MODULE__, :block})
        send(owner, :status_read_started)
        Process.sleep(delay)

      nil ->
        :ok
    end

    result = SalixIM.TestSupport.SessionActivity.get(agent, session)
    RouterSendProbe.stamp(:status_read)
    result
  end

  def subscribe(_, _), do: :ok
  def unsubscribe(_, _), do: :ok
end

RouterSendProbe.run()
