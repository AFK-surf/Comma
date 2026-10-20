defmodule SalixIM.TriageReadModelTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:triage_product_effects]

  use SalixAgent.TestSupport.Settle
  alias SalixIM.Provider.Slack.EndpointRevision
  alias SalixIM.{ProviderConnects, ProviderReceipts}

  alias SalixIM.Triage.{
    Bucketing,
    CanonicalJSON,
    Ledger,
    Pipeline,
    ReadModel,
    ReceiptRecovery,
    RunFence,
    Runtime
  }

  alias SalixStore.{
    CasRecord,
    Crypto,
    Ids,
    Keys,
    Repo,
    S3,
    TriageProductRuntime,
    ULID
  }

  # A page that comes back reordered and that ignores `start_after` is an
  # unavailable-shaped page, not an empty one: the scan must refuse it instead
  # of re-serving keys the cursor already passed.
  defmodule NonAdvancingS3 do
    @behaviour SalixStore.S3

    alias SalixStore.S3.Fake

    @impl true
    def list(prefix, opts) do
      case Fake.list(prefix, Keyword.delete(opts, :start_after)) do
        {:ok, %{objects: objects} = page} -> {:ok, %{page | objects: Enum.reverse(objects)}}
        other -> other
      end
    end

    @impl true
    defdelegate put(key, body, opts), to: Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: Fake

    @impl true
    defdelegate get(key, opts), to: Fake

    @impl true
    defdelegate stream(key, opts), to: Fake

    @impl true
    defdelegate head(key), to: Fake

    @impl true
    defdelegate delete(key, opts), to: Fake

    @impl true
    defdelegate multipart_create(key, opts), to: Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body), to: Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: Fake

    @impl true
    defdelegate multipart_uploads(prefix, opts), to: Fake
  end

  # Injects a GET fault on one exact key, after an allowance of successful
  # reads. `SalixStore.S3` dispatches in the caller's process, so the allowance
  # lives in the process dictionary: it cannot leak into another test, and it
  # can distinguish the read a list already made from the read a caller makes
  # afterwards on the same key.
  defmodule FaultingGetS3 do
    @behaviour SalixStore.S3

    alias SalixStore.S3.Fake

    def fault_get(key, after_reads \\ 0), do: Process.put({__MODULE__, key}, after_reads)

    @impl true
    def get(key, opts) do
      case Process.get({__MODULE__, key}) do
        nil -> Fake.get(key, opts)
        0 -> {:error, :fault_injected}
        remaining -> put_remaining(key, remaining, opts)
      end
    end

    defp put_remaining(key, remaining, opts) do
      Process.put({__MODULE__, key}, remaining - 1)
      Fake.get(key, opts)
    end

    @impl true
    defdelegate list(prefix, opts), to: Fake

    @impl true
    defdelegate put(key, body, opts), to: Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: Fake

    @impl true
    defdelegate stream(key, opts), to: Fake

    @impl true
    defdelegate head(key), to: Fake

    @impl true
    defdelegate delete(key, opts), to: Fake

    @impl true
    defdelegate multipart_create(key, opts), to: Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body), to: Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: Fake

    @impl true
    defdelegate multipart_uploads(prefix, opts), to: Fake
  end

  # Serves the first page and then fails: a fault that arrives partway through
  # a multi-page walk, which is the only way to observe that the walk refuses
  # to hand back the pages it did manage to read.
  defmodule ContinuationFaultS3 do
    @behaviour SalixStore.S3

    alias SalixStore.S3.Fake

    @impl true
    def list(prefix, opts) do
      if Keyword.has_key?(opts, :start_after) do
        {:error, :fault_injected}
      else
        Fake.list(prefix, opts)
      end
    end

    @impl true
    defdelegate put(key, body, opts), to: Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: Fake

    @impl true
    defdelegate get(key, opts), to: Fake

    @impl true
    defdelegate stream(key, opts), to: Fake

    @impl true
    defdelegate head(key), to: Fake

    @impl true
    defdelegate delete(key, opts), to: Fake

    @impl true
    defdelegate multipart_create(key, opts), to: Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body), to: Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: Fake

    @impl true
    defdelegate multipart_uploads(prefix, opts), to: Fake
  end

  defmodule StubRing do
    use GenServer

    def start_link(replies), do: GenServer.start_link(__MODULE__, replies)

    @impl true
    def init(replies), do: {:ok, replies}

    @impl true
    def handle_call(request, _from, replies),
      do: {:reply, Map.fetch!(replies, request), replies}
  end

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_triage_backend = SystemsRuntime.get_env(:salix_store, :triage_record_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    SystemsRuntime.put_env(:salix_store, :triage_record_backend, SalixStore.S3)

    if SystemsRuntime.Proc.whereis(S3.Fake) do
      S3.Fake.reset()
    else
      start_supervised!(S3.Fake)
    end

    unless SystemsRuntime.Proc.whereis(Ids), do: start_supervised!(Ids)

    on_exit(fn ->
      if is_nil(previous_backend) do
        SystemsRuntime.delete_env(:salix_store, :s3_backend)
      else
        SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend)
      end

      if is_nil(previous_triage_backend) do
        SystemsRuntime.delete_env(:salix_store, :triage_record_backend)
      else
        SystemsRuntime.put_env(:salix_store, :triage_record_backend, previous_triage_backend)
      end
    end)

    {:ok, namespace: "triage-read-model-#{SystemsRuntime.Proc.unique_integer([:positive])}"}
  end

  test "product activity exposes bounded product outcomes without the retired patrol field" do
    Repo.query!("""
    TRUNCATE
      triage_product_effect_attempts,
      triage_companion_reaction_obligations,
      triage_product_obligations,
      triage_context_entries,
      slack_triage_channels
    CASCADE
    """)

    project_id = "project-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    group_id = "group-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    agent_id = "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    run_id = "run-product-activity-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    namespace_key = Crypto.hex("product-activity-read-model")

    Repo.query!(
      """
      INSERT INTO triage_runs (record_key, namespace_key, run_id, body)
      VALUES ($1, $2, $3, $4)
      """,
      [
        "triage-test-run://#{run_id}",
        namespace_key,
        run_id,
        %{
          "schema" => "comma.triage-run.v1",
          "run_id" => run_id,
          "authoritative" => true,
          "created_at" => 1,
          "status" => "evaluated"
        }
      ]
    )

    obligation_id = "triage-product-" <> Crypto.hex(run_id)

    payload = %{
      "schema" => "comma.triage-product-obligation.v1",
      "obligation_id" => obligation_id,
      "namespace" => "product-activity-read-model",
      "fence_key" => "triage/fence/#{run_id}",
      "run_id" => run_id,
      "target" => %{
        "connect_id" => "connect-1",
        "connect_generation" => "generation-1",
        "workspace_id" => "T1",
        "channel_id" => "C1",
        "thread_ts" => "1787900000.000001"
      },
      "product_identity" => %{
        "project_id" => project_id,
        "project_salix_group_id" => group_id,
        "agent_id" => agent_id,
        "salix_agent_id" => "agt-shadow"
      },
      "communication" => %{
        "kind" => "reply",
        "text" => "A product-safe rehearsal reply",
        "source_refs" => ["slack://T1/C1/1787900000.000001"]
      },
      "context_candidates" => [
        %{
          "kind" => "follow_up",
          "subject" => "unanswered rollout",
          "value" => "Check the rollout after the observer completes",
          "confidence" => "explicit",
          "source_refs" => ["slack://T1/C1/1787900000.000001"],
          "recheck_after_hours" => 2,
          "follow_up_basis" => "agent_owned"
        }
      ],
      "delegations" => [
        %{
          "task" => "Verify the release observer",
          "source_refs" => ["slack://T1/C1/1787900000.000001"]
        }
      ],
      "source_messages" => [
        %{
          "actor_id" => "U12345678",
          "actor_kind" => "human",
          "excerpt" => "Can you verify the release observer?",
          "message_ts" => "1787900000.000001"
        }
      ],
      "target_cutoff" => %{"event_message_timestamps" => ["1787900000.000001"]},
      "settled_at" => 1_787_900_000_001
    }

    Repo.query!(
      """
      INSERT INTO triage_product_obligations
        (namespace_key, run_id, obligation_id, payload)
      VALUES ($1, $2, $3, $4)
      """,
      [namespace_key, run_id, obligation_id, payload]
    )

    assert {:ok, [claim]} = TriageProductRuntime.claim_obligations("shadow-read-model")

    assert {:ok, %{state: :applied}} =
             TriageProductRuntime.settle_claim(claim, %{
               adapter: :audit_sink,
               outcome: :applied,
               external_writes: 0,
               communication: %{
                 "kind" => "reply",
                 "status" => "delivered",
                 "text" => "A product-safe rehearsal reply"
               },
               metadata: %{
                 "provider_payload" => "must never render",
                 "claim_token" => claim.claim_token,
                 "source_speaker_labels" => ["Peng Xiao"],
                 "delegations" => [
                   %{
                     "index" => 0,
                     "status" => "proposed",
                     "reason" => "delegation_worker_ambiguous",
                     "source_count" => 1
                   }
                 ]
               },
               error: "private adapter detail"
             })

    companion_id = "triage-product-" <> Crypto.hex("#{run_id}:reaction")

    companion_payload =
      payload
      |> Map.put("obligation_id", companion_id)
      |> Map.put("communication", %{
        "kind" => "reaction",
        "emoji" => "eyes",
        "source_refs" => ["slack://T1/C1/1787900000.000001"]
      })
      |> Map.put("context_candidates", [])
      |> Map.put("delegations", [])

    Repo.query!(
      """
      INSERT INTO triage_companion_reaction_obligations
        (namespace_key, run_id, obligation_id, payload)
      VALUES ($1, $2, $3, $4)
      """,
      [namespace_key, run_id, companion_id, companion_payload]
    )

    assert {:ok, [companion_claim]} =
             TriageProductRuntime.claim_companion_reactions("shadow-reaction-read-model")

    assert {:ok, %{state: :applied}} =
             TriageProductRuntime.settle_companion_reaction(companion_claim, %{
               adapter: :audit_sink,
               outcome: :applied,
               external_writes: 0,
               communication: %{
                 "kind" => "reaction",
                 "status" => "captured",
                 "emoji" => "eyes"
               }
             })

    Repo.query!(
      """
      INSERT INTO slack_triage_channels (
        tenant_id, group_id, connect_id, channel_id, installation_generation,
        workspace_id, channel_name, channel_generation, enabled,
        provisioned_at, updated_at
      )
      VALUES ('tenant-1', $1, 'connect-1', 'C1', $2, 'T1', 'general', $3, TRUE, now(), now())
      """,
      [group_id, ULID.generate(), ULID.generate()]
    )

    assert {:ok, ^run_id} =
             TriageProductRuntime.debug_run_id(project_id, group_id, agent_id, obligation_id)

    assert {:error, :not_found} =
             TriageProductRuntime.debug_run_id(
               "foreign-project",
               group_id,
               agent_id,
               obligation_id
             )

    assert {:error, :not_found} =
             TriageProductRuntime.debug_run_id(
               project_id,
               "foreign-group",
               agent_id,
               obligation_id
             )

    assert {:error, :not_found} =
             TriageProductRuntime.debug_run_id(
               project_id,
               group_id,
               "foreign-agent",
               obligation_id
             )

    assert {:ok, activity} =
             ReadModel.product_activity(project_id, group_id, agent_id,
               limit: 2,
               context_limit: 2
             )

    assert [outcome] = activity.outcomes
    assert outcome.state == :applied
    assert outcome.communication.kind == :reply
    assert outcome.communication.text == "A product-safe rehearsal reply"
    assert outcome.communication.status == "delivered"

    assert outcome.companion_reaction == %{
             kind: :reaction,
             emoji: "eyes",
             status: "captured",
             text: nil,
             reason: nil
           }

    assert Enum.map(outcome.communications, & &1.kind) == [:reply, :reaction]

    assert outcome.effect == %{
             adapter: "audit_sink",
             outcome: "applied",
             external_writes: 0,
             status: "delivered"
           }

    assert outcome.companion_effect == %{
             state: :applied,
             attempts: 1,
             adapter: "audit_sink",
             outcome: "applied",
             external_writes: 0,
             status: "captured"
           }

    assert outcome.context == %{candidates: 1, active: 1, proposed: 0}

    assert outcome.delegations == [
             %{index: 0, task: "Verify the release observer", source_count: 1, status: "proposed"}
           ]

    assert outcome.obligation_id == obligation_id

    assert outcome.source.channel_id == "C1"
    assert outcome.source.thread_ts == "1787900000.000001"
    assert outcome.source.message_count == 1
    assert outcome.source.first_activity_at_ms == 1_787_900_000_000
    assert outcome.source.latest_activity_at_ms == 1_787_900_000_000

    assert outcome.source.messages == [
             %{
               actor_kind: :human,
               excerpt: "Can you verify the release observer?",
               message_ts: "1787900000.000001",
               occurred_at_ms: 1_787_900_000_000,
               speaker_label: "Peng Xiao",
               url: "https://app.slack.com/client/T1/C1/thread/C1-1787900000.000001"
             }
           ]

    assert outcome.evidence == %{
             communication_sources: 1,
             companion_reaction_sources: 1,
             context_sources: 1,
             delegation_sources: 1,
             total_sources: 1
           }

    assert outcome.related_context == [
             %{
               kind: "follow_up",
               state: :active,
               disposition: "created",
               subject: "unanswered rollout",
               value: "Check the rollout after the observer completes",
               confidence: "explicit",
               source_count: 1
             }
           ]

    reaction_run_id = run_id <> "-reaction"
    reaction_id = "triage-product-" <> Crypto.hex(reaction_run_id)

    Repo.query!(
      """
      INSERT INTO triage_runs (record_key, namespace_key, run_id, body)
      VALUES ($1, $2, $3, $4)
      """,
      [
        "triage-test-run://#{reaction_run_id}",
        namespace_key,
        reaction_run_id,
        %{
          "schema" => "comma.triage-run.v1",
          "run_id" => reaction_run_id,
          "authoritative" => true,
          "created_at" => 2,
          "status" => "evaluated"
        }
      ]
    )

    reaction_payload =
      payload
      |> Map.put("obligation_id", reaction_id)
      |> Map.put("run_id", reaction_run_id)
      |> Map.put("fence_key", "triage/fence/#{reaction_run_id}")
      |> Map.put("communication", %{
        "kind" => "reaction",
        "emoji" => "tada",
        "source_refs" => ["slack://T1/C1/1787900000.000001"]
      })
      |> Map.put("context_candidates", [])
      |> Map.put("delegations", [])

    Repo.query!(
      """
      INSERT INTO triage_product_obligations
        (namespace_key, run_id, obligation_id, payload)
      VALUES ($1, $2, $3, $4)
      """,
      [namespace_key, reaction_run_id, reaction_id, reaction_payload]
    )

    assert {:ok, [reaction_claim]} = TriageProductRuntime.claim_obligations("shadow-read-model")

    assert {:ok, %{state: :applied}} =
             TriageProductRuntime.settle_claim(reaction_claim, %{
               adapter: :slack,
               outcome: :applied,
               external_writes: 1,
               communication: %{
                 "kind" => "reaction",
                 "status" => "added",
                 "emoji" => "tada"
               }
             })

    assert {:ok, reaction_activity} =
             ReadModel.product_activity(project_id, group_id, agent_id,
               limit: 2,
               context_limit: 2
             )

    assert %{communication: %{kind: :reaction, emoji: "tada", status: "added"}} =
             Enum.find(reaction_activity.outcomes, &(&1.event_ref != outcome.event_ref))

    assert outcome.event_ref =~ ~r/^triage-[0-9a-f]{12}$/

    assert [context] = activity.context
    assert context.kind == "follow_up"
    assert context.state == :active
    assert context.subject == "unanswered rollout"
    assert context.value == "Check the rollout after the observer completes"
    assert context.source_count == 1
    assert is_integer(context.next_check_at_ms)

    assert {:ok, %{context: [], follow_ups: {:ok, [follow_up]}}} =
             ReadModel.product_activity(project_id, group_id, agent_id,
               page: true,
               context_limit: 0,
               include_follow_ups: true
             )

    assert follow_up.entry_id == context.entry_id

    assert {:ok, %{context: [exact]}} =
             ReadModel.product_activity(project_id, group_id, agent_id,
               page: true,
               context_limit: 1,
               context_entry_id: context.entry_id
             )

    assert exact.entry_id == context.entry_id

    Repo.query!(
      """
      INSERT INTO triage_context_entries
        (entry_id, project_id, agent_id, kind, subject_key, value_key, evidence_key,
         state, payload, inserted_at, updated_at)
      VALUES
        ($1, $2, $3, 'project_fact', $4, $5, $6, 'active', $7, now(), now()),
        ($8, $2, $3, 'project_fact', $9, $10, $11, 'proposed', $12, now(), now())
      """,
      [
        "triage-context-cross-agent",
        project_id,
        "another-agent",
        Crypto.hex("cross-agent-subject"),
        Crypto.hex("cross-agent-value"),
        Crypto.hex("cross-agent-evidence"),
        %{
          "subject" => "shared release boundary",
          "value" => "All project Agents share this retained context",
          "confidence" => "explicit",
          "source_refs" => ["slack://T1/C1/1787900000.000002"]
        },
        "triage-context-proposed",
        Crypto.hex("proposed-subject"),
        Crypto.hex("proposed-value"),
        Crypto.hex("proposed-evidence"),
        %{
          "subject" => "unreviewed rollout claim",
          "value" => "This must not enter Knowledge",
          "confidence" => "inferred",
          "source_refs" => ["slack://T1/C1/1787900000.000003"]
        }
      ]
    )

    assert {:ok, %{items: knowledge_items, complete: true}} =
             ReadModel.knowledge_context(project_id, group_id, agent_id, limit: 3)

    assert length(knowledge_items) == 2

    assert {:ok, %{items: [_one_item], complete: false}} =
             ReadModel.knowledge_context(project_id, group_id, agent_id, limit: 1)

    knowledge_context =
      Enum.find(knowledge_items, &(&1.context_ref == context.context_ref))

    assert knowledge_context.context_ref == context.context_ref
    assert knowledge_context.kind == "follow_up"
    assert knowledge_context.state == :active
    assert knowledge_context.subject == "unanswered rollout"
    assert knowledge_context.value == "Check the rollout after the observer completes"

    assert {:ok, %{items: [matched], complete: true}} =
             ReadModel.knowledge_context(project_id, group_id, agent_id,
               query: "shared release boundary",
               limit: 20
             )

    assert matched.subject == "shared release boundary"

    assert Enum.any?(
             knowledge_items,
             &(&1.subject == "shared release boundary" and &1.state == :active)
           )

    refute Enum.any?(knowledge_items, &(&1.subject == "unreviewed rollout claim"))
    refute inspect(knowledge_items, limit: :infinity) =~ "slack://"

    refute Map.has_key?(activity, :patrol)

    rendered = inspect(activity, limit: :infinity)
    refute rendered =~ run_id
    refute rendered =~ claim.claim_token
    refute rendered =~ "provider_payload"
    refute rendered =~ "must never render"
    refute rendered =~ "private adapter detail"
    refute rendered =~ "slack://T1/C1"
    refute rendered =~ "U12345678"

    assert ReadModel.product_activity(project_id, group_id, agent_id, limit: 21) ==
             {:error, :invalid_triage_product_activity}

    explanation = "The thread already confirms that the requested rollout completed."

    Repo.query!(
      "UPDATE triage_product_obligations SET payload = jsonb_set(payload, '{communication}', $2), result = jsonb_set(result, '{communication}', $3) WHERE obligation_id = $1",
      [
        obligation_id,
        %{
          "kind" => "silence",
          "reason" => "already_answered",
          "explanation" => explanation,
          "source_refs" => []
        },
        %{"kind" => "silence", "reason" => "already_answered", "status" => "recorded"}
      ]
    )

    assert {:ok, explained_activity} =
             ReadModel.product_activity(project_id, group_id, agent_id, limit: 2)

    explained = Enum.find(explained_activity.outcomes, &(&1.obligation_id == obligation_id))
    assert explained.communication.explanation == explanation
    assert explained.communication.status == "recorded"
  end

  # ---- buckets ----

  test "the bucket page walks the namespace prefix and round-trips its opaque cursor", %{
    namespace: namespace
  } do
    authority = authority()

    receipts =
      for {event_id, message_ts} <- [
            {"Ev-bucket-one", "1787019000.000001"},
            {"Ev-bucket-two", "1787019000.000002"},
            {"Ev-bucket-three", "1787019000.000003"}
          ] do
        receipt = seed_receipt(authority, event_id, 1_000, message_ts)
        assert Bucketing.append(namespace, receipt) == {:ok, :appended}
        receipt
      end

    assert {:ok, first} = ReadModel.list_buckets(namespace, nil, 2)
    assert length(first.buckets) == 2
    assert first.invalid_count == 0
    refute first.scan_complete
    assert is_binary(first.next_cursor)

    assert {:ok, second} = ReadModel.list_buckets(namespace, first.next_cursor, 2)
    assert length(second.buckets) == 1
    assert second.invalid_count == 0
    assert second.scan_complete
    assert second.next_cursor == nil

    scopes = Enum.map(first.buckets ++ second.buckets, & &1.bucket_scope)
    assert Enum.sort(scopes) == receipts |> Enum.map(&Bucketing.scope_key/1) |> Enum.sort()

    [receipt | _rest] = receipts
    scope = Bucketing.scope_key(receipt)
    item = Enum.find(first.buckets ++ second.buckets, &(&1.bucket_scope == scope))

    assert %{
             bucket_key: SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope),
             bucket_scope: scope,
             open_first_at: 1_000,
             open_last_at: 1_000,
             open_receipt_count: 1,
             sealed_generation_count: 0,
             sealed_receipt_count: 0,
             receipt_count: 1,
             fast_path: false,
             connect_id: authority["connect_id"]
           } == Map.delete(item, :open_generation)

    assert ULID.valid?(item.open_generation)
  end

  # ---- receipts ----

  test "the recent window filters by since, sorts newest first, and reports the scan", %{
    namespace: namespace
  } do
    authority = authority()

    seeded =
      for {event_id, created_at, message_ts} <- [
            {"Ev-window-1", 1_000, "1787019000.000001"},
            {"Ev-window-2", 2_000, "1787019000.000002"},
            {"Ev-window-3", 3_000, "1787019000.000003"},
            {"Ev-window-4", 4_000, "1787019000.000004"}
          ] do
        seed_receipt(authority, event_id, created_at, message_ts)
      end

    assert {:ok, window} = ReadModel.recent_window(namespace, 2_500)
    assert Enum.map(window.receipts, & &1["event_id"]) == ["Ev-window-4", "Ev-window-3"]
    refute window.truncated
    assert window.scanned_pages == 1
    assert window.legacy_count == 0
    assert window.invalid_count == 0

    assert {:ok, everything} = ReadModel.recent_window(namespace, 0)

    assert Enum.map(everything.receipts, & &1["created_at"]) ==
             seeded |> Enum.map(& &1["created_at"]) |> Enum.sort(:desc)

    assert ReadModel.recent_window(namespace, 5_000) ==
             {:ok,
              %{
                receipts: [],
                truncated: false,
                scanned_pages: 1,
                legacy_count: 0,
                invalid_count: 0,
                unavailable_count: 0
              }}

    assert ReadModel.recent_window(namespace, -1) == {:error, :invalid_triage_recent_window}
    assert ReadModel.recent_window("", 0) == {:error, :invalid_triage_recent_window}

    assert ReadModel.recent_window(namespace, 0, page_budget: 0) ==
             {:error, :invalid_triage_recent_window}

    assert ReadModel.recent_window(namespace, 0, page_budget: 41) ==
             {:error, :invalid_triage_recent_window}

    assert ReadModel.recent_window(namespace, 0, unknown: 1) ==
             {:error, :invalid_triage_recent_window}
  end

  test "indexed intake isolates projects, bounds source text and preserves received without inventing silence" do
    authority = authority()
    group = "intake-group-#{ULID.generate()}"
    receipt = seed_receipt(authority, group, 1000, "1787019000.000991")
    receipt = put_in(receipt, ["triage_event", "text"], String.duplicate("中", 1100))
    assert :ok = SalixStore.TriageIntake.observe(group, receipt)
    assert :ok = SalixStore.TriageIntake.observe(group, receipt)
    assert {:ok, %{receipts: [_], truncated: false}} = SalixStore.TriageIntake.recent(group, 20)
    assert {:ok, [^receipt]} = SalixStore.TriageIntake.by_refs(group, [receipt["receipt_ref"]])
    assert {:ok, []} = SalixStore.TriageIntake.by_refs("another-group", [receipt["receipt_ref"]])

    assert {:error, :invalid} =
             SalixStore.TriageIntake.by_refs(group, List.duplicate(receipt["receipt_ref"], 21))

    assert {:ok, page} =
             ReadModel.product_activity("intake-project", group, "intake-agent",
               page: true,
               include_intake: true
             )

    assert {:ok, %{items: [item], truncated: false}} = page.intake
    assert item.state == :received
    assert String.length(item.source_text) == 1024
    assert item.source_url =~ "app.slack.com"
    assert is_binary(item.source_thread_ts)
    assert item.source_url =~ item.source_thread_ts
    assert item.terminal_status == nil

    assert {:ok, foreign} =
             ReadModel.product_activity("intake-project", "another-group", "intake-agent",
               page: true,
               include_intake: true
             )

    assert {:ok, %{items: []}} = foreign.intake

    # A channel filter narrows intake in the query, not after the newest 20.
    channel = receipt["triage_event"]["bucket"]["channel_id"]

    assert {:ok, %{intake: {:ok, %{items: [_same]}}}} =
             ReadModel.product_activity("intake-project", group, "intake-agent",
               page: true,
               include_intake: true,
               channel_id: channel
             )

    assert {:ok, %{intake: {:ok, %{items: []}}}} =
             ReadModel.product_activity("intake-project", group, "intake-agent",
               page: true,
               include_intake: true,
               channel_id: "C-OTHER"
             )

    assert {:error, :invalid_triage_product_activity} =
             ReadModel.product_activity("intake-project", group, "intake-agent",
               channel_id: channel
             )
  end

  test "timeline reports recorded status and verifies only the selected receipt" do
    SystemsRuntime.put_env(:salix_store, :triage_record_backend, SalixStore.TriageRecords)
    namespace = SalixStore.TriageKeys.default_namespace()
    group = "lazy-processing-#{ULID.generate()}"
    authority = authority()

    receipts =
      for ordinal <- 1..2 do
        receipt =
          seed_receipt(
            authority,
            "lazy-#{group}-#{ordinal}",
            20_000 + ordinal,
            "1787019000.#{String.pad_leading(to_string(ordinal), 6, "0")}"
          )

        fence = terminal_v2_fence!(namespace, receipt, 21_000 + ordinal)
        assert {:ok, authorized} = RunFence.authorize_projection_from_storage(namespace, fence)
        assert :ok = Ledger.persist(namespace, authorized)
        assert :ok = SalixStore.TriageIntake.observe(group, receipt)
        receipt
      end

    assert {:ok, page} =
             ReadModel.product_activity("lazy-project", group, "lazy-agent",
               context_limit: 0,
               include_intake: true
             )

    assert {:ok, %{items: items, truncated: false}} = page.intake
    assert length(items) == 2
    refute Enum.any?(items, &(&1.state == :unavailable))
    assert Enum.all?(items, &(&1.state == :settled and &1.terminal_status == "failed"))

    selected = hd(receipts)["receipt_ref"]

    assert {:ok, %{state: :terminal, terminal_status: "failed"}} =
             ReadModel.processing_detail(group, selected)

    assert {:error, :not_found} = ReadModel.processing_detail("another-group", selected)
  end

  test "explicit receipt debug reads one existing run and refuses a foreign group", %{
    namespace: namespace
  } do
    receipt =
      seed_receipt(
        authority(),
        "Ev-model-debug-#{SystemsRuntime.Proc.uuid()}",
        9_000,
        "1787019000.000099"
      )

    fence = terminal_v2_fence!(namespace, receipt, 9_100)
    assert {:ok, projection} = RunFence.authorize_projection_from_storage(namespace, fence)
    assert :ok = Ledger.persist(namespace, projection)
    group = "debug-group-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    assert :ok = SalixStore.TriageIntake.observe(group, receipt)

    assert {:ok, debug} =
             ReadModel.model_debug(
               namespace,
               "project",
               group,
               "agent",
               "receipt",
               receipt["receipt_ref"]
             )

    assert debug.run_id == fence["run_id"]
    assert debug.requests == []
    assert debug.raw_response == nil
    assert debug.decision == fence["terminal"]["decision"]

    assert {:error, :not_found} =
             ReadModel.model_debug(
               namespace,
               "project",
               "foreign-group",
               "agent",
               "receipt",
               receipt["receipt_ref"]
             )
  end

  # ---- ring ----

  # ---- connects ----

  test "connect posture reports provisioned, unprovisioned, and disabled connects, never secrets" do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    other_tenant_id = Ids.new_tenant_id()
    router_agent_id = Ids.new_agent_id(group_id)

    group = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "router_agent_id" => router_agent_id,
      "router_conversation_id" => Ids.new_conversation_id()
    }

    assert {:ok, _group} = CasRecord.create(Keys.ctl_group(group_id), group)

    provisioned =
      tenant_id
      |> slack_connect(group_id, "Provisioned", 3)
      |> Map.put("inbound_agent_id", router_agent_id)

    unprovisioned =
      tenant_id
      |> slack_connect(group_id, "Unprovisioned", 2)
      |> Map.put("inbound_agent_id", router_agent_id)

    disabled =
      tenant_id
      |> slack_connect(group_id, "Disabled", 1)
      |> Map.put("inbound_agent_id", router_agent_id)

    provisioned =
      provisioned
      |> Map.merge(%{
        "app_name" => "Bridge For Teams (Staging)",
        "approved_channel_id" => "C_PROVISIONED",
        "approved_channel_name" => "provisioned-room",
        "triage_provisioned_at" => 1,
        "triage_enabled" => true
      })

    unprovisioned = Map.merge(unprovisioned, %{"triage_enabled" => false})

    disabled =
      disabled
      |> Map.merge(%{
        "approved_channel_id" => "C_DISABLED",
        "triage_enabled" => false
      })

    for connect <- [provisioned, unprovisioned, disabled] do
      assert {:ok, _connect} =
               CasRecord.create(Keys.ctl_im_connect(group_id, connect["connect_id"]), connect)
    end

    assert {:ok, postures} = ReadModel.connect_posture(tenant_id, group_id)
    assert length(postures) == 3

    by_id = Map.new(postures, &{&1.connect_id, &1})

    assert by_id[provisioned["connect_id"]] == %{
             connect_id: provisioned["connect_id"],
             posture_complete?: true,
             provisioned?: true,
             triage_enabled: true,
             approved_channel_id: "C_PROVISIONED",
             approved_channel_name: "provisioned-room",
             configured_channels: [],
             channel_scope_complete?: true,
             channel_controls_available?: true,
             authority_valid?: false,
             connect_generation: provisioned["connect_generation"],
             app_name: "Bridge For Teams (Staging)",
             bot_username: "atlas-bot",
             source_ready?: true,
             workspace_id: provisioned["workspace_id"],
             workspace_name: "Provisioned",
             inbound_agent_id: provisioned["inbound_agent_id"],
             app_id: provisioned["app_id"]
           }

    assert by_id[unprovisioned["connect_id"]].provisioned? == false
    assert by_id[unprovisioned["connect_id"]].triage_enabled == false
    assert by_id[unprovisioned["connect_id"]].approved_channel_id == nil

    assert by_id[disabled["connect_id"]].provisioned? == true
    assert by_id[disabled["connect_id"]].triage_enabled == false
    assert by_id[disabled["connect_id"]].approved_channel_id == "C_DISABLED"
    # A legacy authority predating both presentation names and the newer setup
    # marker is still provisioned; the approved channel was the old authority.
    assert by_id[disabled["connect_id"]].approved_channel_name == nil

    expected_keys =
      Enum.sort([
        :app_id,
        :app_name,
        :approved_channel_id,
        :approved_channel_name,
        :bot_username,
        :authority_valid?,
        :channel_controls_available?,
        :channel_scope_complete?,
        :connect_generation,
        :connect_id,
        :configured_channels,
        :inbound_agent_id,
        :posture_complete?,
        :provisioned?,
        :source_ready?,
        :triage_enabled,
        :workspace_id,
        :workspace_name
      ])

    for posture <- postures do
      assert Enum.sort(Map.keys(posture)) == expected_keys
    end

    rendered = inspect(postures)
    refute rendered =~ "xoxb"
    refute rendered =~ "signing-secret"
    refute rendered =~ "client-secret"

    assert ReadModel.connect_posture(other_tenant_id, group_id) == {:error, :unavailable}

    assert ReadModel.connect_posture(tenant_id, Ids.new_group_id(other_tenant_id)) ==
             {:error, :unavailable}

    assert ReadModel.connect_posture(tenant_id, "") == {:error, :unavailable}
  end

  # ---- fixtures ----

  defp authority do
    %{
      "provider" => "slack",
      "tenant_id" => "tenant-atlas",
      "group_id" => "project-atlas",
      "connect_id" => "connect-atlas",
      "connect_generation" => ULID.generate(),
      "workspace_id" => "T_ATLAS",
      "approved_channel_id" => "C_ATLAS",
      "inbound_agent_id" => "agt1_atlas_router",
      "app_id" => "A_BFT",
      "bot_user_id" => "U_BFT",
      "bot_id" => "B_BFT",
      "oauth_completed_at" => 1,
      "triage_enabled" => true
    }
  end

  # Builds the exact shape `ProviderReceipts.record_slack_triage_root/2`
  # writes, with a caller-chosen `created_at` so window ordering is
  # deterministic instead of wall-clock.
  defp seed_receipt(authority, event_id, created_at, message_ts, opts \\ []) do
    {:ok, revision} = EndpointRevision.sha256(authority)
    key = Keys.ctl_im_slack_event_receipt(authority["connect_id"], event_id)
    thread_ts = Keyword.get(opts, :thread_ts, message_ts)

    receipt = %{
      "schema" => "comma.slack-triage-event-receipt.v2",
      "connect_id" => authority["connect_id"],
      "event_id" => event_id,
      "connect_generation" => authority["connect_generation"],
      "created_at" => created_at,
      "receipt_ref" => "s3://" <> key,
      "source_message_ref" =>
        Enum.join(
          [
            authority["connect_generation"],
            authority["workspace_id"],
            authority["approved_channel_id"],
            thread_ts,
            message_ts
          ],
          ":"
        ),
      "triage_event" => %{
        "event_id" => event_id,
        "connect_generation" => authority["connect_generation"],
        "message_ts" => message_ts,
        "actor_id" => "U_HUMAN",
        "actor_kind" => "human",
        "text" => "please review this update",
        "event_type" => "message",
        "addressing_kind" => "ambient",
        "trigger_kind" => "none",
        "fast_path" => false,
        "bucket" => %{
          "workspace_id" => authority["workspace_id"],
          "channel_id" => authority["approved_channel_id"],
          "thread_ts" => thread_ts
        },
        "endpoint_provenance" => %{
          "schema" => "comma.slack-endpoint-provenance.v1",
          "captured_at_ms" => created_at,
          "callback_api_app_id" => authority["app_id"],
          "fast_path_bot_user_id" => authority["bot_user_id"],
          "endpoint_revision_sha256" => revision
        },
        "source_mode" => "callback"
      }
    }

    assert {:ok, ^receipt} = CasRecord.create(key, receipt)
    receipt
  end

  defp seal_receipts!(namespace, receipts, sealed_at) do
    Enum.each(receipts, fn receipt ->
      assert Bucketing.append(namespace, receipt) == {:ok, :appended}
    end)

    scope = receipts |> hd() |> Bucketing.scope_key()
    assert {:ok, bucket} = Bucketing.load(namespace, scope)

    assert {:ok, sealed} =
             Bucketing.seal(
               namespace,
               scope,
               bucket["open_generation"],
               %{debounce_ms: 0, max_wait_ms: 1},
               sealed_at
             )

    assert is_map(sealed)
    {sealed, scope}
  end

  defp create_v2_fence!(namespace, scope, sealed, created_at, deadline_at) do
    assert {:ok, input} = Pipeline.build_input(sealed)

    assert {:ok, {:won, creation}} =
             RunFence.create(
               namespace,
               scope,
               ULID.generate(),
               input,
               created_at,
               deadline_at
             )

    {creation, input}
  end

  defp terminal_v2_fence!(namespace, receipt, sealed_at) do
    {sealed, scope} = seal_receipts!(namespace, [receipt], sealed_at)
    {creation, _input} = create_v2_fence!(namespace, scope, sealed, sealed_at + 1, sealed_at + 2)
    assert {:ok, terminal_fence} = RunFence.recover_open(namespace, creation.record, :deadline)
    terminal_fence
  end

  defp slack_connect(tenant_id, group_id, workspace_name, created_at) do
    connect_id = Ids.new_connect_id()

    %{
      "provider" => "slack",
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => connect_id,
      "connect_generation" => ULID.generate(),
      "workspace_id" => "T_" <> workspace_name,
      "workspace_name" => workspace_name,
      "app_id" => "A_" <> workspace_name,
      "client_id" => "client-" <> workspace_name,
      "client_secret" => "client-secret",
      "signing_secret" => "signing-secret",
      "bot_token" => "xoxb-private-test-token",
      "bot_user_id" => "U_BOT",
      "bot_id" => "B_BOT",
      "bot_username" => "atlas-bot",
      "inbound_agent_id" => "agt1_atlas_router",
      "oauth_completed_at" => 1,
      "created_at" => created_at,
      "updated_at" => created_at
    }
  end
end
