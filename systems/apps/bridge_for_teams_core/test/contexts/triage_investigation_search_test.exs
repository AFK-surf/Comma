defmodule BridgeForTeams.TriageInvestigationSearchTest do
  use ExUnit.Case, async: false

  alias BridgeForTeams.TriageInvestigationSearch, as: Search
  alias SalixIM.Provider
  alias SalixStore.{CasRecord, Ids, Keys, SlackSearchCatalog, SlackSearchSources}

  setup do
    previous_s3 = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    unless Process.whereis(SalixStore.S3.Fake), do: start_supervised!(SalixStore.S3.Fake)
    unless Process.whereis(Ids), do: start_supervised!(Ids)

    on_exit(fn ->
      if is_nil(previous_s3),
        do: Application.delete_env(:salix_store, :s3_backend),
        else: Application.put_env(:salix_store, :s3_backend, previous_s3)
    end)

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    worker = worker!(tenant, group)

    connect = %{
      "provider" => "slack",
      "tenant_id" => tenant,
      "group_id" => group,
      "connect_id" => Ids.new_connect_id(),
      "connect_generation" => "local-search-generation",
      "workspace_id" => "TLOCALSEARCH",
      "bot_token" => "local-search-token",
      "oauth_completed_at" => 1
    }

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_im_connect(group, connect["connect_id"]), connect)

    state = start_supervised!({Agent, fn -> %{} end})

    %{worker: worker, connect: connect, state: state}
  end

  test "an ordinary Worker searches published local evidence through the real provider", ctx do
    message = message("1600000000.000001", "Orion token rotation is recorded in the audit.")
    on_exit(Search.install!(ctx.state, ctx.connect, [message]))

    assert {:ok, %{"messages" => [result], "next_cursor" => nil}} =
             search(ctx.worker, %{"query" => "ORION token"})

    assert result["text"] == message["text"]
    assert result["thread_ts"] == message["thread_ts"]
    assert result["channel"] == message["channel"]
    assert result["connect_id"] == ctx.connect["connect_id"]
    assert result["fixture_search_semantics"] =~ "not semantic ranking"

    assert Enum.any?(Agent.get(ctx.state, & &1.context_reads), fn receipt ->
             receipt.operation == "slack.message_search.excerpts" and
               receipt.agent_id == ctx.worker and
               Enum.any?(receipt.messages, &(&1["text"] == message["text"]))
           end)
  end

  test "production pagination retains local matching and narrowing filters", ctx do
    messages = [
      message("1600000000.000001", "Orion rotation first"),
      message("1600000000.000002", "Orion rotation second"),
      message("1600000000.000003", "Orion rotation wrong author")
      |> Map.put("user", "UOTHERAUTHOR"),
      message("1600000000.000004", "Orion rotation outside time window"),
      message("1600000000.000002", "Orion rotation different channel")
      |> Map.put("channel", "COTHERCONTEXT")
    ]

    on_exit(Search.install!(ctx.state, ctx.connect, messages))

    assert {:ok, %{"messages" => [first], "next_cursor" => cursor}} =
             search(ctx.worker, %{
               "query" => "orion ROTATION",
               "mode" => "keyword",
               "count" => 1,
               "channel" => "CLOCALCONTEXT",
               "workspace" => ctx.connect["workspace_id"],
               "sender" => "ULOCALAUTHOR",
               "oldest" => "1600000000.000001",
               "latest" => "1600000000.000004"
             })

    assert first["text"] == "Orion rotation second"
    assert is_binary(cursor)

    assert {:ok, %{"messages" => [second], "next_cursor" => nil}} =
             search(ctx.worker, %{"cursor" => cursor})

    assert second["text"] == "Orion rotation first"
  end

  test "captured bot claims retain their actor kind rather than becoming human evidence", ctx do
    captured =
      message("1600000000.000001", "Prior assistant claim about the calendar")
      |> Map.put("actor_kind", "bot")
      |> Map.put("user", "U_CAPTURED_BOT")

    on_exit(Search.install!(ctx.state, ctx.connect, [captured]))

    assert {:ok, %{"messages" => [result]}} = search(ctx.worker, %{"query" => "calendar"})
    assert result["actor_kind"] == "bot"
    assert result["actor_id"] == "U_CAPTURED_BOT"
  end

  test "an unacknowledged build is hidden by the real publication gate", ctx do
    on_exit(Search.install!(ctx.state, ctx.connect, [message("1600000000.000001", "Orion")]))
    assert {:ok, %{"messages" => [_]}} = search(ctx.worker, %{"query" => "Orion"})

    update_rows(ctx.state, fn row ->
      %{row | candidate: Map.put(row.candidate, "build_id", Ecto.UUID.generate())}
    end)

    assert {:ok, %{"messages" => []}} = search(ctx.worker, %{"query" => "Orion"})
  end

  test "a published row without owner-observed channel provenance is hidden", ctx do
    on_exit(Search.install!(ctx.state, ctx.connect, [message("1600000000.000001", "Orion")]))

    [row] = Agent.get(ctx.state, & &1.search_rows)
    candidate = Map.put(row.candidate, "channel_id", "CUNOBSERVED")
    assert {:ok, captured} = SlackSearchSources.capture(candidate, candidate["message_ts_us"])

    candidate =
      Map.merge(candidate, %{
        "build_id" => Ecto.UUID.generate(),
        "change_epoch" => captured.change_epoch,
        "build_sequence" => captured.build_sequence
      })

    row = %{
      row
      | candidate: candidate,
        excerpt:
          Map.merge(row.excerpt, %{
            "channel" => candidate["channel_id"],
            "build_id" => candidate["build_id"]
          })
    }

    Agent.update(ctx.state, &Map.put(&1, :search_rows, [row]))
    assert :ok = SlackSearchSources.publish(candidate)
    assert {:ok, published} = SlackSearchSources.visible([candidate])
    assert MapSet.member?(published, candidate["build_id"])
    assert {:ok, known} = SlackSearchCatalog.known_candidates([candidate])
    refute MapSet.member?(known, candidate["build_id"])
    assert {:ok, %{"messages" => []}} = search(ctx.worker, %{"query" => "Orion"})
  end

  test "a changed current source identity hides the old published excerpt", ctx do
    on_exit(Search.install!(ctx.state, ctx.connect, [message("1600000000.000001", "Orion")]))
    assert {:ok, %{"messages" => [_]}} = search(ctx.worker, %{"query" => "Orion"})

    update_rows(ctx.state, fn row ->
      %{row | current_source: %{row.current_source | payload_identity: Ecto.UUID.generate()}}
    end)

    assert {:ok, %{"messages" => []}} = search(ctx.worker, %{"query" => "Orion"})
  end

  test "the next page rechecks the real connect even while its catalog stays active", ctx do
    messages = [
      message("1600000000.000001", "Orion first"),
      message("1600000000.000002", "Orion second")
    ]

    on_exit(Search.install!(ctx.state, ctx.connect, messages))

    assert {:ok, %{"messages" => [_], "next_cursor" => cursor}} =
             search(ctx.worker, %{"query" => "Orion", "count" => 1})

    assert is_binary(cursor)

    assert {:ok, _} =
             CasRecord.update(
               Keys.ctl_im_connect(ctx.connect["group_id"], ctx.connect["connect_id"]),
               &Map.put(&1, "disabled_at", 1)
             )

    assert {:ok, %{"messages" => [], "next_cursor" => nil}} =
             search(ctx.worker, %{"cursor" => cursor})

    assert {:ok, %{"messages" => []}} = search(ctx.worker, %{"query" => "Orion"})
  end

  test "another Group cannot search or resume the owning Group's result window", ctx do
    messages = [
      message("1600000000.000001", "Orion first"),
      message("1600000000.000002", "Orion second")
    ]

    on_exit(Search.install!(ctx.state, ctx.connect, messages))

    assert {:ok, %{"messages" => [_], "next_cursor" => cursor}} =
             search(ctx.worker, %{"query" => "Orion", "count" => 1})

    tenant = ctx.connect["tenant_id"]
    other_worker = worker!(tenant, Ids.new_group_id(tenant))
    assert {:ok, %{"messages" => []}} = search(other_worker, %{"query" => "Orion"})
    assert {:error, error} = search(other_worker, %{"cursor" => cursor})
    assert error =~ "unavailable in this group"
  end

  test "an unavailable index fails clearly instead of reporting empty results", ctx do
    on_exit(Search.install!(ctx.state, ctx.connect, [message("1600000000.000001", "Orion")]))
    Application.delete_env(:salix_im, :slack_message_search_reader)

    assert {:error, error} = search(ctx.worker, %{"query" => "Orion"})
    assert error =~ "Message search is unavailable"
  end

  test "exhausting read receipts fails closed without stopping the shared corpus Agent", ctx do
    on_exit(Search.install!(ctx.state, ctx.connect, [message("1600000000.000001", "Orion")]))
    Agent.update(ctx.state, &Map.put(&1, :context_reads, List.duplicate(%{}, 200)))

    assert {:error, error} = search(ctx.worker, %{"query" => "Orion"})
    assert error =~ "Message search is unavailable"
    assert Process.alive?(ctx.state)
    assert length(Agent.get(ctx.state, & &1.context_reads)) == 200
  end

  test "invalid or unbounded corpora are rejected before installing the reader", ctx do
    message = message("1600000000.000001", "Orion")
    previous_reader = Application.get_env(:salix_im, :slack_message_search_reader)

    for messages <- [[], List.duplicate(message, 51), [message, message]] do
      assert_raise ArgumentError, fn -> Search.install!(ctx.state, ctx.connect, messages) end
    end

    assert_raise ArgumentError, fn ->
      Search.install!(ctx.state, ctx.connect, [
        Map.put(message, "text", String.duplicate("x", 16_385))
      ])
    end

    assert Application.get_env(:salix_im, :slack_message_search_reader) == previous_reader
    refute Map.has_key?(Agent.get(ctx.state, & &1), :search_rows)
  end

  defp update_rows(state, update) do
    Agent.update(state, &Map.update!(&1, :search_rows, fn rows -> Enum.map(rows, update) end))
  end

  defp worker!(tenant, group) do
    assert {:ok, _} =
             CasRecord.create(Keys.ctl_group(group), %{
               "tenant_id" => tenant,
               "group_id" => group,
               "router_conversation_id" => Ids.new_conversation_id()
             })

    worker = Ids.new_agent_id(group)

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_agent(worker), %{
               "agent_id" => worker,
               "tenant_id" => tenant,
               "group_id" => group,
               "role" => "worker",
               "heartbeat_schedule_id" => Ids.new_schedule_id()
             })

    worker
  end

  defp message(ts, text) do
    %{
      "channel" => "CLOCALCONTEXT",
      "ts" => ts,
      "thread_ts" => "1600000000.000000",
      "user" => "ULOCALAUTHOR",
      "text" => text
    }
  end

  defp search(worker, params) do
    Provider.call_api(worker, "slack", "slack.message_search", %{
      "params" => params,
      "tool_context" => %{"agent_id" => worker}
    })
  end
end
