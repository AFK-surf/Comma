defmodule SalixIM.SlackMessageMirrorBackfillTest do
  @moduledoc """
  One backfill pass against scripted Slack, a scripted writer, and the real
  ledger.

  The rules under test are the ones `tla/salix/SlackMirrorBackfill.tla` proves
  the code has to keep: write before commit, replies to the end or not at all,
  resume from the watermark, and stop at the floor or at Slack's end.
  """
  use ExUnit.Case, async: false

  alias SalixIM.SlackMessageMirror.Backfill
  alias SalixStore.{Repo, SlackMirrorBackfillLedger, ULID}

  defmodule FakeSlack do
    @moduledoc false
    use Agent

    def start(script) do
      {:ok, pid} = Agent.start_link(fn -> Map.merge(%{calls: []}, script) end)
      pid
    end

    def calls(pid), do: pid |> Agent.get(& &1.calls) |> Enum.reverse()
    def last_conversation_opts(pid), do: Agent.get(pid, & &1[:last_conversation_opts])
    def last_history_opts(pid), do: Agent.get(pid, & &1[:last_history_opts])
    def last_replies_opts(pid), do: Agent.get(pid, & &1[:last_replies_opts])

    def conversations(pid, opts) do
      Agent.get_and_update(pid, fn state ->
        [answer | rest] = Map.get(state, :conversations, [{:ok, [], nil}])

        {answer,
         state
         |> Map.update!(:calls, &[{:conversations, opts[:cursor]} | &1])
         |> Map.put(:last_conversation_opts, opts)
         |> Map.put(:conversations, if(rest == [], do: [answer], else: rest))}
      end)
    end

    def history(pid, channel_id, opts) do
      Agent.get_and_update(pid, fn state ->
        pages = get_in(state, [:history, channel_id]) || []
        {answer, rest} = pop(pages, {:ok, []})

        {answer,
         state
         |> Map.update!(:calls, &[{:history, channel_id, opts[:latest]} | &1])
         |> Map.put(:last_history_opts, opts)
         |> put_in([:history, channel_id], rest)}
      end)
    end

    def replies(pid, channel_id, root_ts, opts) do
      Agent.get_and_update(pid, fn state ->
        pages = get_in(state, [:replies, {channel_id, root_ts}]) || []
        {answer, rest} = pop(pages, {:ok, [], ""})

        {answer,
         state
         |> Map.update!(:calls, &[{:replies, channel_id, root_ts, opts[:cursor]} | &1])
         |> Map.put(:last_replies_opts, opts)
         |> put_in([:replies, {channel_id, root_ts}], rest)}
      end)
    end

    defp pop([], default), do: {default, []}
    defp pop([answer | rest], _default), do: {answer, rest}
  end

  defmodule FakeWriter do
    @moduledoc false
    use Agent

    def start(answers \\ []) do
      {:ok, pid} = Agent.start_link(fn -> %{rows: [], answers: answers} end)
      pid
    end

    def rows(pid), do: pid |> Agent.get(& &1.rows) |> Enum.reverse()

    def write_batch(pid, rows) do
      Agent.get_and_update(pid, fn state ->
        {answer, rest} =
          case state.answers do
            [] -> {:ok, []}
            [answer | rest] -> {answer, rest}
          end

        rows = if answer == :ok, do: Enum.reverse(rows) ++ state.rows, else: state.rows
        {answer, %{state | rows: rows, answers: rest}}
      end)
    end
  end

  # The pass reaches its collaborators by module, so each test binds the
  # module-level entry points to the Agents it started.
  defmodule Reader do
    @moduledoc false
    def conversations(_credential, opts), do: FakeSlack.conversations(pid(), opts)
    def history(_credential, channel_id, opts), do: FakeSlack.history(pid(), channel_id, opts)

    def replies(_credential, channel_id, root_ts, opts),
      do: FakeSlack.replies(pid(), channel_id, root_ts, opts)

    defp pid, do: Application.fetch_env!(:salix_im, :backfill_test_slack)
  end

  defmodule Writer do
    @moduledoc false
    def write_batch(rows), do: FakeWriter.write_batch(pid(), rows)
    defp pid, do: Application.fetch_env!(:salix_im, :backfill_test_writer)
  end

  defmodule ChannelObserver do
    def observe_slack_member_channels(connect, channels) do
      send(self(), {:member_channels_observed, connect["connect_id"], channels})
      {:error, :projection_unavailable}
    end
  end

  @now_us 1_787_100_000_000_000

  setup do
    Repo.query!("TRUNCATE slack_mirror_channel_watermarks, slack_mirror_backfill_connects")

    on_exit(fn ->
      Application.delete_env(:salix_im, :backfill_test_slack)
      Application.delete_env(:salix_im, :backfill_test_writer)
    end)

    :ok
  end

  describe "a fresh channel" do
    test "shared discovery publishes its page and a listening failure does not block archive" do
      connect = claimed_connect!()
      channels = [%{"id" => "C1"}]

      slack =
        start_slack(%{conversations: [{:ok, channels, nil}], history: %{"C1" => [{:ok, []}]}})

      start_writer()
      assert {:ok, :idle} = run(connect, channel_observer: ChannelObserver)
      assert_received {:member_channels_observed, _, ^channels}
      assert Enum.count(FakeSlack.calls(slack), &match?({:conversations, _}, &1)) == 1
    end

    test "is written page by page, the watermark follows, and Slack's end exhausts it" do
      connect = claimed_connect!()

      slack =
        start_slack(%{
          conversations: [{:ok, [%{"id" => "C1"}], nil}],
          history: %{
            "C1" => [{:ok, [message(900), message(800)]}, {:ok, [message(700)]}, {:ok, []}]
          }
        })

      writer = start_writer()

      assert {:ok, :idle} = run(connect)

      assert Enum.map(FakeWriter.rows(writer), & &1["message_ts_us"]) == [
               us(900),
               us(800),
               us(700)
             ]

      assert {:ok, watermark} = SlackMirrorBackfillLedger.watermark(key("C1"))
      assert watermark["indexed_from_ts_us"] == us(700)
      assert watermark["indexed_to_ts_us"] == @now_us
      assert watermark["exhausted"] == true
      assert watermark["leased_until"] == nil

      # Each request starts where the last page ended, exclusive.
      assert [
               {:conversations, nil},
               {:history, "C1", first},
               {:history, "C1", second},
               {:history, "C1", third}
             ] =
               FakeSlack.calls(slack)

      assert first == slack_ts(@now_us)
      assert second == "1787019000.000800"
      assert third == "1787019000.000700"
    end

    test "an empty channel is exhausted without a watermark" do
      connect = claimed_connect!()

      start_slack(%{
        conversations: [{:ok, [%{"id" => "C1"}], nil}],
        history: %{"C1" => [{:ok, []}]}
      })

      writer = start_writer()

      assert {:ok, :idle} = run(connect)
      assert FakeWriter.rows(writer) == []

      assert {:ok, %{"exhausted" => true, "indexed_from_ts_us" => nil}} =
               SlackMirrorBackfillLedger.watermark(key("C1"))
    end

    test "archived member channels are walked and history requests all metadata" do
      connect = claimed_connect!()

      slack =
        start_slack(%{
          conversations: [
            {:ok, [%{"id" => "C_ARCHIVED", "is_archived" => true}], nil}
          ],
          history: %{"C_ARCHIVED" => [{:ok, [message(900)]}, {:ok, []}]}
        })

      writer = start_writer()

      assert {:ok, :idle} = run(connect)
      assert Enum.map(FakeWriter.rows(writer), & &1["message_ts_us"]) == [us(900)]
      assert FakeSlack.last_conversation_opts(slack)[:exclude_archived] == false
      assert FakeSlack.last_history_opts(slack)[:include_all_metadata] == true
      assert FakeSlack.last_history_opts(slack)[:limit] == 1_000
    end

    test "history rows stamp observed_ts_us from the cut taken before the request" do
      connect = claimed_connect!()

      start_slack(%{
        conversations: [{:ok, [%{"id" => "C1"}], nil}],
        history: %{"C1" => [{:ok, [message(900)]}, {:ok, []}]}
      })

      writer = start_writer()

      assert {:ok, :idle} = run(connect, snapshot_cut: fn -> 4_242 end)
      assert Enum.map(FakeWriter.rows(writer), & &1["observed_ts_us"]) == [4_242]
    end
  end

  describe "write before commit" do
    test "a page the writer refuses does not move the watermark, and the pass asks to retry" do
      connect = claimed_connect!()

      start_slack(%{
        conversations: [{:ok, [%{"id" => "C1"}], nil}],
        history: %{"C1" => [{:ok, [message(900)]}, {:ok, [message(800)]}]}
      })

      start_writer([:ok, {:error, :clickhouse_down}])

      assert {:ok, :retry} = run(connect)

      assert {:ok, watermark} = SlackMirrorBackfillLedger.watermark(key("C1"))
      assert watermark["indexed_from_ts_us"] == us(900)
      assert watermark["last_error"] =~ "clickhouse_down"
      assert watermark["leased_until"] == nil
    end

    test "a thread that does not end within the guard fails the page rather than committing it" do
      connect = claimed_connect!()

      start_slack(%{
        conversations: [{:ok, [%{"id" => "C1"}], nil}],
        history: %{"C1" => [{:ok, [thread_root(900, 5)]}]},
        replies: %{{"C1", ts(900)} => List.duplicate({:ok, [message(901)], "again"}, 10)}
      })

      start_writer()

      assert {:ok, :retry} = run(connect, thread_page_cap: 3)

      assert {:ok, %{"indexed_from_ts_us" => nil, "last_error" => error}} =
               SlackMirrorBackfillLedger.watermark(key("C1"))

      assert error =~ "thread_cursor_runaway"
    end
  end

  describe "threads" do
    test "every reply page is written with the parent page before the commit" do
      connect = claimed_connect!()

      slack =
        start_slack(%{
          conversations: [{:ok, [%{"id" => "C1"}], nil}],
          history: %{"C1" => [{:ok, [thread_root(900, 3), message(850)]}, {:ok, []}]},
          replies: %{
            {"C1", ts(900)} => [
              {:ok, [thread_root(900, 3), reply(901, 900)], "page2"},
              {:ok, [reply(902, 900), reply(903, 900)], ""}
            ]
          }
        })

      writer = start_writer()

      assert {:ok, :idle} = run(connect)

      written = FakeWriter.rows(writer) |> Enum.map(& &1["message_ts_us"]) |> Enum.sort()
      assert written == Enum.sort([us(900), us(850), us(900), us(901), us(902), us(903)])

      assert {:ok, %{"indexed_from_ts_us" => from}} =
               SlackMirrorBackfillLedger.watermark(key("C1"))

      assert from == us(850)
      assert FakeSlack.last_replies_opts(slack)[:limit] == 1_000
    end

    # A broadcast carries `thread_ts` pointing at another message; its thread
    # is walked from the page that carries the parent, not from here.
    test "only parents with replies start a replies walk" do
      connect = claimed_connect!()

      slack =
        start_slack(%{
          conversations: [{:ok, [%{"id" => "C1"}], nil}],
          history: %{
            "C1" => [{:ok, [message(900), reply(880, 500), thread_root(870, 0)]}, {:ok, []}]
          }
        })

      start_writer()

      assert {:ok, :idle} = run(connect)
      refute Enum.any?(FakeSlack.calls(slack), &match?({:replies, _, _, _}, &1))
    end
  end

  describe "resuming" do
    test "a channel with a watermark is read from below it and indexed_to stays put" do
      connect = claimed_connect!()
      :ok = seed_watermark!("C1", from: us(700), to: us(950))

      slack =
        start_slack(%{
          conversations: [{:ok, [%{"id" => "C1"}], nil}],
          history: %{"C1" => [{:ok, [message(600)]}, {:ok, []}]}
        })

      start_writer()

      assert {:ok, :idle} = run(connect)

      assert [
               {:conversations, nil},
               {:history, "C1", "1787019000.000700"},
               {:history, "C1", "1787019000.000600"}
             ] =
               FakeSlack.calls(slack)

      assert {:ok, %{"indexed_from_ts_us" => from, "indexed_to_ts_us" => to}} =
               SlackMirrorBackfillLedger.watermark(key("C1"))

      assert from == us(600)
      assert to == us(950)
    end

    test "without a page budget one pass walks a channel to Slack's end" do
      connect = claimed_connect!()

      start_slack(%{
        conversations: [{:ok, [%{"id" => "C1"}], nil}],
        history: %{
          "C1" =>
            Enum.map(1..45, fn n -> {:ok, [message(1000 - n)]} end) ++
              [{:ok, []}]
        }
      })

      start_writer()

      assert {:ok, :idle} = run(connect, page_budget: :infinity)

      assert {:ok, %{"exhausted" => true, "indexed_from_ts_us" => from}} =
               SlackMirrorBackfillLedger.watermark(key("C1"))

      assert from == us(955)
    end

    test "a pass round-robins history pages so a deep first channel does not starve the rest" do
      connect = claimed_connect!()

      slack =
        start_slack(%{
          conversations: [{:ok, [%{"id" => "C1"}, %{"id" => "C2"}], nil}],
          history: %{
            "C1" => [
              {:ok, [thread_root(900, 1)]},
              {:ok, [message(800)]},
              {:ok, []}
            ],
            "C2" => [{:ok, [message(700)]}, {:ok, []}]
          },
          replies: %{
            {"C1", ts(900)} => [{:ok, [thread_root(900, 1), reply(901, 900)], ""}]
          }
        })

      start_writer()

      assert {:ok, :idle} = run(connect, page_budget: :infinity)

      assert [
               {:conversations, nil},
               {:history, "C1", _},
               {:replies, "C1", _, _},
               {:history, "C2", _},
               {:history, "C1", _},
               {:history, "C2", _},
               {:history, "C1", _}
             ] = FakeSlack.calls(slack)

      assert {:ok, %{"exhausted" => true}} = SlackMirrorBackfillLedger.watermark(key("C1"))

      assert {:ok, %{"exhausted" => true, "indexed_from_ts_us" => from}} =
               SlackMirrorBackfillLedger.watermark(key("C2"))

      assert from == us(700)
    end

    test "the page budget ends a visit with :more and the next visit continues below" do
      connect = claimed_connect!()

      start_slack(%{
        conversations: [{:ok, [%{"id" => "C1"}], nil}, {:ok, [%{"id" => "C1"}], nil}],
        history: %{
          "C1" => [{:ok, [message(900)]}, {:ok, [message(800)]}, {:ok, [message(700)]}, {:ok, []}]
        }
      })

      start_writer()

      assert {:ok, :more} = run(connect, page_budget: 2)

      assert {:ok, %{"indexed_from_ts_us" => from}} =
               SlackMirrorBackfillLedger.watermark(key("C1"))

      assert from == us(800)

      assert {:ok, :idle} = run(connect, page_budget: 2)

      assert {:ok, %{"indexed_from_ts_us" => from, "exhausted" => true}} =
               SlackMirrorBackfillLedger.watermark(key("C1"))

      assert from == us(700)
    end

    test "an exhausted channel costs nothing" do
      connect = claimed_connect!()
      :ok = seed_watermark!("C1", from: us(700), to: us(950), exhausted: true)
      slack = start_slack(%{conversations: [{:ok, [%{"id" => "C1"}], nil}]})
      start_writer()

      assert {:ok, :idle} = run(connect)
      assert FakeSlack.calls(slack) == [{:conversations, nil}]
    end
  end

  describe "the floor" do
    test "stops the walk without exhausting the channel, so lowering it resumes" do
      connect = claimed_connect!()

      slack =
        start_slack(%{
          conversations: [
            {:ok, [%{"id" => "C1"}], nil},
            {:ok, [%{"id" => "C1"}], nil},
            {:ok, [%{"id" => "C1"}], nil}
          ],
          history: %{"C1" => [{:ok, [message(900)]}, {:ok, [message(800)]}, {:ok, []}]}
        })

      start_writer()

      assert {:ok, :idle} = run(connect, floor_ts_us: us(900))

      assert {:ok, %{"indexed_from_ts_us" => from, "exhausted" => false}} =
               SlackMirrorBackfillLedger.watermark(key("C1"))

      assert from == us(900)

      # Same floor: nothing to do.
      assert {:ok, :idle} = run(connect, floor_ts_us: us(900))
      assert length(FakeSlack.calls(slack)) == 3

      # Lower floor: the walk picks up below the watermark.
      assert {:ok, :idle} = run(connect, floor_ts_us: 0)

      assert {:ok, %{"indexed_from_ts_us" => from, "exhausted" => true}} =
               SlackMirrorBackfillLedger.watermark(key("C1"))

      assert from == us(800)
    end
  end

  describe "claims" do
    test "two installations in one workspace walk different channels at once" do
      # Slack rate-limits per workspace AND bot, so two bots are two budgets.
      # The channel claim is only a courtesy between them; it must not serialize
      # the installations themselves.
      first = claimed_connect!()
      second = claimed_connect!()

      start_slack(%{
        conversations: [
          {:ok, [%{"id" => "C1"}], nil},
          {:ok, [%{"id" => "C2"}], nil}
        ],
        history: %{
          "C1" => [{:ok, [message(900)]}, {:ok, []}],
          "C2" => [{:ok, [message(800)]}, {:ok, []}]
        }
      })

      writer = start_writer()

      assert {:ok, :idle} = run(first)
      assert {:ok, :idle} = run(second)

      written = FakeWriter.rows(writer) |> Enum.map(& &1["channel_id"]) |> Enum.sort()
      assert written == ["C1", "C2"]
    end

    test "a channel another walker holds is skipped, and the rest of the pass runs" do
      connect = claimed_connect!()
      {:ok, _row} = SlackMirrorBackfillLedger.claim_channel(key("C1"), 60_000)

      slack =
        start_slack(%{
          conversations: [{:ok, [%{"id" => "C1"}, %{"id" => "C2"}], nil}],
          history: %{"C2" => [{:ok, [message(900)]}, {:ok, []}]}
        })

      writer = start_writer()

      # C1 may still have history; busy is not "this install is done".
      assert {:ok, :retry} = run(connect)
      assert Enum.map(FakeWriter.rows(writer), & &1["channel_id"]) == ["C2"]
      refute Enum.any?(FakeSlack.calls(slack), &match?({:history, "C1", _}, &1))
    end

    test "a pass that only hits busy channels retries rather than going idle" do
      connect = claimed_connect!()
      {:ok, _row} = SlackMirrorBackfillLedger.claim_channel(key("C1"), 60_000)

      start_slack(%{conversations: [{:ok, [%{"id" => "C1"}], nil}]})
      start_writer()

      assert {:ok, :retry} = run(connect)
    end

    test "a finite page budget yields so a skipped channel is retried before the rest are exhausted" do
      connect = claimed_connect!()
      {:ok, _row} = SlackMirrorBackfillLedger.claim_channel(key("C1"), 60_000)

      slack =
        start_slack(%{
          conversations: [
            {:ok, [%{"id" => "C1"}, %{"id" => "C2"}], nil},
            {:ok, [%{"id" => "C1"}, %{"id" => "C2"}], nil}
          ],
          history: %{
            "C2" =>
              Enum.map(1..5, fn n -> {:ok, [message(900 - n)]} end) ++
                [{:ok, []}]
          }
        })

      start_writer()

      assert {:ok, :more} = run(connect, page_budget: 2)
      refute Enum.any?(FakeSlack.calls(slack), &match?({:history, "C1", _}, &1))

      assert {:ok, %{"indexed_from_ts_us" => from, "exhausted" => false}} =
               SlackMirrorBackfillLedger.watermark(key("C2"))

      assert from == us(898)

      :ok = SlackMirrorBackfillLedger.release_channel(key("C1"))

      assert {:ok, :more} = run(connect, page_budget: 2)
      assert Enum.any?(FakeSlack.calls(slack), &match?({:history, "C1", _}, &1))
    end

    test "losing the installation's claim stops the pass" do
      connect = claimed_connect!()
      :ok = SlackMirrorBackfillLedger.finish_connect(connect["connect_id"], 0, nil)

      start_slack(%{conversations: [{:ok, [%{"id" => "C1"}], nil}]})
      start_writer()

      assert {:error, :claim_lost} = run(connect)
    end
  end

  describe "Slack answers" do
    test "a rate limit is waited out exactly as long as Slack asked, then retried" do
      connect = claimed_connect!()

      start_slack(%{
        conversations: [{:ok, [%{"id" => "C1"}], nil}],
        history: %{"C1" => [{:error, {:rate_limited, 7_000}}, {:ok, [message(900)]}, {:ok, []}]}
      })

      writer = start_writer()
      parent = self()

      assert {:ok, :idle} = run(connect, sleep: fn ms -> send(parent, {:slept, ms}) end)
      assert_received {:slept, 7_000}
      assert length(FakeWriter.rows(writer)) == 1
    end

    test "a channel the bot can no longer read is recorded and the pass moves on" do
      connect = claimed_connect!()

      start_slack(%{
        conversations: [{:ok, [%{"id" => "C1"}, %{"id" => "C2"}], nil}],
        history: %{"C1" => [{:error, :ineligible}], "C2" => [{:ok, [message(900)]}, {:ok, []}]}
      })

      writer = start_writer()

      assert {:ok, :retry} = run(connect)
      assert Enum.map(FakeWriter.rows(writer), & &1["channel_id"]) == ["C2"]
      assert {:ok, %{"last_error" => error}} = SlackMirrorBackfillLedger.watermark(key("C1"))
      assert error =~ "ineligible"
    end

    test "channel listing follows its cursor to the end" do
      connect = claimed_connect!()

      slack =
        start_slack(%{
          conversations: [{:ok, [%{"id" => "C1"}], "next"}, {:ok, [%{"id" => "C2"}], ""}],
          history: %{"C1" => [{:ok, []}], "C2" => [{:ok, []}]}
        })

      start_writer()

      assert {:ok, :idle} = run(connect)
      assert [{:conversations, nil}, {:conversations, "next"} | _rest] = FakeSlack.calls(slack)
      assert {:ok, %{"exhausted" => true}} = SlackMirrorBackfillLedger.watermark(key("C2"))
    end

    test "the token being refused fails the pass" do
      connect = claimed_connect!()
      start_slack(%{conversations: [{:error, {:slack, "invalid_auth"}}]})
      start_writer()

      assert {:error, {:slack, "invalid_auth"}} = run(connect)
    end
  end

  defp run(connect, opts \\ []) do
    Backfill.run_pass(
      connect,
      Keyword.merge(
        [now_us: @now_us, pace_ms: 0, reader: Reader, writer: Writer, lease_ttl_ms: 60_000],
        opts
      )
    )
  end

  defp start_slack(script) do
    pid = FakeSlack.start(script)
    Application.put_env(:salix_im, :backfill_test_slack, pid)
    pid
  end

  defp start_writer(answers \\ []) do
    pid = FakeWriter.start(answers)
    Application.put_env(:salix_im, :backfill_test_writer, pid)
    pid
  end

  defp claimed_connect! do
    connect = %{
      "connect_id" => "imc_" <> ULID.generate(),
      "tenant_id" => "ten1_backfill",
      "group_id" => "grp1_backfill",
      "workspace_id" => "T_BACKFILL",
      "bot_token" => "xoxb-backfill-test"
    }

    :ok = SlackMirrorBackfillLedger.upsert_connects([connect])
    {:ok, _row} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
    connect
  end

  defp seed_watermark!(channel_id, opts) do
    {:ok, _row} = SlackMirrorBackfillLedger.claim_channel(key(channel_id), 60_000)
    :ok = SlackMirrorBackfillLedger.lower_watermark(key(channel_id), opts[:from], opts[:to])
    if opts[:exhausted], do: :ok = SlackMirrorBackfillLedger.mark_exhausted(key(channel_id))
    SlackMirrorBackfillLedger.release_channel(key(channel_id))
  end

  defp key(channel_id),
    do: %{
      "tenant_id" => "ten1_backfill",
      "workspace_id" => "T_BACKFILL",
      "channel_id" => channel_id
    }

  defp message(n), do: %{"type" => "message", "user" => "U1", "text" => "m#{n}", "ts" => ts(n)}

  defp thread_root(n, replies),
    do: message(n) |> Map.put("thread_ts", ts(n)) |> Map.put("reply_count", replies)

  defp reply(n, root), do: message(n) |> Map.put("thread_ts", ts(root))

  defp ts(n), do: "1787019000." <> String.pad_leading(Integer.to_string(n), 6, "0")
  defp us(n), do: 1_787_019_000_000_000 + n

  defp slack_ts(micros) do
    "#{div(micros, 1_000_000)}." <>
      String.pad_leading(Integer.to_string(rem(micros, 1_000_000)), 6, "0")
  end
end
