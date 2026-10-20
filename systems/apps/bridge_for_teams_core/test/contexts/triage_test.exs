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
          SystemsClock.sleep(ms)
          result

        result ->
          result
      end
    end

    def triage_recent_window(namespace, since_ms, opts),
      do: Stub.call({:window, namespace, since_ms, opts}, {:error, :unavailable})

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

  defp unique, do: SystemsRuntime.Proc.unique_integer([:positive])

  defp use_stub(responses \\ %{}) do
    if :ets.whereis(BridgeForTeams.Salix.ReadCache) != :undefined,
      do: :ets.delete_all_objects(BridgeForTeams.Salix.ReadCache)

    start_supervised!({Stub, responses})
    prev = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, StubClient)
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
    prev = SystemsRuntime.get_env(:bridge_for_teams_core, :triage_audit_writer)

    SystemsRuntime.put_env(:bridge_for_teams_core, :triage_audit_writer, fn _attrs ->
      {:error, :audit_store_down}
    end)

    on_exit(fn -> restore(:triage_audit_writer, prev) end)
    :ok
  end

  defp restore(key, nil), do: SystemsRuntime.delete_env(:bridge_for_teams_core, key)
  defp restore(key, value), do: SystemsRuntime.put_env(:bridge_for_teams_core, key, value)

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

  defp window(receipts) do
    %{
      receipts: receipts,
      scanned_pages: 1,
      legacy_count: 0,
      invalid_count: 0,
      unavailable_count: 0,
      truncated: false
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

  # ---- org scoping ----

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

    refute Triage.product_activity(org.id, %{agent | agent_id: SystemsRuntime.Proc.uuid()}) ==
             {:ok, activity}

    assert {:error, :agent_not_found} =
             Triage.product_activity(org.id, %{agent | project_id: SystemsRuntime.Proc.uuid()})

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
             Triage.product_heatmap(org.id, %{agent | project_id: SystemsRuntime.Proc.uuid()})

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
          %{agent | agent_id: SystemsRuntime.Proc.uuid()},
          %{agent | project_id: SystemsRuntime.Proc.uuid()},
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

  # ---- ring ----

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

  defp expected_cursor_token(cursor),
    do: :sha256 |> :crypto.hash(cursor) |> Base.encode16(case: :lower) |> binary_part(0, 8)

  # ---- router agents (Agent picker) ----

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
end
