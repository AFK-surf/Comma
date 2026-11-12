defmodule SalixIM.MentionReplyLatencyTest do
  use SystemsClock.Case, async: false

  alias SalixIM.MentionReplyLatency, as: Latency

  @connect %{"connect_id" => "con_1"}
  @now 1_800_000_000_000
  @retention 3_600_000

  defmodule Forward do
    require SystemsRuntime.Proc

    def event(name, measurements, metadata, owner),
      do: SystemsRuntime.Proc.send(owner, {name, measurements, metadata})
  end

  setup context do
    handler = context.test

    SystemsRuntime.Telemetry.attach_many(
      handler,
      for(
        event <- [:mention, :reply, :no_reply, :invalid, :pending, :observation, :observed],
        do: [:salix, :agent_message, event]
      ),
      &Forward.event/4,
      SystemsRuntime.Proc.self()
    )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)
    time = :atomics.new(1, [])
    :atomics.put(time, 1, @now - @retention)
    %{time: time}
  end

  # The tracker of a release with no `window/1` and no clause for a cast it
  # does not know.
  defmodule OldTracker do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, name, name: name)
    @impl true
    def init(name), do: {:ok, name}
    @impl true
    def handle_cast({:copy_to, _peer}, name), do: {:noreply, name}
    def handle_cast({:observed, _entry}, name), do: {:noreply, name}
    def handle_cast({:gap, _provider, _at}, name), do: {:noreply, name}
  end

  defp start(id, time, peers \\ fn -> [] end, live \\ nil, opts \\ []) do
    live = live || fn -> [id] end

    start_supervised!(
      Supervisor.child_spec(
        {Latency,
         name: id,
         id: id,
         peers: peers,
         live: live,
         interval: 86_400_000,
         clock: fn -> :atomics.get(time, 1) end,
         capacity: Keyword.get(opts, :capacity, 64),
         pull: Keyword.get(opts, :pull, &window_of/1)},
        id: id
      )
    )

    id
  end

  defp window_of(peer) do
    Latency.window(peer)
  catch
    :exit, _ -> nil
  end

  # A pod that has run for the whole retention window has seen every mention
  # that can still be pending. Pods start a window before @now.
  defp complete(server, time) do
    :atomics.put(time, 1, @now)
    Latency.sample(server)
    flush()
    server
  end

  defp flush do
    receive do
      {[:salix, :agent_message, _], _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp slack_mention(source \\ "source-1", overrides \\ %{}) do
    Map.merge(
      %{
        provider: "slack",
        connect_id: "con_1",
        source_message_id: source,
        place: "C1",
        thread: ["1.000000"],
        source_sent_at_ms: @now - 10_000
      },
      overrides
    )
  end

  # A send from an activation that holds `sources`.
  defp reply(server, overrides \\ %{}, sources \\ ["source-1"]) do
    Process.put(:salix_im_provider_tool_context, %{"source_message_ids" => sources})

    Latency.reply(
      "slack",
      @connect,
      Map.merge(%{place: "C1", thread: ["1.000000"], at_ms: @now}, overrides),
      server
    )

    Process.delete(:salix_im_provider_tool_context)
  end

  # What a pod casts on for a confirmed Slack reply in the mention's thread.
  defp reply_at(server) do
    place = :sys.get_state(server).pending |> Map.values() |> hd()

    %{
      provider: "slack",
      scope: place.scope,
      thread: place.thread,
      parent: [],
      sources: [place.key],
      card: nil,
      at_ms: @now
    }
  end

  defp flush_gauges do
    receive do
      {[:salix, :agent_message, name], _, _} when name in [:pending, :observation, :observed] ->
        flush_gauges()
    after
      0 -> :ok
    end
  end

  defp gauges(server) do
    flush_gauges()
    Latency.sample(server)

    for provider <- Latency.providers(), into: %{} do
      assert_received {[:salix, :agent_message, :observation], %{coverage: coverage},
                       %{provider: ^provider}}

      age =
        receive do
          {[:salix, :agent_message, :pending], %{oldest_age: age}, %{provider: ^provider}} -> age
        after
          0 -> nil
        end

      {provider, {coverage, age}}
    end
  end

  test "a reply records the source-to-reply latency once, for the first reply only", %{time: time} do
    server = start(:complete_path, time) |> complete(time)

    Latency.mention(slack_mention(), server)
    reply(server)
    reply(server, %{at_ms: @now + 5_000})

    assert gauges(server)["slack"] == {1, 0}
    assert_received {[:salix, :agent_message, :mention], %{count: 1}, %{provider: "slack"}}
    assert_received {[:salix, :agent_message, :reply], %{latency: 10_000}, %{provider: "slack"}}
    refute_received {[:salix, :agent_message, :reply], _, _}
  end

  test "a duplicate mention counts once and cannot reopen an answered one", %{time: time} do
    server = start(:duplicates, time) |> complete(time)

    Latency.mention(slack_mention(), server)
    Latency.mention(slack_mention(), server)
    reply(server)
    Latency.mention(slack_mention(), server)

    assert gauges(server)["slack"] == {1, 0}
    assert_received {[:salix, :agent_message, :mention], _, _}
    refute_received {[:salix, :agent_message, :mention], _, _}
  end

  test "an unanswered mention ages, and a reply elsewhere does not answer it", %{time: time} do
    server = start(:unanswered, time) |> complete(time)

    Latency.mention(slack_mention(), server)
    reply(server, %{thread: ["2.000000"]})
    reply(server, %{place: "C2"})
    reply(server, %{at_ms: @now - 20_000})

    Process.put(:salix_im_provider_tool_context, %{"source_message_id" => "source-1"})

    Latency.reply(
      "slack",
      %{"connect_id" => "con_2"},
      %{place: "C1", thread: ["1.000000"], at_ms: @now},
      server
    )

    Process.delete(:salix_im_provider_tool_context)

    assert gauges(server)["slack"] == {1, 10_000}
    refute_received {[:salix, :agent_message, :reply], _, _}
  end

  test "a deliberate no-reply closes its mention with no sample and no gap", %{time: time} do
    server = start(:no_reply, time) |> complete(time)

    Latency.mention(slack_mention(), server)
    Latency.no_reply(["source-1:redelivery:2", nil], server)
    reply(server)

    assert gauges(server)["slack"] == {1, 0}
    assert_received {[:salix, :agent_message, :no_reply], %{count: 1}, %{provider: "slack"}}
    refute_received {[:salix, :agent_message, :reply], _, _}

    :atomics.add(time, 1, @retention + 1)
    SystemsRuntime.Server.call(server, :sample)
    refute_received {[:salix, :agent_message, :invalid], _, _}
  end

  test "a no-reply of another source leaves the mention pending", %{time: time} do
    server = start(:other_no_reply, time) |> complete(time)

    Latency.mention(slack_mention(), server)
    Latency.no_reply(["source-2"], server)

    assert gauges(server)["slack"] == {1, 10_000}
    refute_received {[:salix, :agent_message, :no_reply], _, _}
  end

  test "another turn's reply in the same thread answers nothing", %{time: time} do
    server = start(:previous_turn, time) |> complete(time)

    Latency.mention(slack_mention(), server)
    reply(server, %{}, ["earlier-turn"])

    assert gauges(server)["slack"] == {1, 10_000}
    refute_received {[:salix, :agent_message, :reply], _, _}
    refute_received {[:salix, :agent_message, :invalid], _, _}
  end

  test "a message in the thread with no evidence is uncertain, once, and retains the mention",
       %{time: time} do
    server = start(:uncertain, time) |> complete(time)

    Latency.mention(slack_mention(), server)
    reply(server, %{}, [])
    reply(server, %{}, [])

    assert gauges(server)["slack"] == {1, 10_000}
    assert_received {[:salix, :agent_message, :invalid], _, %{reason: :uncertain_correlation}}
    refute_received {[:salix, :agent_message, :invalid], _, _}
    refute_received {[:salix, :agent_message, :reply], _, _}
  end

  test "coalesced mentions are answered one by one, by the reply in each thread", %{time: time} do
    server = start(:coalesced, time) |> complete(time)
    activation = ["first", "second", "third"]

    Latency.mention(slack_mention("first"), server)
    Latency.mention(slack_mention("second", %{source_sent_at_ms: @now - 5_000}), server)
    Latency.mention(slack_mention("third", %{thread: ["2.000000"]}), server)

    reply(server, %{}, activation)
    assert gauges(server)["slack"] == {1, 10_000}
    assert_received {[:salix, :agent_message, :reply], %{latency: 10_000}, _}
    assert_received {[:salix, :agent_message, :reply], %{latency: 5_000}, _}
    refute_received {[:salix, :agent_message, :reply], _, _}

    reply(server, %{thread: ["2.000000"], at_ms: @now + 1_000}, activation)
    assert gauges(server)["slack"] == {1, 0}
    assert_received {[:salix, :agent_message, :reply], %{latency: 11_000}, _}
  end

  test "a post outside any thread answers only a source of its activation", %{time: time} do
    server = start(:source, time) |> complete(time)
    Latency.mention(slack_mention("answered"), server)
    Latency.mention(slack_mention("other", %{thread: ["2.000000"]}), server)

    reply(server, %{thread: []}, ["answered"])

    assert gauges(server)["slack"] == {1, 10_000}
    assert_received {[:salix, :agent_message, :reply], %{latency: 10_000}, _}
    refute_received {[:salix, :agent_message, :reply], _, _}
  end

  test "the mention's Task card answers it without an activation at send time", %{time: time} do
    server = start(:card, time) |> complete(time)
    Latency.mention(slack_mention(), server)

    Process.put(:salix_im_provider_tool_context, %{"source_message_id" => "source-1"})
    Latency.card_requested("cnv1_task", server)
    Process.delete(:salix_im_provider_tool_context)

    Latency.with_card("cnv1_other", fn -> reply(server, %{}, []) end)
    assert gauges(server)["slack"] == {1, 10_000}

    Latency.with_card("cnv1_task", fn -> reply(server, %{}, []) end)
    assert gauges(server)["slack"] == {1, 0}
    assert_received {[:salix, :agent_message, :reply], %{latency: 10_000}, _}
  end

  test "a duplicate provider receipt records nothing more", %{time: time} do
    server = start(:receipts, time) |> complete(time)
    Latency.mention(slack_mention(), server)

    reply(server)
    reply(server)

    assert gauges(server)["slack"] == {1, 0}
    assert_received {[:salix, :agent_message, :reply], _, _}
    refute_received {[:salix, :agent_message, :reply], _, _}
    refute_received {[:salix, :agent_message, :invalid], _, _}
  end

  test "failed and unknown sends leave the mention pending", %{time: time} do
    server = start(:failed, time) |> complete(time)
    Latency.mention(slack_mention(), server)

    Latency.slack_reply(@connect, "1.000000", {:error, "channel_not_found"})
    Latency.slack_upload(@connect, "C1", "1.000000", {:error, :timeout})
    Latency.provider_post("feishu", @connect, "/im/v1/messages/om_1/reply", {:error, "timeout"})

    assert gauges(server)["slack"] == {1, 10_000}
  end

  test "reactions, pins and forwards are not replies" do
    message = %{"message_id" => "om_2", "chat_id" => "oc_1", "create_time" => "1"}

    for path <- ["/im/v1/messages/om_1/reactions", "/im/v1/pins", "/im/v1/messages/om_1/forward"] do
      assert :ok == Latency.provider_post("feishu", @connect, path, {:ok, message})
      refute_received {[:salix, :agent_message, _], _, _}
    end
  end

  test "Feishu and Lark replies match by the provider's receipt", %{time: time} do
    server = start(:feishu, time) |> complete(time)

    for provider <- ["feishu", "lark"] do
      Latency.mention(
        %{
          provider: provider,
          connect_id: "con_1",
          source_message_id: "#{provider}-source",
          place: "oc_1",
          message: "om_1",
          source_sent_at_ms: @now - 1_000
        },
        server
      )
    end

    Latency.reply("feishu", @connect, %{place: "oc_1", parent: "om_1", at_ms: @now}, server)

    assert %{"feishu" => {1, 0}, "lark" => {1, 1_000}, "slack" => {1, 0}} = gauges(server)
    assert_received {[:salix, :agent_message, :reply], %{latency: 1_000}, %{provider: "feishu"}}
  end

  test "a Lark reply in the thread answers the mention its activation holds", %{time: time} do
    server = start(:lark_thread, time) |> complete(time)

    Latency.mention(
      %{
        provider: "lark",
        connect_id: "con_1",
        source_message_id: "lark-mention",
        place: "oc_1",
        message: "om_mention",
        thread: ["om_root", "omt_1"],
        source_sent_at_ms: @now - 20_000
      },
      server
    )

    # The Router answers the mention under the next message of the same
    # activation: the call names only that source as its current one.
    Process.put(:salix_im_provider_tool_context, %{
      "source_message_id" => "lark-next",
      "source_message_ids" => ["lark-next"],
      "activation_source_message_ids" => ["lark-mention", "lark-next"]
    })

    Latency.reply(
      "lark",
      @connect,
      %{place: "oc_1", parent: "om_next", thread: ["om_root", "omt_1"], at_ms: @now},
      server
    )

    Process.delete(:salix_im_provider_tool_context)

    assert gauges(server)["lark"] == {1, 0}
    assert_received {[:salix, :agent_message, :reply], %{latency: 20_000}, %{provider: "lark"}}
  end

  test "a mention without a usable source time is rejected, not given zero", %{time: time} do
    server = start(:clock, time) |> complete(time)

    Latency.mention(slack_mention("missing", %{source_sent_at_ms: nil}), server)
    Latency.mention(slack_mention("future", %{source_sent_at_ms: @now + 600_000}), server)
    Latency.mention(slack_mention("negative", %{source_sent_at_ms: -1}), server)

    assert gauges(server) == %{"slack" => {0, nil}, "feishu" => {1, 0}, "lark" => {1, 0}}

    assert_received {[:salix, :agent_message, :invalid], _,
                     %{provider: "slack", reason: :missing_source_time}}

    for _ <- 1..2 do
      assert_received {[:salix, :agent_message, :invalid], _,
                       %{provider: "slack", reason: :invalid_clock}}
    end

    refute_received {[:salix, :agent_message, :reply], _, _}
  end

  test "a reply without receipt evidence settles the mention with no latency", %{time: time} do
    server = start(:receipt, time) |> complete(time)

    Latency.mention(slack_mention(), server)
    reply(server, %{at_ms: nil})

    assert gauges(server)["slack"] == {0, nil}

    assert_received {[:salix, :agent_message, :invalid], _,
                     %{provider: "slack", reason: :missing_receipt}}

    refute_received {[:salix, :agent_message, :reply], _, _}
  end

  test "a lost measurement keeps coverage at 0 for the whole retained hour", %{time: time} do
    server = start(:gap, time) |> complete(time)

    Latency.mention(slack_mention("future-reply"), server)
    reply(server, %{at_ms: @now + 600_000}, ["future-reply"])
    assert Latency.sample(server) == :ok
    assert_received {[:salix, :agent_message, :invalid], _, %{reason: :invalid_clock}}
    refute_received {[:salix, :agent_message, :reply], _, _}

    :atomics.add(time, 1, @retention - 1)
    assert gauges(server)["slack"] == {0, nil}
    refute_received {[:salix, :agent_message, :observed], _, %{provider: "slack"}}

    :atomics.add(time, 1, 1)
    assert gauges(server)["slack"] == {1, 0}
  end

  test "coverage stays 0 and no age is claimed until the observation is complete", %{time: time} do
    server = start(:idle, time)

    for provider <- Latency.providers() do
      assert_received {[:salix, :agent_message, :observation], %{coverage: 0},
                       %{provider: ^provider}}
    end

    assert gauges(server)["slack"] == {0, nil}
    refute_received {[:salix, :agent_message, :observed], _, _}

    :atomics.add(time, 1, @retention)
    assert gauges(server) == %{"slack" => {1, 0}, "feishu" => {1, 0}, "lark" => {1, 0}}
    expected = @now / 1_000
    assert_received {[:salix, :agent_message, :observed], %{observed_at: ^expected}, _}
  end

  test "an expired mention leaves the gauge and is counted", %{time: time} do
    server = start(:expiry, time) |> complete(time)
    Latency.mention(slack_mention(), server)
    assert gauges(server)["slack"] == {1, 10_000}

    :atomics.add(time, 1, @retention)
    assert gauges(server)["slack"] == {0, nil}

    assert_received {[:salix, :agent_message, :invalid], _,
                     %{provider: "slack", reason: :expired}}
  end

  describe "with two pods" do
    setup %{time: time} do
      live = fn -> [:pod_a, :pod_b] end
      start(:pod_a, time, fn -> [:pod_b] end, live) |> complete(time)
      start(:pod_b, time, fn -> [:pod_a] end, live)
      assert Latency.sample(:pod_a) == :ok
      flush()
      :ok
    end

    test "a reply on the other pod answers the mention and is recorded once" do
      Latency.mention(slack_mention(), :pod_a)
      assert Latency.sample(:pod_a) == :ok
      assert gauges(:pod_b)["slack"] == {1, 10_000}
      assert_received {[:salix, :agent_message, :mention], _, _}
      refute_received {[:salix, :agent_message, :mention], _, _}

      reply(:pod_b)
      reply(:pod_a)
      assert Latency.sample(:pod_b) == :ok
      assert gauges(:pod_a)["slack"] == {1, 0}
      assert gauges(:pod_b)["slack"] == {1, 0}

      assert_received {[:salix, :agent_message, :reply], %{latency: 10_000}, _}
      refute_received {[:salix, :agent_message, :reply], _, _}
    end

    test "a replica that sees the reply first settles on the first pod's word", %{time: time} do
      Latency.mention(slack_mention(), :pod_a)
      assert Latency.sample(:pod_a) == :ok
      keys = &SalixAgent.DeliveryTelemetry.source_key/1
      flush()

      replica =
        start(:replica, time, fn -> [] end, fn -> [:pod_a, :replica] end)

      entry = :sys.get_state(:pod_a).pending[keys.("source-1")]

      :ok = SystemsRuntime.Server.cast(replica, {:peer_reply, reply_at(:pod_a)})
      :ok = SystemsRuntime.Server.cast(replica, {:observed, entry})
      assert gauges(replica)["slack"] == {0, 10_000}

      :ok = SystemsRuntime.Server.cast(replica, {:settled, [{entry.key, entry.sent_at_ms}]})
      assert gauges(replica)["slack"] == {0, nil}
      refute_received {[:salix, :agent_message, :reply], _, _}
    end

    test "a mention left on a replica by its dead first pod ends as expired", %{time: time} do
      keys = &SalixAgent.DeliveryTelemetry.source_key/1
      survivor = start(:survivor_b, time, fn -> [] end, fn -> [:survivor_b] end) |> complete(time)

      :ok =
        SystemsRuntime.Server.cast(
          survivor,
          {:observed,
           %{
             key: keys.("lost-reply"),
             provider: "slack",
             scope: keys.("slack\ncon_1\nC1"),
             message: [],
             thread: [],
             cards: [],
             uncertain?: false,
             sent_at_ms: @now - 10_000,
             origin: :lost
           }}
        )

      :atomics.add(time, 1, @retention)
      assert gauges(survivor)["slack"] == {0, nil}
      assert_received {[:salix, :agent_message, :invalid], _, %{reason: :expired}}
    end

    test "a lost measurement opens the gap on every pod" do
      Latency.mention(slack_mention("no-time", %{source_sent_at_ms: nil}), :pod_a)
      assert Latency.sample(:pod_a) == :ok
      assert gauges(:pod_b)["slack"] == {0, nil}
    end

    test "a replica reports nothing while the mention's first pod lives" do
      Latency.mention(slack_mention("uncertain"), :pod_a)
      assert Latency.sample(:pod_a) == :ok
      assert Latency.sample(:pod_b) == :ok
      flush()

      reply(:pod_b, %{}, [])
      assert Latency.sample(:pod_b) == :ok
      assert Latency.sample(:pod_a) == :ok

      assert_received {[:salix, :agent_message, :invalid], _, _}
      refute_received {[:salix, :agent_message, :invalid], _, _}
    end
  end

  test "the lowest live pod reports for a pod that is gone", %{time: time} do
    server = start(:survivor, time) |> complete(time)
    source = "from-a-lost-pod"
    keys = &SalixAgent.DeliveryTelemetry.source_key/1

    :ok =
      SystemsRuntime.Server.cast(
        server,
        {:observed,
         %{
           key: keys.(source),
           provider: "slack",
           scope: keys.("slack\ncon_1\nC1"),
           message: [],
           thread: [],
           cards: [],
           uncertain?: false,
           sent_at_ms: @now - 10_000,
           origin: :lost
         }}
      )

    reply(server, %{thread: []}, [source])
    assert Latency.sample(server) == :ok
    assert_received {[:salix, :agent_message, :reply], %{latency: 10_000}, _}
  end

  test "a pod records nothing for a gone pod's mention when a lower pod lives", %{time: time} do
    live = fn -> [:pod_b, :pod_c] end
    server = start(:pod_c, time, fn -> [] end, live) |> complete(time)
    keys = &SalixAgent.DeliveryTelemetry.source_key/1

    :ok =
      SystemsRuntime.Server.cast(
        server,
        {:observed,
         %{
           key: keys.("from-a-lost-pod"),
           provider: "slack",
           scope: keys.("slack\ncon_1\nC1"),
           message: [],
           thread: [],
           cards: [],
           uncertain?: false,
           sent_at_ms: @now - 10_000,
           origin: :lost
         }}
      )

    reply(server, %{thread: []}, ["from-a-lost-pod"])
    assert gauges(server)["slack"] == {1, 0}
    refute_received {[:salix, :agent_message, :reply], _, _}
  end

  test "answered mentions cannot grow the table past its bound", %{time: time} do
    server = start(:capped, time, fn -> [] end, nil, capacity: 4) |> complete(time)

    for n <- 1..32 do
      Latency.mention(slack_mention("answered-#{n}"), server)
      reply(server, %{}, ["answered-#{n}"])
    end

    Latency.mention(slack_mention("pending"), server)
    assert %{answered: answered, pending: pending} = :sys.get_state(server)
    assert map_size(answered) + map_size(pending) <= 4
    assert map_size(pending) == 1
  end

  test "a copy from a peer cannot grow the table past its bound", %{time: time} do
    server = start(:copied, time, fn -> [] end, nil, capacity: 4) |> complete(time)
    keys = &SalixAgent.DeliveryTelemetry.source_key/1

    entry = fn n ->
      %{
        key: keys.("pending-#{n}"),
        provider: "slack",
        scope: keys.("slack\ncon_1\nC1"),
        message: [],
        thread: [],
        cards: [],
        uncertain?: false,
        sent_at_ms: @now - n,
        origin: :copied
      }
    end

    pending = Map.new(1..6, &{entry.(&1).key, entry.(&1)})
    answered = Map.new(1..6, &{keys.("answered-#{&1}"), @now})
    :ok = SystemsRuntime.Server.cast(server, {:copy, pending, answered, %{}})

    assert %{"slack" => {0, 6}} = gauges(server)
    assert %{answered: left, pending: kept} = :sys.get_state(server)
    assert map_size(left) + map_size(kept) == 4
    assert_received {[:salix, :agent_message, :invalid], _, %{reason: :overflow}}
  end

  test "a Worker's Conversation message answers the mention its activation holds", %{time: time} do
    server = start(:worker, time) |> complete(time)
    Latency.mention(slack_mention("thread-mention"), server)
    Latency.mention(slack_mention("another", %{thread: ["2.000000"]}), server)
    Latency.conversation_message("thread-mention", "msg1_in", server)
    Latency.conversation_message("another", "msg1_other", server)

    Process.put(:salix_im_provider_tool_context, %{
      "source_message_id" => "groupconv:cnv1_task:msg1_in:par1_worker"
    })

    Latency.message_sent("msg1_out", server)
    Process.delete(:salix_im_provider_tool_context)

    Latency.with_message("msg1_unrelated", fn -> reply(server, %{}, []) end)
    assert gauges(server)["slack"] == {1, 10_000}
    refute_received {[:salix, :agent_message, :reply], _, _}

    Latency.with_message("msg1_out", fn -> reply(server, %{}, []) end)
    assert gauges(server)["slack"] == {1, 10_000}
    assert_received {[:salix, :agent_message, :reply], %{latency: 10_000}, _}
    refute_received {[:salix, :agent_message, :reply], _, _}
  end

  test "a Worker's direct send answers the mention its activation holds", %{time: time} do
    server = start(:worker_direct, time) |> complete(time)
    Latency.mention(slack_mention("thread-mention"), server)
    Latency.conversation_message("thread-mention", "msg1_in", server)

    reply(server, %{}, ["groupconv:cnv1_task:msg1_in:par1_worker:suffix"])

    assert gauges(server)["slack"] == {1, 0}
    assert_received {[:salix, :agent_message, :reply], %{latency: 10_000}, _}
  end

  test "an unsupported mention from a pod of the old release opens the gap", %{time: time} do
    server = start(:mixed, time) |> complete(time)
    :ok = SystemsRuntime.Server.cast(server, {:unsupported, "key", "slack", @now})
    :ok = SystemsRuntime.Server.cast(server, {:not_a_message_of_this_release})
    assert gauges(server)["slack"] == {0, nil}

    :atomics.add(time, 1, @retention)
    assert gauges(server)["slack"] == {1, 0}
  end

  test "a confirmed delivery that overtakes its link still answers the mention", %{time: time} do
    server = start(:overtaken, time) |> complete(time)
    Latency.mention(slack_mention("thread-mention"), server)
    Latency.conversation_message("thread-mention", "msg1_in", server)

    Latency.with_message("msg1_out", fn -> reply(server, %{}, []) end)
    assert Latency.sample(server) == :ok
    refute_received {[:salix, :agent_message, :reply], _, _}

    Process.put(:salix_im_provider_tool_context, %{
      "source_message_id" => "groupconv:cnv1_task:msg1_in:par1_worker"
    })

    Latency.message_sent("msg1_out", server)
    Process.delete(:salix_im_provider_tool_context)

    assert gauges(server)["slack"] == {1, 0}
    assert_received {[:salix, :agent_message, :reply], %{latency: 10_000}, _}
    refute_received {[:salix, :agent_message, :reply], _, _}
  end

  test "a Worker's direct send that overtakes the ingress link answers the mention",
       %{time: time} do
    server = start(:overtaken_ingress, time) |> complete(time)
    Latency.mention(slack_mention("thread-mention"), server)

    reply(server, %{}, ["groupconv:cnv1_task:msg1_in:par1_worker"])
    Latency.conversation_message("thread-mention", "msg1_in", server)

    assert gauges(server)["slack"] == {1, 0}
    assert_received {[:salix, :agent_message, :reply], %{latency: 10_000}, _}
  end

  test "an overtaken reply older than the mention still answers nothing", %{time: time} do
    server = start(:overtaken_old, time) |> complete(time)
    reply(server, %{}, ["groupconv:cnv1_task:msg1_in:par1_worker"])
    Latency.mention(slack_mention("thread-mention", %{source_sent_at_ms: @now + 1}), server)
    Latency.conversation_message("thread-mention", "msg1_in", server)

    assert gauges(server)["slack"] == {1, 0}
    refute_received {[:salix, :agent_message, :reply], _, _}
  end

  test "a restarted pod copies the table from a complete peer", %{time: time} do
    peer = :peer
    start(peer, time) |> complete(time)
    Latency.mention(slack_mention(), peer)
    assert Latency.sample(peer) == :ok

    restarted = start(:restarted, time, fn -> [peer] end)
    assert Latency.sample(peer) == :ok
    assert gauges(restarted)["slack"] == {1, 10_000}
  end

  test "a rolling restart before the window has run keeps the table and the window",
       %{time: time} do
    live = fn -> [:rolling_a, :rolling_b] end
    first = start(:rolling_a, time, fn -> [:rolling_b] end, live)
    Latency.mention(slack_mention("pending", %{source_sent_at_ms: @now - @retention}), first)
    Latency.mention(slack_mention("gap", %{source_sent_at_ms: nil}), first)
    assert Latency.sample(first) == :ok

    :atomics.add(time, 1, div(@retention, 2))
    second = start(:rolling_b, time, fn -> [:rolling_a] end, live)
    assert Latency.sample(first) == :ok
    assert Latency.sample(second) == :ok
    stop_supervised!(first)

    assert %{pending: pending, gaps: %{"slack" => _}} = :sys.get_state(second)
    assert map_size(pending) == 1
    assert :sys.get_state(second).started_at == @now - @retention
    assert {0, _age} = gauges(second)["slack"]
    assert gauges(second)["feishu"] == {0, nil}

    :atomics.add(time, 1, div(@retention, 2))
    assert gauges(second)["feishu"] == {1, 0}
  end

  test "a tracker of an older release stays up beside a restarted pod", %{time: time} do
    supervisor =
      start_supervised!(%{
        id: :old_release,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [
             [%{id: OldTracker, start: {OldTracker, :start_link, [:old_tracker]}}],
             [strategy: :one_for_one, max_restarts: 3, max_seconds: 5]
           ]}
      })

    old = Process.whereis(:old_tracker)

    server =
      start(:beside_old, time, fn -> [:old_tracker] end, nil,
        pull: fn _peer ->
          try do
            :erpc.call(node(), OldTracker, :window, [], 1_000)
          rescue
            ErlangError -> nil
          end
        end
      )

    # The old release asks every restarted peer and is asked in turn.
    :ok = SystemsRuntime.Server.cast(server, {:copy_to, :old_tracker})
    for _ <- 1..8, do: assert(Latency.sample(server) == :ok)

    assert :sys.get_state(:old_tracker) == :old_tracker
    assert Process.whereis(:old_tracker) == old
    assert Process.alive?(supervisor)
    assert gauges(server)["slack"] == {0, nil}
  end

  test "an incomplete peer gives no proof of completeness", %{time: time} do
    peer = start(:incomplete_peer, time)
    restarted = start(:restarted_alone, time, fn -> [peer] end)
    assert Latency.sample(peer) == :ok
    assert gauges(restarted)["slack"] == {0, nil}
  end

  test "the Feishu and Lark send paths report what the provider confirmed" do
    start_supervised!(Latency)
    original = Req.default_options()
    Req.default_options(Keyword.put(original, :plug, {Req.Test, __MODULE__}))
    on_exit(fn -> Req.default_options(original) end)

    connect = %{
      "connect_id" => "con_send",
      "status" => "connected",
      "app_id" => "cli_test",
      "tenant_access_token" => "offline-test-token"
    }

    sent_at = SystemsClock.system_time(:millisecond)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "code" => 0,
        "data" => %{
          "message_id" => "om_reply",
          "chat_id" => "oc_send",
          "parent_id" => "om_source",
          "root_id" => "om_source",
          "create_time" => to_string(sent_at + 2_000)
        }
      })
    end)

    for provider <- ["feishu", "lark"] do
      Latency.provider_mention("#{provider}-send-path", %{
        "bot_mentioned" => true,
        "sender_type" => "user",
        "provider" => provider,
        "connect_id" => "con_send",
        "chat_id" => "oc_send",
        "message_id" => "om_source",
        "source_sent_at_ms" => sent_at
      })
    end

    Latency.provider_mention("bot-authored", %{"bot_mentioned" => true, "sender_type" => "app"})
    Latency.provider_mention("not-mentioned", %{"sender_type" => "user"})

    Latency.provider_mention(
      "command",
      %{"bot_mentioned" => true, "sender_type" => "user"},
      "<salix-command>status</salix-command>"
    )

    assert {:ok, _} =
             SalixIM.Provider.Feishu.call("agent", connect, "feishu.reply_text", %{
               "message_id" => "om_source",
               "text" => "done"
             })

    assert {:ok, _} =
             SalixIM.Provider.Lark.API.post(connect, "/im/v1/messages/om_source/reply", %{})

    assert Latency.sample() == :ok

    for provider <- ["feishu", "lark"] do
      assert_received {[:salix, :agent_message, :mention], %{count: 1}, %{provider: ^provider}}

      assert_received {[:salix, :agent_message, :reply], %{latency: 2_000},
                       %{provider: ^provider}}
    end

    refute_received {[:salix, :agent_message, :mention], _, _}
  end

  test "the metric names, finite labels and privacy of the exported series", %{time: time} do
    reporter = Module.concat(__MODULE__, Reporter)
    metrics = SystemsObservability.Metrics.enabled_metrics([:salix])

    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: reporter,
       metrics: Enum.reject(metrics, &match?(%Telemetry.Metrics.Distribution{}, &1)),
       start_async: false}
    )

    server = start(:privacy, time) |> complete(time)
    Latency.mention(slack_mention("private-source-id", %{place: "C-PRIVATE"}), server)
    Latency.mention(slack_mention("other", %{source_sent_at_ms: nil}), server)
    assert Latency.sample(server) == :ok

    scrape = TelemetryMetricsPrometheus.Core.scrape(reporter)
    assert scrape =~ ~r/salix_agent_message_mentions_total\{provider="slack"\} 2/
    assert scrape =~ ~r/salix_agent_message_pending_oldest_age_seconds\{provider="slack"\} 10/
    assert scrape =~ ~r/salix_agent_message_latency_coverage\{provider="lark"\} 1/
    assert scrape =~ "salix_agent_message_latency_observed_at_seconds"

    assert scrape =~
             ~r/salix_agent_message_latency_invalid_total\{provider="slack",reason="missing_source_time"\} 1/

    refute scrape =~ "private-source-id"
    refute scrape =~ "C-PRIVATE"
    refute scrape =~ "con_1"

    assert %Telemetry.Metrics.Distribution{reporter_options: options} =
             Enum.find(metrics, &(&1.name == [:salix, :agent_message, :latency, :seconds]))

    assert Enum.all?([120, 300], &(&1 in options[:buckets]))
  end
end
