defmodule BridgeForTeams.TriageTest do
  # async: false — these swap the global `:salix_client` app env and share the
  # node-local `Salix.ReadCache` ETS table.
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, Memberships, Observability, Orgs, Triage}

  defmodule Stub do
    @moduledoc """
    Scripted Salix responses plus a per-key invocation counter, so the cache
    tests can assert on how many times the seam was actually crossed.

    A response of `{:seq, [a, b, ...]}` is consumed one call at a time and the
    last element repeats — that is how a write test observes the posture
    changing across the write.
    """
    use Agent

    def start_link(responses),
      do: Agent.start_link(fn -> %{responses: responses, calls: %{}} end, name: __MODULE__)

    def put(key, value),
      do: Agent.update(__MODULE__, fn s -> %{s | responses: Map.put(s.responses, key, value)} end)

    def calls(key), do: Agent.get(__MODULE__, fn s -> Map.get(s.calls, key, 0) end)

    def call(key, default) do
      Agent.get_and_update(__MODULE__, fn state ->
        calls = Map.update(state.calls, key, 1, &(&1 + 1))

        {value, responses} =
          case Map.fetch(state.responses, key) do
            {:ok, {:seq, [only]}} -> {only, state.responses}
            {:ok, {:seq, [head | tail]}} -> {head, Map.put(state.responses, key, {:seq, tail})}
            {:ok, value} -> {value, state.responses}
            :error -> {default, state.responses}
          end

        {value, %{state | calls: calls, responses: responses}}
      end)
    end
  end

  defmodule StubClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    alias BridgeForTeams.TriageTest.Stub

    # `{:slow, ms, result}` sleeps *outside* the stub's Agent, so a fan-out
    # test observes real concurrency instead of the Agent serialising it.
    def triage_connect_posture(_tenant_id, group_id) do
      case Stub.call({:posture, group_id}, {:ok, []}) do
        {:slow, ms, result} ->
          Process.sleep(ms)
          result

        result ->
          result
      end
    end

    def triage_list_buckets(namespace, cursor, limit),
      do: Stub.call({:buckets, namespace, cursor, limit}, {:error, :unavailable})

    def triage_get_bucket(namespace, bucket_key),
      do: Stub.call({:bucket, namespace, bucket_key}, {:error, :not_found})

    def triage_list_receipts(cursor), do: Stub.call({:receipts, cursor}, {:error, :unavailable})

    def triage_recent_window(namespace, since_ms, opts),
      do: Stub.call({:window, namespace, since_ms, opts}, {:error, :unavailable})

    def triage_recent_processing(namespace, since_ms, opts),
      do: Stub.call({:processing, namespace, since_ms, opts}, {:error, :unavailable})

    def triage_processing_detail(group_id, receipt_ref),
      do: Stub.call({:processing_detail, group_id, receipt_ref}, {:error, :unavailable})

    def triage_product_activity(project_id, group_id, agent_id, opts),
      do:
        Stub.call(
          {:product_activity, project_id, group_id, agent_id, opts},
          {:error, :unavailable}
        )

    def triage_product_heatmap(project_id, group_id, agent_id),
      do: Stub.call({:product_heatmap, project_id, group_id, agent_id}, {:error, :unavailable})

    def triage_delegation_task(project_id, group_id, agent_id, obligation_id, index),
      do:
        Stub.call(
          {:delegation_task, project_id, group_id, agent_id, obligation_id, index},
          {:error, :unavailable}
        )

    def triage_ring_status(refs), do: Stub.call({:ring, refs}, {:error, :unavailable})

    def triage_list_slack_channels(_tenant_id, group_id, connect_id, cursor, limit),
      do:
        Stub.call(
          {:channels, group_id, connect_id, cursor, limit},
          {:error, :unavailable}
        )

    def triage_set_enabled(_tenant_id, group_id, connect_id, enabled?),
      do: Stub.call({:set_enabled, group_id, connect_id, enabled?}, :ok)

    def triage_provision(_tenant_id, group_id, connect_id, channel_id),
      do: Stub.call({:provision, group_id, connect_id, channel_id}, {:ok, %{}})
  end

  setup do
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-#{unique()}"})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        name: "Bridge",
        slug: "bridge-#{unique()}"
      })

    {:ok, owner} = Accounts.create_user(%{email: "owner-#{unique()}@example.com"})
    {:ok, _} = Memberships.put_org_member(org.id, owner.id, "owner")

    %{
      org: org,
      project: project,
      owner: owner,
      namespace: SalixStore.TriageKeys.default_namespace()
    }
  end

  defp unique, do: System.unique_integer([:positive])

  defp use_stub(responses \\ %{}) do
    if :ets.whereis(BridgeForTeams.Salix.ReadCache) != :undefined,
      do: :ets.delete_all_objects(BridgeForTeams.Salix.ReadCache)

    start_supervised!({Stub, responses})
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, StubClient)
    on_exit(fn -> restore(:salix_client, prev) end)
    :ok
  end

  # Kept as a no-op while the call sites remain explicit about which tests use
  # the Triage namespace. The namespace is now product-owned and fixed.
  defp use_namespace(_namespace), do: :ok

  # The audit writer is resolved through app env exactly so this branch is
  # reachable: "the audit row could not be written" cannot otherwise be
  # produced without corrupting the audit table.
  defp use_failing_audit_writer do
    prev = Application.get_env(:bridge_for_teams_core, :triage_audit_writer)

    Application.put_env(:bridge_for_teams_core, :triage_audit_writer, fn _attrs ->
      {:error, :audit_store_down}
    end)

    on_exit(fn -> restore(:triage_audit_writer, prev) end)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:bridge_for_teams_core, key)
  defp restore(key, value), do: Application.put_env(:bridge_for_teams_core, key, value)

  defp posture(connect_id, overrides \\ %{}) do
    Map.merge(
      %{
        connect_id: connect_id,
        provisioned?: true,
        triage_enabled: false,
        approved_channel_id: "C123",
        connect_generation: "gen-1",
        bot_username: "bridge",
        workspace_name: "Acme",
        app_id: "A1"
      },
      overrides
    )
  end

  defp bucket(connect_id) do
    %{
      bucket_key: "ctl/im_triage/x/buckets/#{connect_id}.json",
      bucket_scope: "scope-#{connect_id}",
      open_generation: "gen-1",
      open_first_at: 1,
      open_last_at: 2,
      receipt_count: 1,
      fast_path: false,
      connect_id: connect_id
    }
  end

  defp receipt(connect_id),
    do: %{
      "schema" => "comma.slack-triage-event-receipt.v2",
      "connect_id" => connect_id,
      "event_id" => "ev-#{connect_id}",
      "created_at" => 10,
      "triage_event" => %{"message_ts" => "1.1"}
    }

  # ---- namespace ----

  test "the runtime namespace is product-owned and ignores legacy app env" do
    previous = Application.get_env(:bridge_for_teams_core, :triage_namespace)
    on_exit(fn -> restore(:triage_namespace, previous) end)

    for legacy <- [nil, "", "   ", "operator-selected"] do
      Application.put_env(:bridge_for_teams_core, :triage_namespace, legacy)
      assert Triage.namespace() == {:ok, SalixStore.TriageKeys.default_namespace()}
    end
  end

  # ---- org scoping ----

  test "bucket rows outside the org are dropped and counted", %{
    org: org,
    project: project,
    namespace: namespace
  } do
    group = project.salix_group_id

    use_stub(%{
      {:posture, group} => {:ok, [posture("mine")]},
      {:buckets, namespace, nil, 25} =>
        {:ok,
         %{
           buckets: [bucket("mine"), bucket("theirs"), %{bucket("orphan") | connect_id: nil}],
           invalid_count: 1,
           next_cursor: "v1.abc",
           scan_complete: false
         }}
    })

    use_namespace(namespace)

    assert {:ok, page} = Triage.list_buckets(org.id)

    assert Enum.map(page.buckets, & &1.connect_id) == ["mine"]
    # "theirs" belongs to another org; the orphan bucket has no open receipt to
    # attribute, so neither may render here. Every group answered, so both
    # drops are confirmed foreign rather than merely unchecked.
    assert page.foreign_count == 2
    assert page.unattributed_count == 0
    # The read model's own honest-scan count passes through untouched.
    assert page.invalid_count == 1
    assert page.next_cursor == "v1.abc"
    assert page.scan_complete == false
    assert page.scope_complete == true

    assert page.owners == %{
             "mine" => %{group_id: group, project_id: project.id, project_name: "Bridge"}
           }
  end

  test "receipt rows outside the org are dropped and counted", %{
    org: org,
    project: project,
    namespace: namespace
  } do
    cursor = "v1.cursor-#{unique()}"

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("mine")]},
      {:receipts, cursor} =>
        {:ok,
         %{
           receipts: [receipt("mine"), receipt("theirs")],
           connect_ids: ["mine", "theirs"],
           legacy_count: 2,
           invalid_count: 0,
           unavailable_count: 1,
           next_cursor: nil,
           scan_complete: true,
           scanned_count: 2
         }}
    })

    use_namespace(namespace)

    assert {:ok, page} = Triage.list_receipts(org.id, cursor)

    assert Enum.map(page.receipts, & &1["connect_id"]) == ["mine"]
    assert page.connect_ids == ["mine"]
    assert page.foreign_count == 1
    # Scan-health counts describe the unfiltered page and are not org content.
    assert page.legacy_count == 2
    assert page.unavailable_count == 1
  end

  test "recent window rows outside the org are dropped and counted", %{
    org: org,
    project: project,
    namespace: namespace
  } do
    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("mine")]},
      {:window, namespace, 100, []} =>
        {:ok,
         %{
           receipts: [receipt("theirs"), receipt("mine")],
           scanned_pages: 3,
           legacy_count: 0,
           invalid_count: 0,
           unavailable_count: 2,
           truncated: true
         }}
    })

    use_namespace(namespace)

    assert {:ok, window} = Triage.recent_window(org.id, 100)
    assert Enum.map(window.receipts, & &1["connect_id"]) == ["mine"]
    assert window.foreign_count == 1
    assert window.truncated == true
    # The read model's partial-read count is scan health, not org content: it
    # passes through unfiltered, so the UI can warn that the window has holes.
    assert window.unavailable_count == 2
  end

  test "recent processing is org-scoped, owner-decorated, and preserves scan honesty", %{
    org: org,
    project: project,
    namespace: namespace
  } do
    item = fn connect_id, state ->
      %{
        state: state,
        receipt_ref: "receipt://#{connect_id}",
        receipt_count: 2,
        connect_id: connect_id,
        received_at_ms: 100,
        observed_at_ms: 200,
        terminal_status: nil,
        suggested_action: nil
      }
    end

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("mine")]},
      {:processing, namespace, 100, [page_budget: 2, limit: 10]} =>
        {:ok,
         %{
           items: [item.("theirs", :terminal), item.("mine", :evaluating)],
           scanned_pages: 2,
           legacy_count: 1,
           invalid_count: 2,
           unavailable_count: 3,
           state_unavailable_count: 4,
           truncated: true
         }}
    })

    assert {:ok, page} =
             Triage.recent_processing(org.id, 100, page_budget: 2, limit: 10)

    assert [%{connect_id: "mine", state: :evaluating, owner: owner}] = page.items

    assert owner == %{
             group_id: project.salix_group_id,
             project_id: project.id,
             project_name: "Bridge"
           }

    assert page.owners == %{"mine" => owner}
    assert page.scope_complete
    assert page.unavailable_groups == []
    assert page.foreign_count == 1
    assert page.unattributed_count == 0
    assert page.scanned_pages == 2
    assert page.unavailable_count == 3
    assert page.state_unavailable_count == 4
    assert page.truncated
  end

  test "internal feedback persists and rechecks reviewer, agent and exact source ownership", %{
    org: org,
    project: project,
    owner: owner
  } do
    {:ok, [agent | _]} = Triage.router_agents(org.id)
    id = "feedback-outcome"

    key =
      {:product_activity, project.id, project.salix_group_id, agent.agent_id,
       [page: true, obligation_id: id, limit: 1, context_limit: 0]}

    use_stub(%{key => {:ok, %{outcomes: [%{obligation_id: id}], context: []}}})

    assert {:ok, saved} =
             Triage.add_feedback(org, agent, owner.id, "outcome", id, %{
               "score" => "4",
               "comment" => "Useful answer; missing the source link",
               "reviewer_id" => Ecto.UUID.generate()
             })

    assert saved.reviewer_id == owner.id
    assert saved.score == 4

    assert {:ok, %{items: [review], truncated: false}} =
             Triage.feedback(org, agent, owner.id, "outcome", id)

    assert review.id == saved.id
    assert review.comment == "Useful answer; missing the source link"

    assert {:error, %Ecto.Changeset{}} =
             Triage.add_feedback(org, agent, owner.id, "outcome", id, %{"score" => "6"})

    assert {:error, %Ecto.Changeset{}} =
             Triage.add_feedback(org, agent, owner.id, "outcome", id, %{
               "comment" => String.duplicate("x", 4001)
             })

    assert {:error, %Ecto.Changeset{}} =
             Triage.add_feedback(org, agent, owner.id, "outcome", id, %{"comment" => " "})

    {:ok, member} = Accounts.create_user(%{email: "feedback-member-#{unique()}@example.com"})
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    assert {:error, _} = Triage.feedback(org, agent, member.id, "outcome", id)

    assert {:error, _} =
             Triage.add_feedback(org, agent, member.id, "outcome", id, %{"score" => "5"})

    assert {:error, :agent_not_found} =
             Triage.add_feedback(
               org,
               %{agent | project_id: Ecto.UUID.generate()},
               owner.id,
               "outcome",
               id,
               %{"score" => "5"}
             )

    Stub.put(key, {:ok, %{outcomes: [%{obligation_id: "different-source"}], context: []}})

    assert {:error, :subject_not_found} =
             Triage.add_feedback(org, agent, owner.id, "outcome", id, %{"score" => "5"})

    assert {:error, :subject_not_found} = Triage.feedback(org, agent, owner.id, "outcome", id)
  end

  test "follow-up feedback uses an exact authorized entry rather than the recent context window",
       %{org: org, project: project, owner: owner} do
    {:ok, [agent | _]} = Triage.router_agents(org.id)
    id = "older-follow-up"

    key =
      {:product_activity, project.id, project.salix_group_id, agent.agent_id,
       [page: true, context_entry_id: id, limit: 1, context_limit: 1]}

    use_stub(%{key => {:ok, %{outcomes: [], context: [%{entry_id: id, kind: "follow_up"}]}}})

    assert {:ok, _} =
             Triage.add_feedback(org, agent, owner.id, "follow_up", id, %{
               "comment" => "Check the eventual result"
             })

    assert {:ok, %{items: [review]}} = Triage.feedback(org, agent, owner.id, "follow_up", id)
    assert is_nil(review.score)
    Stub.put(key, {:ok, %{outcomes: [], context: [%{entry_id: id, kind: "project_fact"}]}})

    assert {:error, :subject_not_found} =
             Triage.add_feedback(org, agent, owner.id, "follow_up", id, %{"score" => "2"})
  end

  test "product activity is bound to the selected org Agent and crosses the seam uncached", %{
    org: org,
    project: project
  } do
    {:ok, [agent | _rest]} = Triage.router_agents(org.id)

    activity = %{
      outcomes: [%{event_ref: "triage-public-event"}],
      context: [%{context_ref: "triage-public-context"}]
    }

    key =
      {:product_activity, project.id, project.salix_group_id, agent.agent_id,
       [limit: 4, context_limit: 5]}

    use_stub(%{key => {:ok, activity}})

    assert {:ok, ^activity} =
             Triage.product_activity(org.id, agent,
               limit: 4,
               context_limit: 5
             )

    assert {:ok, ^activity} =
             Triage.product_activity(org.id, agent,
               limit: 4,
               context_limit: 5
             )

    assert Stub.calls(key) == 2

    refute Triage.product_activity(org.id, %{agent | agent_id: Ecto.UUID.generate()}) ==
             {:ok, activity}

    assert {:error, :agent_not_found} =
             Triage.product_activity(org.id, %{agent | project_id: Ecto.UUID.generate()})

    {:ok, foreign_org} =
      Orgs.create_org(%{name: "Foreign", slug: "foreign-#{unique()}"})

    assert {:error, :agent_not_found} = Triage.product_activity(foreign_org.id, agent)
    assert Stub.calls(key) == 2
  end

  test "the product heatmap is bound to the selected org Agent and cached per Agent", %{
    org: org,
    project: project
  } do
    {:ok, [agent | _rest]} = Triage.router_agents(org.id)
    heatmap = %{since_ms: 0, bucket_ms: 3_600_000, cells: [], truncated: false}
    key = {:product_heatmap, project.id, project.salix_group_id, agent.agent_id}

    use_stub(%{key => {:seq, [{:error, :unavailable}, {:ok, heatmap}]}})

    # An error is not cached, so the next read crosses the seam again.
    assert {:error, :unavailable} = Triage.product_heatmap(org.id, agent)
    assert {:ok, ^heatmap} = Triage.product_heatmap(org.id, agent)
    assert {:ok, ^heatmap} = Triage.product_heatmap(org.id, agent)
    assert Stub.calls(key) == 2

    {:ok, foreign_org} = Orgs.create_org(%{name: "Foreign", slug: "foreign-#{unique()}"})

    assert {:error, :agent_not_found} = Triage.product_heatmap(foreign_org.id, agent)

    assert {:error, :agent_not_found} =
             Triage.product_heatmap(org.id, %{agent | project_id: Ecto.UUID.generate()})

    assert Stub.calls(key) == 2
  end

  test "processing detail reauthorizes the current org Agent before reading one receipt", %{
    org: org,
    project: project
  } do
    {:ok, [agent | _]} = Triage.router_agents(org.id)
    key = {:processing_detail, project.salix_group_id, "receipt"}
    detail = %{state: :terminal, terminal_status: "failed"}
    use_stub(%{key => {:ok, detail}})
    assert {:ok, ^detail} = Triage.processing_detail(org.id, agent, "receipt")
    assert Stub.calls(key) == 1
    {:ok, foreign_org} = Orgs.create_org(%{name: "Foreign", slug: "foreign-#{unique()}"})
    assert {:error, :agent_not_found} = Triage.processing_detail(foreign_org.id, agent, "receipt")

    assert {:error, :agent_not_found} =
             Triage.processing_detail(org.id, %{agent | group_id: "another-group"}, "receipt")

    assert Stub.calls(key) == 1
  end

  test "delegation Task lookup reauthorizes the selected org Agent and reads one exact slot uncached",
       %{
         org: org,
         project: project
       } do
    {:ok, [agent | _rest]} = Triage.router_agents(org.id)
    obligation_id = "triage-product-" <> String.duplicate("d", 64)
    key = {:delegation_task, project.id, project.salix_group_id, agent.agent_id, obligation_id, 1}

    task = %{
      "disposition" => "created",
      "conversation_id" => SalixStore.Ids.new_conversation_id()
    }

    use_stub(%{key => {:ok, task}})

    assert {:ok, ^task} = Triage.delegation_task(org.id, agent, obligation_id, 1)
    assert {:ok, ^task} = Triage.delegation_task(org.id, agent, obligation_id, 1)
    assert Stub.calls(key) == 2

    for selected <- [
          %{agent | agent_id: Ecto.UUID.generate()},
          %{agent | project_id: Ecto.UUID.generate()},
          %{agent | group_id: SalixStore.Ids.new_group_id(SalixStore.Ids.new_tenant_id())}
        ] do
      assert {:error, :agent_not_found} =
               Triage.delegation_task(org.id, selected, obligation_id, 1)
    end

    {:ok, foreign_org} = Orgs.create_org(%{name: "Foreign", slug: "foreign-#{unique()}"})

    assert {:error, :agent_not_found} =
             Triage.delegation_task(foreign_org.id, agent, obligation_id, 1)

    assert Stub.calls(key) == 2
  end

  test "delegation Task lookup preserves unavailable and uncreated owner facts without mutation",
       %{
         org: org,
         project: project
       } do
    {:ok, [agent | _rest]} = Triage.router_agents(org.id)
    obligation_id = "triage-product-" <> String.duplicate("e", 64)
    key = {:delegation_task, project.id, project.salix_group_id, agent.agent_id, obligation_id, 0}
    use_stub()

    for result <- [
          {:ok, %{"disposition" => "not_created"}},
          {:ok, %{"disposition" => "reserved_task_unavailable"}},
          {:error, :not_found},
          {:error, :unavailable}
        ] do
      Stub.put(key, result)
      assert Triage.delegation_task(org.id, agent, obligation_id, 0) == result
    end

    assert Stub.calls(key) == 4

    for {ref, index} <- [{"", 0}, {nil, 0}, {obligation_id, -1}, {obligation_id, 2}] do
      assert {:error, :invalid_delegation} = Triage.delegation_task(org.id, agent, ref, index)
    end

    assert Stub.calls(key) == 4
  end

  test "delegation Task lookup rejects a selected Agent removed after the Timeline read", %{
    org: org,
    project: project
  } do
    {:ok, [agent | _rest]} = Triage.router_agents(org.id)
    obligation_id = "triage-product-" <> String.duplicate("f", 64)
    key = {:delegation_task, project.id, project.salix_group_id, agent.agent_id, obligation_id, 0}
    use_stub(%{key => {:ok, %{"disposition" => "not_created"}}})

    {:ok, record} = BridgeForTeams.Agents.get_agent(agent.agent_id)
    archive_agent_fixture!(record)

    assert {:error, :agent_not_found} = Triage.delegation_task(org.id, agent, obligation_id, 0)
    assert Stub.calls(key) == 0
  end

  test "a bucket belonging to another org reads as :not_found", %{
    org: org,
    project: project,
    namespace: namespace
  } do
    key = "ctl/im_triage/x/buckets/theirs.json"

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("mine")]},
      {:bucket, namespace, key} => {:ok, bucket("theirs")}
    })

    use_namespace(namespace)

    assert {:error, :not_found} = Triage.get_bucket(org.id, key)

    mine_key = "ctl/im_triage/x/buckets/mine.json"
    Stub.put({:bucket, namespace, mine_key}, {:ok, bucket("mine")})

    assert {:ok, %{owner: owner}} = Triage.get_bucket(org.id, mine_key)
    assert owner.project_id == project.id
  end

  test "a group whose posture is unavailable leaves the scope incomplete", %{
    org: org,
    project: project,
    namespace: namespace
  } do
    {:ok, other} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        name: "Sick",
        slug: "sick-#{unique()}"
      })

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("mine")]},
      {:posture, other.salix_group_id} => {:error, :unavailable},
      {:buckets, namespace, nil, 25} =>
        {:ok,
         %{
           buckets: [bucket("mine")],
           invalid_count: 0,
           next_cursor: nil,
           scan_complete: true
         }}
    })

    use_namespace(namespace)

    assert {:ok, page} = Triage.list_buckets(org.id)
    # The sick group contributed no connects, so its rows are indistinguishable
    # from another org's: the page must say so rather than render a quietly
    # short list.
    assert page.scope_complete == false
    assert [%{project_id: sick_id, reason: :unavailable}] = page.unavailable_groups
    assert sick_id == other.id

    assert {:ok, %{scope_complete: false, connects: [%{connect_id: "mine"}]}} =
             Triage.connect_posture(org.id)
  end

  test "drops taken while the scope is incomplete are unattributed, never foreign", %{
    org: org,
    project: project,
    namespace: namespace
  } do
    {:ok, other} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        name: "Sick",
        slug: "sick-#{unique()}"
      })

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("mine")]},
      {:posture, other.salix_group_id} => {:error, :unavailable},
      {:buckets, namespace, nil, 25} =>
        {:ok,
         %{
           buckets: [bucket("mine"), bucket("maybe-theirs")],
           invalid_count: 0,
           next_cursor: nil,
           scan_complete: true
         }}
    })

    use_namespace(namespace)

    assert {:ok, page} = Triage.list_buckets(org.id)

    assert Enum.map(page.buckets, & &1.connect_id) == ["mine"]
    # The sick group's connects are missing from the join, so "maybe-theirs"
    # may well be this org's own row. Calling it foreign would state something
    # the join never established.
    assert page.foreign_count == 0
    assert page.unattributed_count == 1
    assert page.scope_complete == false
  end

  test "posture carries the owning project onto each connect", %{org: org, project: project} do
    use_stub(%{{:posture, project.salix_group_id} => {:ok, [posture("mine")]}})

    assert {:ok, %{connects: [connect]}} = Triage.connect_posture(org.id)
    assert connect.connect_id == "mine"
    assert connect.project_id == project.id
    assert connect.project_name == "Bridge"
    assert connect.group_id == project.salix_group_id
    # Display fields only — the posture projection never carries a credential.
    refute Map.has_key?(connect, :bot_token)
  end

  test "channel discovery is scoped to one org connect and briefly cached", %{
    org: org,
    project: project
  } do
    key = {:channels, project.salix_group_id, "mine", nil, 100}

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("mine")]},
      key =>
        {:ok,
         %{
           channels: [
             %{id: "C1", name: "general", private?: false, shared?: false, member?: true}
           ],
           next_cursor: "next"
         }}
    })

    ref = %{
      connect_id: "mine",
      project_id: project.id,
      group_id: project.salix_group_id
    }

    assert {:ok, page} = Triage.list_slack_channels(org, ref)

    assert page.channels == [
             %{id: "C1", name: "general", private?: false, shared?: false, member?: true}
           ]

    assert page.next_cursor == "next"

    assert {:ok, ^page} = Triage.list_slack_channels(org, ref)
    assert Stub.calls(key) == 1

    assert {:error, :connect_not_found} =
             Triage.list_slack_channels(org, %{connect_id: "foreign"})

    assert {:error, :invalid_channel_cursor} =
             Triage.list_slack_channels(org, ref, " cursor-with-spaces ")

    refute Stub.calls({:channels, project.salix_group_id, "foreign", nil, 100}) > 0
  end

  # ---- caching ----

  test "posture reads are served from the cache", %{org: org, project: project} do
    use_stub(%{{:posture, project.salix_group_id} => {:ok, [posture("mine")]}})

    assert {:ok, _} = Triage.connect_posture(org.id)
    assert {:ok, _} = Triage.connect_posture(org.id)
    assert Stub.calls({:posture, project.salix_group_id}) == 1
  end

  # The whole assembled scope is the cache entry, and a failed group is part of
  # a perfectly successful scope. That is what bounds the fan-out: a Salix
  # outage costs one build per TTL rather than one per card, without ever
  # caching an `{:error, _}` — the scan reads below still refuse to.
  test "a failed group rides inside the cached scope instead of re-firing per card", %{
    org: org,
    project: project,
    namespace: namespace
  } do
    {:ok, down} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        name: "Down",
        slug: "down-#{unique()}"
      })

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("mine")]},
      {:posture, down.salix_group_id} => {:error, :unavailable}
    })

    use_namespace(namespace)

    assert {:ok, result} = Triage.connect_posture(org.id)
    refute result.scope_complete
    assert [%{group_id: group_id}] = result.unavailable_groups
    assert group_id == down.salix_group_id

    # Three more scope consumers on the same render, all served from the one
    # build: the switch card again, the recent window, and the receipt scan.
    assert {:ok, _} = Triage.connect_posture(org.id)
    assert {:error, :unavailable} = Triage.recent_window(org.id, 100)
    assert {:error, :unavailable} = Triage.list_receipts(org.id)

    assert Stub.calls({:posture, down.salix_group_id}) == 1
    assert Stub.calls({:posture, project.salix_group_id}) == 1
  end

  # A group the fan-out could not reach in time is reported, never dropped: the
  # bound is allowed to cost completeness, not honesty.
  test "a slow Salix costs one bounded fan-out, and every unreached group is named", %{
    org: org,
    project: project
  } do
    slow =
      for i <- 1..23 do
        {:ok, down} =
          BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
            name: "Down #{i}",
            slug: "down-#{unique()}"
          })

        down
      end

    groups = [project.salix_group_id | Enum.map(slow, & &1.salix_group_id)]

    use_stub(Map.new(groups, &{{:posture, &1}, {:slow, 30_000, {:error, :unavailable}}}))

    {elapsed_us, {:ok, result}} = :timer.tc(fn -> Triage.connect_posture(org.id) end)

    # 24 sequential 30s reads would be twelve minutes. The bound is one
    # per-group timeout, and it does not move with the project count.
    assert div(elapsed_us, 1000) < 15_000

    issued = Enum.count(groups, &(Stub.calls({:posture, &1}) > 0))
    assert issued <= 16, "#{issued} posture reads issued for #{length(groups)} groups"
    assert issued < length(groups)

    # Every project is still accounted for — the ones that answered and the
    # ones the deadline cut off — so the page can name what it could not check.
    refute result.scope_complete
    assert Enum.sort(Enum.map(result.unavailable_groups, & &1.group_id)) == Enum.sort(groups)
  end

  test "scan reads are served from the cache", %{
    org: org,
    project: project,
    namespace: namespace
  } do
    cursor = "v1.cursor-#{unique()}"

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("mine")]},
      {:receipts, cursor} =>
        {:ok,
         %{
           receipts: [receipt("mine")],
           connect_ids: ["mine"],
           legacy_count: 0,
           invalid_count: 0,
           unavailable_count: 0,
           next_cursor: nil,
           scan_complete: true,
           scanned_count: 1
         }}
    })

    use_namespace(namespace)

    assert {:ok, _} = Triage.list_receipts(org.id, cursor)
    assert {:ok, _} = Triage.list_receipts(org.id, cursor)
    assert Stub.calls({:receipts, cursor}) == 1
  end

  test "a scan fault is never cached, so recovery is visible immediately", %{
    org: org,
    project: project,
    namespace: namespace
  } do
    cursor = "v1.cursor-#{unique()}"

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("mine")]},
      {:receipts, cursor} =>
        {:seq,
         [
           {:error, :unavailable},
           {:ok,
            %{
              receipts: [receipt("mine")],
              connect_ids: ["mine"],
              legacy_count: 0,
              invalid_count: 0,
              unavailable_count: 0,
              next_cursor: nil,
              scan_complete: true,
              scanned_count: 1
            }}
         ]}
    })

    use_namespace(namespace)

    assert {:error, :unavailable} = Triage.list_receipts(org.id, cursor)

    # Inside the 5s scan TTL. A cached error would pin the failed scan for the
    # whole window and hide a Salix that has already come back.
    assert {:ok, page} = Triage.list_receipts(org.id, cursor)
    assert Enum.map(page.receipts, & &1["connect_id"]) == ["mine"]
    assert Stub.calls({:receipts, cursor}) == 2
  end

  # ---- writes ----

  test "enabling a connect calls Salix, re-reads the posture, and audits the change", %{
    org: org,
    project: project,
    owner: owner
  } do
    group = project.salix_group_id

    use_stub(%{
      {:posture, group} =>
        {:seq,
         [
           {:ok, [posture("mine", %{triage_enabled: false, connect_generation: "gen-1"})]},
           {:ok, [posture("mine", %{triage_enabled: true, connect_generation: "gen-2"})]}
         ]}
    })

    assert {:ok, later} =
             Triage.set_connect_triage(org, owner, %{connect_id: "mine"}, :enable,
               request_id: "req-triage-enable"
             )

    assert later.triage_enabled == true
    assert later.project_id == project.id
    assert Stub.calls({:set_enabled, group, "mine", true}) == 1

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "integration.slack.triage_enabled")

    assert audit.result == "ok"
    assert audit.actor_user_id == owner.id
    assert audit.resource_type == "project_im_connect_triage"
    assert audit.resource_id == "mine"
    assert audit.request_id == "req-triage-enable"

    # `Observability` normalizes atoms to strings on the way into the audit
    # payload, and booleans are atoms — so the stored old→new evidence is
    # `"true"`/`"false"`, not `true`/`false`.
    assert %{
             "action" => "enabled",
             "connect_id" => "mine",
             "triage_enabled_before" => "false",
             "triage_enabled_after" => "true",
             "provisioned_before" => "true",
             "provisioned_after" => "true",
             "connect_generation_rotated" => "true",
             "post_write_posture_observed" => "true"
           } = audit.metadata

    assert audit.metadata["project_id"] == project.id
    assert audit.metadata["group_id"] == group
  end

  test "provisioning uses the one-way door and audits it as provisioned", %{
    org: org,
    project: project,
    owner: owner
  } do
    group = project.salix_group_id

    use_stub(%{
      {:posture, group} =>
        {:ok, [posture("mine", %{provisioned?: false, approved_channel_id: nil})]}
    })

    assert {:ok, _} =
             Triage.set_connect_triage(org, owner, %{connect_id: "mine"}, {:provision, "C999"})

    assert Stub.calls({:provision, group, "mine", "C999"}) == 1

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "integration.slack.triage_provisioned")

    assert audit.metadata["action"] == "provisioned"
    # Never a message body, and not the channel id itself — only the posture.
    refute Map.has_key?(audit.metadata, "approved_channel_id")
    assert Map.has_key?(audit.metadata, "approved_channel_configured")
  end

  test "an org member is denied, the denial is audited, and Salix is never called", %{
    org: org,
    project: project
  } do
    {:ok, member} = Accounts.create_user(%{email: "member-#{unique()}@example.com"})
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

    use_stub(%{{:posture, project.salix_group_id} => {:ok, [posture("mine")]}})

    assert {:error, :forbidden} =
             Triage.set_connect_triage(org, member, %{connect_id: "mine"}, :enable)

    assert Stub.calls({:set_enabled, project.salix_group_id, "mine", true}) == 0

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "integration.slack.triage_enabled")

    assert audit.result == "denied"
    assert audit.reason_class == "forbidden"
    assert audit.actor_user_id == member.id
  end

  test "a connect outside the org is rejected without calling Salix", %{org: org, owner: owner} do
    use_stub()

    assert {:error, :connect_not_found} =
             Triage.set_connect_triage(org, owner, %{connect_id: "theirs"}, :enable)

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "integration.slack.triage_enabled")

    assert audit.result == "failed"
    assert audit.reason_class == "connect_not_found"
  end

  test "pinning the wrong project on a real connect is rejected", %{
    org: org,
    project: project,
    owner: owner
  } do
    {:ok, other} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        name: "Other",
        slug: "other-#{unique()}"
      })

    use_stub(%{{:posture, project.salix_group_id} => {:ok, [posture("mine")]}})

    assert {:error, :connect_not_found} =
             Triage.set_connect_triage(
               org,
               owner,
               %{connect_id: "mine", project_id: other.id},
               :enable
             )
  end

  test "an unavailable Salix write is returned and audited as failed", %{
    org: org,
    project: project,
    owner: owner
  } do
    group = project.salix_group_id

    use_stub(%{
      {:posture, group} => {:ok, [posture("mine")]},
      {:set_enabled, group, "mine", false} => {:error, :unavailable}
    })

    assert {:error, :unavailable} =
             Triage.set_connect_triage(org, owner, %{connect_id: "mine"}, :disable)

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "integration.slack.triage_disabled")

    assert audit.result == "failed"
    assert audit.reason_class == "unavailable"
  end

  test "a connect missing while a group is unreadable is transient, not gone", %{
    org: org,
    project: project,
    owner: owner
  } do
    {:ok, other} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        name: "Sick",
        slug: "sick-#{unique()}"
      })

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("mine")]},
      {:posture, other.salix_group_id} => {:error, :unavailable}
    })

    # The connect could be sitting in exactly the group that did not answer, so
    # `:connect_not_found` — which the UI renders as "no longer part of this
    # organization" — would be a claim about a connect nobody looked at.
    assert {:error, :unavailable} =
             Triage.set_connect_triage(org, owner, %{connect_id: "elsewhere"}, :enable)

    assert Stub.calls({:set_enabled, project.salix_group_id, "elsewhere", true}) == 0

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "integration.slack.triage_enabled")

    assert audit.result == "failed"
    assert audit.reason_class == "unavailable"

    # Pinning the ref to the healthy project narrows the question to a group
    # that *did* answer, so absence becomes provable again.
    assert {:error, :connect_not_found} =
             Triage.set_connect_triage(
               org,
               owner,
               %{connect_id: "elsewhere", project_id: project.id},
               :enable
             )
  end

  test "a successful write whose posture re-read fails still succeeds, and says it did not look",
       %{org: org, project: project, owner: owner} do
    group = project.salix_group_id

    use_stub(%{
      {:posture, group} =>
        {:seq, [{:ok, [posture("mine", %{triage_enabled: false})]}, {:error, :unavailable}]}
    })

    assert {:ok, result} =
             Triage.set_connect_triage(org, owner, %{connect_id: "mine"}, :enable)

    # The write landed; the re-read did not. The caller gets the pre-write
    # posture rather than an invented one.
    assert result.triage_enabled == false
    assert Stub.calls({:set_enabled, group, "mine", true}) == 1

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "integration.slack.triage_enabled")

    assert audit.result == "ok"
    # Unobserved, not "unchanged": the audit row must not imply the switch
    # failed to move when the truth is that nobody checked.
    assert audit.metadata["post_write_posture_observed"] == "false"
    assert audit.metadata["triage_enabled_before"] == "false"
    refute audit.metadata["triage_enabled_after"]
    refute audit.metadata["connect_generation_rotated"]
  end

  test "an org with no Salix tenant answers :tenant_not_ready", %{org: org, owner: owner} do
    use_stub()

    # The column is NOT NULL with a non-blank check, so this state cannot be
    # persisted today. It still reaches the context: callers hand it an
    # `%Organization{}` they already hold, and `fetch_org/1` passes a struct
    # through without re-reading it. The guard is the reason a half-provisioned
    # org degrades to a flash instead of fanning out over a nil tenant.
    org = %{org | salix_tenant_id: nil}

    assert {:error, :tenant_not_ready} = Triage.connect_posture(org)

    assert {:error, :tenant_not_ready} =
             Triage.set_connect_triage(org, owner, %{connect_id: "mine"}, :enable)

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "integration.slack.triage_enabled")

    assert audit.reason_class == "tenant_not_ready"
  end

  test "an unknown action never reaches Salix", %{org: org, owner: owner} do
    use_stub()

    assert {:error, :invalid_action} =
             Triage.set_connect_triage(org, owner, %{connect_id: "mine"}, :archive)

    assert {:error, :invalid_action} =
             Triage.set_connect_triage(org, owner, %{connect_id: "mine"}, {:provision, "  "})
  end

  # ---- ring ----

  test "ring status passes the salix_web process names through", %{org: _org} do
    refs = %{
      runtime: Salix.Bindings.TriageReviewRuntime,
      recovery: Salix.Bindings.TriageReceiptRecovery
    }

    use_stub(%{{:ring, refs} => {:ok, %{running: false, runtime: %{}, recovery: %{}}}})
    BridgeForTeams.Salix.ReadCache.invalidate(:triage_ring_status)

    assert {:ok, %{running: false}} = Triage.ring_status()
    assert Stub.calls({:ring, refs}) == 1
  end

  test "ring status binds readiness and cache invalidation to the selected Agent" do
    agent_id = "agt1_selected_router"

    refs = %{
      runtime: Salix.Bindings.TriageReviewRuntime,
      recovery: Salix.Bindings.TriageReceiptRecovery,
      evaluation_agent_id: agent_id
    }

    ring = fn readiness ->
      {:ok,
       %{
         running: readiness == :ready,
         evaluation_readiness: readiness,
         runtime: %{},
         recovery: %{cursor: nil}
       }}
    end

    use_stub(%{{:ring, refs} => {:seq, [ring.(:unavailable), ring.(:ready)]}})

    assert {:ok, %{evaluation_readiness: :unavailable}} = Triage.ring_status(agent_id)
    assert {:ok, %{evaluation_readiness: :unavailable}} = Triage.ring_status(agent_id)
    assert Stub.calls({:ring, refs}) == 1

    assert :ok = Triage.refresh_evaluation_status(agent_id)
    assert {:ok, %{evaluation_readiness: :ready}} = Triage.ring_status(agent_id)
    assert Stub.calls({:ring, refs}) == 2

    assert Triage.ring_status("  ") == {:error, :invalid_evaluation_agent}
    assert Triage.refresh_evaluation_status(%{}) == {:error, :invalid_evaluation_agent}
  end

  test "the ring's recovery cursor is replaced by an opaque token" do
    refs = %{
      runtime: Salix.Bindings.TriageReviewRuntime,
      recovery: Salix.Bindings.TriageReceiptRecovery
    }

    # The ring is deployment-wide, so its cursor names a record belonging to
    # whichever org it happens to be walking — here, not this one.
    raw_key = "ctl/im/slack/event_receipts/connect-of-another-org/Ev-1.json"
    cursor = "v1." <> Base.url_encode64(raw_key, padding: false)

    use_stub(%{
      {:ring, refs} =>
        {:ok,
         %{
           running: true,
           runtime: %{running: true, mode: :review, namespace: "ns"},
           recovery: %{running: true, phase: :resolve, cursor: cursor, pending_receipts: 2}
         }}
    })

    BridgeForTeams.Salix.ReadCache.invalidate(:triage_ring_status)

    assert {:ok, ring} = Triage.ring_status()

    refute Map.has_key?(ring.recovery, :cursor)
    assert ring.recovery.cursor_token == expected_cursor_token(cursor)
    assert ring.recovery.phase == :resolve
    assert ring.recovery.pending_receipts == 2

    rendered = inspect(ring)
    refute rendered =~ "connect-of-another-org"
    refute rendered =~ cursor
    refute rendered =~ "v1."
  end

  test "a ring with no cursor reports no token" do
    refs = %{
      runtime: Salix.Bindings.TriageReviewRuntime,
      recovery: Salix.Bindings.TriageReceiptRecovery
    }

    use_stub(%{
      {:ring, refs} => {:ok, %{running: false, runtime: %{}, recovery: %{cursor: nil}}}
    })

    BridgeForTeams.Salix.ReadCache.invalidate(:triage_ring_status)

    assert {:ok, %{recovery: %{cursor_token: nil}}} = Triage.ring_status()
  end

  test "manual refresh invalidates only the visible status query", %{
    org: org,
    project: project,
    namespace: namespace
  } do
    refs = %{
      runtime: Salix.Bindings.TriageReviewRuntime,
      recovery: Salix.Bindings.TriageReceiptRecovery
    }

    ring = fn readiness ->
      {:ok,
       %{
         running: readiness == :ready,
         evaluation_readiness: readiness,
         runtime: %{},
         recovery: %{cursor: nil}
       }}
    end

    projection = fn observed_at_ms ->
      {:ok,
       %{
         items: [
           %{
             state: :received,
             receipt_ref: "receipt://mine",
             receipt_count: 1,
             connect_id: "mine",
             received_at_ms: observed_at_ms,
             observed_at_ms: observed_at_ms,
             terminal_status: nil,
             suggested_action: nil
           }
         ],
         scanned_pages: 1,
         legacy_count: 0,
         invalid_count: 0,
         unavailable_count: 0,
         state_unavailable_count: 0,
         truncated: false
       }}
    end

    opts = [page_budget: 2, limit: 10]

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("mine")]},
      {:ring, refs} => {:seq, [ring.(:unknown), ring.(:ready)]},
      {:processing, namespace, 100, opts} => {:seq, [projection.(100), projection.(200)]}
    })

    assert {:ok, %{evaluation_readiness: :unknown}} = Triage.ring_status()

    assert {:ok, %{items: [%{observed_at_ms: 100}]}} =
             Triage.recent_processing(org, 100, opts)

    assert :ok = Triage.refresh_evaluation_status()
    assert {:ok, %{evaluation_readiness: :ready}} = Triage.ring_status()

    assert {:ok, %{items: [%{observed_at_ms: 100}]}} =
             Triage.recent_processing(org, 100, opts)

    assert Stub.calls({:ring, refs}) == 2
    assert Stub.calls({:processing, namespace, 100, opts}) == 1

    assert :ok = Triage.refresh_recent_processing(org, 100, opts)

    assert {:ok, %{items: [%{observed_at_ms: 200}]}} =
             Triage.recent_processing(org, 100, opts)

    assert {:ok, %{evaluation_readiness: :ready}} = Triage.ring_status()

    assert Stub.calls({:ring, refs}) == 2
    assert Stub.calls({:processing, namespace, 100, opts}) == 2
  end

  defp expected_cursor_token(cursor),
    do: :sha256 |> :crypto.hash(cursor) |> Base.encode16(case: :lower) |> binary_part(0, 8)

  # ---- router agents (Memory lens picker) ----

  test "router agents lists routers and never workers", %{org: org, project: project} do
    router = insert_agent(project, "router", "agt-router-#{unique()}")
    worker = insert_agent(project, "worker", "agt-worker-#{unique()}")

    assert {:ok, agents} = Triage.router_agents(org.id)

    ids = Enum.map(agents, & &1.agent_id)
    assert router.id in ids
    # Workers carry no semantic memory at all, so they must never reach the
    # Memory picker.
    refute worker.id in ids

    row = Enum.find(agents, &(&1.agent_id == router.id))
    assert row.salix_agent_id == router.salix_agent_id
    assert row.group_id == project.salix_group_id
    assert row.project_name == project.name
  end

  test "router agents answers a tagged error rather than an empty picker" do
    # The Memory tab renders this through the same fault component as every
    # other section: collapsing it to `[]` would put "no router agents" — a
    # statement about the org — on screen when the read simply failed.
    assert {:error, :not_found} = Triage.router_agents(Ecto.UUID.generate())
  end

  test "router agents does not need the review runtime", %{org: org} do
    use_namespace(nil)

    # `Projects.create_project/2` already provisions the group's router agent.
    assert {:ok, [_agent | _rest]} = Triage.router_agents(org.id)
  end

  # ---- text reveal audit ----

  test "a text reveal writes one audit row naming the receipt, never the text", %{
    org: org,
    owner: owner
  } do
    assert :ok =
             Triage.record_text_reveal(org, owner, "s3://ctl/im/slack/event_receipts/c/e.json",
               connect_id: "mine",
               surface: "triage_timeline",
               request_id: "req-reveal"
             )

    assert [audit] =
             Observability.list_audit_logs(org.id,
               action: "integration.slack.triage_text_revealed"
             )

    assert audit.result == "ok"
    assert audit.actor_user_id == owner.id
    assert audit.resource_type == "im_triage_message_text"
    assert audit.resource_id == "s3://ctl/im/slack/event_receipts/c/e.json"
    assert audit.request_id == "req-reveal"

    assert audit.metadata == %{
             "receipt_ref" => "s3://ctl/im/slack/event_receipts/c/e.json",
             "connect_id" => "mine",
             "surface" => "triage_timeline"
           }
  end

  test "a member's reveal is refused and the refusal is itself audited", %{org: org} do
    {:ok, member} = Accounts.create_user(%{email: "member-#{unique()}@example.com"})
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

    assert {:error, :forbidden} = Triage.record_text_reveal(org, member, "s3://receipt")

    assert [audit] =
             Observability.list_audit_logs(org.id,
               action: "integration.slack.triage_text_revealed"
             )

    assert audit.result == "denied"
    assert audit.reason_class == "forbidden"
    assert audit.resource_id == "s3://receipt"
  end

  test "a page of reveals is audited per message and stored together or not at all", %{
    org: org,
    owner: owner
  } do
    items = [
      %{receipt_ref: "s3://receipt-a", connect_id: "c-a"},
      %{receipt_ref: "s3://receipt-b", connect_id: "c-b"},
      %{receipt_ref: "s3://receipt-a", connect_id: "c-a"},
      %{receipt_ref: "  ", connect_id: "c-blank"}
    ]

    assert Triage.record_text_reveals(org, owner, items, surface: "triage_timeline") ==
             MapSet.new(["s3://receipt-a", "s3://receipt-b"])

    audits =
      Observability.list_audit_logs(org.id, action: "integration.slack.triage_text_revealed")

    assert audits |> Enum.map(&{&1.resource_id, &1.metadata["connect_id"]}) |> Enum.sort() ==
             [{"s3://receipt-a", "c-a"}, {"s3://receipt-b", "c-b"}]

    assert Enum.all?(audits, &(&1.result == "ok" and &1.actor_user_id == owner.id))

    # One invalid row keeps the whole batch out, so no message is shown unaudited.
    valid = %{org_id: org.id, action: "integration.slack.triage_text_revealed", result: "ok"}
    assert {:error, _reason} = Observability.record_audits([valid, %{org_id: org.id}])

    assert length(
             Observability.list_audit_logs(org.id,
               action: "integration.slack.triage_text_revealed"
             )
           ) == 2
  end

  test "a reveal whose audit row cannot be written is refused, not degraded to :ok", %{
    org: org,
    owner: owner
  } do
    use_failing_audit_writer()

    # The audit row is written *before* the text is shown, so it is the access
    # control's receipt and not a description of the past. Swallowing the
    # failure would hand raw Slack message text to an operator with no record
    # that anyone read it.
    assert {:error, :audit_unavailable} =
             Triage.record_text_reveal(org, owner, "s3://ctl/im/slack/event_receipts/c/e.json",
               connect_id: "mine",
               surface: "triage_timeline"
             )

    assert Observability.list_audit_logs(org.id,
             action: "integration.slack.triage_text_revealed"
           ) == []
  end

  test "a switch write whose audit row fails still succeeds", %{
    org: org,
    project: project,
    owner: owner
  } do
    use_stub(%{{:posture, project.salix_group_id} => {:ok, [posture("mine")]}})
    use_failing_audit_writer()

    # The mirror image of the reveal: the write already landed on the far side,
    # and failing the caller here would report a completed change as an error.
    assert {:ok, _later} = Triage.set_connect_triage(org, owner, %{connect_id: "mine"}, :enable)
    assert Stub.calls({:set_enabled, project.salix_group_id, "mine", true}) == 1
  end

  test "a blank or oversized receipt ref never reaches the audit log", %{org: org, owner: owner} do
    assert {:error, :invalid_receipt_ref} = Triage.record_text_reveal(org, owner, "   ")
    assert {:error, :invalid_receipt_ref} = Triage.record_text_reveal(org, owner, nil)

    assert {:error, :invalid_receipt_ref} =
             Triage.record_text_reveal(org, owner, String.duplicate("a", 513))

    assert Observability.list_audit_logs(org.id,
             action: "integration.slack.triage_text_revealed"
           ) == []
  end

  # ---- memory read audit ----

  test "a memory read attempt writes one audit row naming the agent and the path", %{
    org: org,
    project: project,
    owner: owner
  } do
    agent = %{
      agent_id: "agent-uuid",
      salix_agent_id: "agt-router",
      group_id: project.salix_group_id,
      project_id: project.id,
      project_name: project.name
    }

    assert {:ok, "req-memory"} =
             Triage.record_memory_read_attempt(org, owner, agent, "/memory/semantic/team.md",
               surface: "triage_memory",
               request_id: "req-memory"
             )

    assert [audit] = memory_audits(org)

    # "ok" scores the *attempt*: the row is written before the seam is asked
    # for the body, so this says the access was authorized and the body
    # requested — the fetch's own outcome is a separate row.
    assert audit.result == "ok"
    assert audit.actor_user_id == owner.id
    assert audit.resource_type == "im_triage_agent_memory"
    assert audit.resource_id == "/memory/semantic/team.md"
    assert audit.request_id == "req-memory"

    # The file is named by `resource_id` above and deliberately not repeated in
    # metadata: `Observability` redacts every path-shaped metadata key, so a
    # `"path"` entry here would store `[REDACTED]` and name nothing.
    assert audit.metadata == %{
             "agent_id" => "agent-uuid",
             "salix_agent_id" => "agt-router",
             "project_id" => project.id,
             "group_id" => project.salix_group_id,
             "surface" => "triage_memory"
           }
  end

  test "a memory path is audited byte for byte, never trimmed to another file", %{
    org: org,
    owner: owner
  } do
    # Salix's workspace normalization only prepends a leading slash and keeps
    # the rest verbatim, so `"/memory/x.md "` is an ordinary, creatable VFS key
    # and a *different* file from `"/memory/x.md"`. Trimming here would name one
    # file in the row while the caller fetched the other.
    assert {:ok, _request_id} =
             Triage.record_memory_read_attempt(org, owner, %{agent_id: "a"}, "/memory/x.md ")

    assert [audit] = memory_audits(org)
    assert audit.resource_id == "/memory/x.md "
  end

  test "a memory fetch that failed is audited as failed, under the attempt's request id", %{
    org: org,
    project: project,
    owner: owner
  } do
    agent = %{
      agent_id: "agent-uuid",
      salix_agent_id: "agt-router",
      group_id: project.salix_group_id,
      project_id: project.id,
      project_name: project.name
    }

    assert {:ok, request_id} =
             Triage.record_memory_read_attempt(org, owner, agent, "/memory/gone.md",
               surface: "triage_memory"
             )

    assert :ok =
             Triage.record_memory_read_failure(
               org,
               owner,
               agent,
               "/memory/gone.md",
               :not_found,
               surface: "triage_memory",
               request_id: request_id
             )

    # Both rows belong to one operator action, and the pair says what happened:
    # the access was authorized, and then nothing was fetched or rendered.
    assert [failure, attempt] = Enum.sort_by(memory_audits(org), & &1.result)
    assert attempt.result == "ok"
    assert failure.result == "failed"
    assert attempt.request_id == request_id
    assert failure.request_id == request_id
    assert failure.reason_class == "not_found"
    assert failure.resource_id == "/memory/gone.md"
    assert failure.metadata["agent_id"] == "agent-uuid"
    # And the file's contents are nowhere in either row.
    refute Enum.any?(memory_audits(org), &(&1.metadata["body"] != nil))
  end

  test "a member's memory read is refused and the refusal is itself audited", %{org: org} do
    {:ok, member} = Accounts.create_user(%{email: "member-#{unique()}@example.com"})
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

    assert {:error, :forbidden} =
             Triage.record_memory_read_attempt(org, member, %{agent_id: "a"}, "/memory/x.md")

    assert [audit] = memory_audits(org)

    assert audit.result == "denied"
    assert audit.reason_class == "forbidden"
    assert audit.resource_id == "/memory/x.md"
  end

  test "a memory read whose audit row cannot be written is refused, not degraded to :ok", %{
    org: org,
    owner: owner
  } do
    use_failing_audit_writer()

    # Same contract as the text reveal: the row is the price of the content,
    # and the caller must not render a `/memory` body without one.
    assert {:error, :audit_unavailable} =
             Triage.record_memory_read_attempt(org, owner, %{agent_id: "a"}, "/memory/x.md")

    assert memory_audits(org) == []
  end

  test "a blank agent or path never reaches the memory audit log", %{org: org, owner: owner} do
    assert {:error, :invalid_memory_agent} =
             Triage.record_memory_read_attempt(org, owner, %{agent_id: "  "}, "/memory/x.md")

    assert {:error, :invalid_memory_agent} =
             Triage.record_memory_read_attempt(org, owner, nil, "/memory/x.md")

    assert {:error, :invalid_memory_path} =
             Triage.record_memory_read_attempt(org, owner, %{agent_id: "a"}, "   ")

    assert {:error, :invalid_memory_path} =
             Triage.record_memory_read_attempt(org, owner, %{agent_id: "a"}, nil)

    assert {:error, :invalid_memory_path} =
             Triage.record_memory_read_attempt(
               org,
               owner,
               %{agent_id: "a"},
               String.duplicate("a", 1025)
             )

    assert {:error, :invalid_memory_path} =
             Triage.record_memory_read_failure(org, owner, %{agent_id: "a"}, "  ", :not_found)

    assert memory_audits(org) == []
  end

  defp memory_audits(org) do
    Observability.list_audit_logs(org.id,
      action: "integration.slack.triage_memory_read_attempted"
    )
  end

  defp insert_agent(project, role, _salix_agent_id) do
    {:ok, agent} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(
        project.id,
        %{role: role, name: "#{role}-#{unique()}"}
      )

    agent
  end
end
