# MIX_ENV=test mix run bench/router_ingress.exs
# Deterministic Shanghai-weather workload through the real Conversation, Session,
# tool, authorization, and storage adapters. Only provider HTTP and S3 latency
# are controlled. This does not reproduce historical staging infrastructure.
defmodule SessionHotPathProbe do
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
    Application.put_env(:salix_store, :s3_backend, SessionHotPathProbe.Storage)
    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)
    Application.put_env(:salix_im, :session_activity_mod, SalixIM.TestSupport.SessionActivity)
    Application.put_env(:salix_agent, :conversation_source_mod, SalixIM.ConversationSource)
    Application.put_env(:salix_agent, :llm, SessionHotPathProbe.Provider)
    Application.put_env(:salix_agent, :agent_observability_mod, SessionHotPathProbe.Observer)
    Application.put_env(:salix_agent, :exa_api_key, "local-probe-not-a-credential")
    Req.Test.set_req_test_to_shared()

    Req.Test.stub(__MODULE__, fn conn ->
      true = conn.host == "api.exa.ai"
      stamp(:read_dispatch)
      Process.sleep(100)
      stamp(:read_complete)

      Req.Test.json(conn, %{
        "results" => [
          %{
            "title" => "Shanghai weather fixture",
            "url" => "https://weather.example.test",
            "text" => "上海今天多云，25°C。"
          }
        ]
      })
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    for {mod, fun, arity} <- [
          {SalixAgent.ConversationConsumer, :consume, 4},
          {SalixAgent.RoundConfig, :build_round_snapshot, 2},
          {SalixAgent.RoundConfig, :refresh_round_snapshot, 3},
          {SalixAgent.RoundConfig, :materialize_round_snapshot, 3}
        ] do
      Code.ensure_loaded!(mod)
      :erlang.trace_pattern({mod, fun, arity}, [{:_, [], [{:return_trace}]}], [:local])
    end

    :erlang.trace(:all, true, [:call, :monotonic_timestamp, {:tracer, self()}])

    count = String.to_integer(System.get_env("PROBE_SAMPLES", "20"))
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
            "role" => "router"
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

        {:ok, actor} =
          SalixAgent.InternalSessionFleet.ensure_started(agent, session, process_on_init: true)

        %{revision: %SalixAgent.InternalSessionStore.Revision{}} = :sys.get_state(actor)

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

        if System.get_env("PROBE_CONFIG") == "cold" do
          :sys.replace_state(actor, fn state ->
            %{
              state
              | round_config_cache:
                  SalixAgent.RoundConfigCache.invalidate(state.round_config_cache)
            }
          end)
        end

        if System.get_env("PROBE_CONFIG") == "changed" do
          {:ok, _} =
            SalixStore.CasRecord.update(
              Keys.ctl_agent(agent),
              &Map.put(&1, "purpose", "Weather research")
            )
        end

        drain([])
        :persistent_term.put({SessionHotPathProbe.Provider, :step}, 0)
        :persistent_term.put(__MODULE__, %{owner: self(), delay: delay})
        stamp(:append)

        {:ok, _} =
          SalixIM.RouterConversationInput.append_user_message(group, %{
            "content" => [%{"type" => "text", "text" => "搜一下今天上海天气"}]
          })

        events = await_continuation([])
        :sys.get_state(actor)
        events = drain(events)
        :persistent_term.erase(__MODULE__)
        sample = summarize(events, agent, session, conversation)
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
        search_delay_ms: 100,
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
      20_000 -> raise "weather workload did not reach continuation"
    end
  end

  defp drain(events) do
    receive do
      event -> drain([event | events])
    after
      0 -> events
    end
  end

  defp summarize(events, agent, session, _conversation) do
    phase =
      events
      |> Enum.flat_map(fn
        {:probe, :phase, _, %{phase: "activation"} = fact} -> [fact]
        _ -> []
      end)
      |> Enum.min_by(&DateTime.to_unix(&1.started_at, :microsecond))

    processing = DateTime.to_unix(phase.started_at, :microsecond)
    round = processing + phase.duration_ms * 1000

    times =
      Map.new([:append, :read_dispatch, :read_complete], fn kind ->
        {kind,
         events
         |> Enum.flat_map(fn
           {:probe, ^kind, t, _} -> [t]
           _ -> []
         end)
         |> Enum.min()}
      end)

    provider = for {:probe, :provider_dispatch, t, step} <- events, into: %{}, do: {step, t}
    response = for {:probe, :provider_complete, t, 1} <- events, do: t

    ingress =
      events
      |> Enum.flat_map(fn
        {:trace_ts, _, :call, {SalixAgent.ConversationConsumer, :consume, _}, t} -> [system_us(t)]
        _ -> []
      end)
      |> Enum.min()

    bounds = %{
      "append_to_consumer" => {times.append, ingress},
      "ingress_to_processing" => {ingress, processing},
      "processing_to_round" => {processing, round},
      "round_to_provider" => {round, provider[1]},
      "processing_to_provider" => {processing, provider[1]},
      "model_response_to_read" => {hd(response), times.read_dispatch},
      "read_result_to_continuation" => {times.read_complete, provider[2]},
      "append_to_continuation" => {times.append, provider[2]},
      "ingress_to_continuation" => {ingress, provider[2]}
    }

    storage =
      for {:probe, :storage, finished, {op, key, started}} <- events,
          do: {op, key, started, finished}

    operations =
      Map.new(bounds, fn {name, {first, last}} ->
        requests = Enum.filter(storage, fn {_, _, at, _} -> at >= first and at <= last end)

        {name,
         %{
           reads: Enum.count(requests, &(elem(&1, 0) in [:get, :head, :list])),
           writes: Enum.count(requests, &(elem(&1, 0) in [:put, :put_stream]))
         }}
      end)

    %{
      intervals_ms:
        Map.new(bounds, fn {name, {first, last}} ->
          {name, Float.round((last - first) / 1000, 3)}
        end),
      storage_starts_by_interval: operations,
      profile:
        for(
          {:probe, :storage_stack, _, {op, key, started, stack}} <- events,
          do: %{
            op: op,
            key: key,
            at_ms: Float.round((started - times.append) / 1000, 3),
            stack: stack
          }
        ),
      configuration: configuration_spans(events, times.append, provider[2]),
      queues:
        for(
          {:probe, :queue, at, data} <- events,
          do: %{at_ms: (at - times.append) / 1000, data: inspect(data)}
        ),
      session_writes:
        Enum.count(storage, fn {op, key, _, _} ->
          op == :put and key == Keys.agent_internal_runtime_session(agent, session)
        end),
      workspace_writes:
        Enum.count(storage, fn {op, key, _, _} ->
          op == :put and key == Keys.agent_workspace_state(agent)
        end)
    }
  end

  defp configuration_spans(events, first, last) do
    {_pending, spans} =
      events
      |> Enum.reverse()
      |> Enum.reduce({%{}, []}, fn
        {:trace_ts, pid, :call, {SalixAgent.RoundConfig, fun, _}, at}, {pending, spans} ->
          {Map.put(pending, {pid, fun}, system_us(at)), spans}

        {:trace_ts, pid, :return_from, {SalixAgent.RoundConfig, fun, _}, _, at},
        {pending, spans} ->
          {started, pending} = Map.pop(pending, {pid, fun})
          finished = system_us(at)

          if started && started >= first && finished <= last do
            {pending,
             [%{stage: fun, duration_ms: Float.round((finished - started) / 1000, 3)} | spans]}
          else
            {pending, spans}
          end

        _, acc ->
          acc
      end)

    Enum.reverse(spans)
  end

  defp system_us(native),
    do:
      System.system_time(:microsecond) - System.monotonic_time(:microsecond) +
        System.convert_time_unit(native, :native, :microsecond)
end

defmodule SessionHotPathProbe.Storage do
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
      if config = :persistent_term.get(SessionHotPathProbe, nil), do: Process.sleep(config.delay)

      if System.get_env("PROBE_PROFILE") == "true" do
        SessionHotPathProbe.stamp(
          :storage_stack,
          {unquote(operation), hd([unquote_splicing(args)]), started,
           inspect(Process.info(self(), :current_stacktrace), limit: :infinity)}
        )
      end

      result = apply(SalixStore.S3.Fake, unquote(operation), [unquote_splicing(args)])

      SessionHotPathProbe.stamp(
        :storage,
        {unquote(operation), hd([unquote_splicing(args)]), started}
      )

      result
    end
  end
end

defmodule SessionHotPathProbe.Provider do
  def complete(messages, tools), do: complete_stream(messages, tools, fn _ -> :ok end)

  def complete_stream(_, _, _) do
    step = :persistent_term.get({__MODULE__, :step}) + 1
    :persistent_term.put({__MODULE__, :step}, step)
    SessionHotPathProbe.stamp(:provider_dispatch, step)

    if step == 1 do
      Process.sleep(100)
      SessionHotPathProbe.stamp(:provider_complete, step)

      {:assistant, "",
       [
         %{
           id: "weather-search",
           name: "call",
           args: %{"tool" => "web.search", "params" => %{"query" => "今天上海天气"}}
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

defmodule SessionHotPathProbe.Observer do
  def round_phase(fact) do
    if System.get_env("PROBE_PROFILE") == "true",
      do:
        SessionHotPathProbe.stamp(
          :queue,
          {fact.phase, inspect(Process.info(self(), :messages), limit: :infinity)}
        )

    SessionHotPathProbe.stamp(:phase, fact)
  end

  def agent_run(_), do: :ok
  def tool_call(_), do: :ok
end

SessionHotPathProbe.run()
