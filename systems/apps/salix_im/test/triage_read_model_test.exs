defmodule SalixIM.TriageReadModelTest do
  use ExUnit.Case, async: false

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
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_triage_backend = Application.get_env(:salix_store, :triage_record_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    Application.put_env(:salix_store, :triage_record_backend, SalixStore.S3)

    if Process.whereis(S3.Fake) do
      S3.Fake.reset()
    else
      start_supervised!(S3.Fake)
    end

    unless Process.whereis(Ids), do: start_supervised!(Ids)

    on_exit(fn ->
      if is_nil(previous_backend) do
        Application.delete_env(:salix_store, :s3_backend)
      else
        Application.put_env(:salix_store, :s3_backend, previous_backend)
      end

      if is_nil(previous_triage_backend) do
        Application.delete_env(:salix_store, :triage_record_backend)
      else
        Application.put_env(:salix_store, :triage_record_backend, previous_triage_backend)
      end
    end)

    {:ok, namespace: "triage-read-model-#{System.unique_integer([:positive])}"}
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

    project_id = "project-#{System.unique_integer([:positive])}"
    group_id = "group-#{System.unique_integer([:positive])}"
    agent_id = "agent-#{System.unique_integer([:positive])}"
    run_id = "run-product-activity-#{System.unique_integer([:positive])}"
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

  test "a folder marker, a poison key, and a misplaced bucket are counted without pinning", %{
    namespace: namespace
  } do
    authority = authority()
    prefix = SalixStore.TriageKeys.ctl_im_triage_buckets_prefix(namespace)

    assert {:ok, _marker} = S3.put(prefix, "", if_none_match: "*")

    assert {:ok, _poison} =
             S3.put(prefix <> "!poison ", Jason.encode!(%{"raw" => "poison"}), if_none_match: "*")

    receipt = seed_receipt(authority, "Ev-bucket-healthy", 1_000, "1787019000.000001")
    assert Bucketing.append(namespace, receipt) == {:ok, :appended}

    scope = Bucketing.scope_key(receipt)

    assert {:ok, record} =
             CasRecord.get(SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope))

    # A valid bucket body parked under a key that is not sha256 of its own
    # scope does not belong to the scan: the key/body binding is the only
    # thing that makes an opaque key addressable.
    assert {:ok, _misplaced} =
             CasRecord.create(
               SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope <> ":drift"),
               record
             )

    assert {:ok, page} = ReadModel.list_buckets(namespace, nil, 25)
    assert Enum.map(page.buckets, & &1.bucket_scope) == [scope]
    assert page.invalid_count == 3
    assert page.scan_complete
    assert page.next_cursor == nil

    assert {:ok, marker_page} = ReadModel.list_buckets(namespace, nil, 1)
    assert marker_page.buckets == []
    assert marker_page.invalid_count == 1
    refute marker_page.scan_complete
    assert is_binary(marker_page.next_cursor)

    assert {:ok, poison_page} = ReadModel.list_buckets(namespace, marker_page.next_cursor, 1)
    assert poison_page.buckets == []
    assert poison_page.invalid_count == 1
    refute poison_page.scan_complete
    assert poison_page.next_cursor != marker_page.next_cursor
  end

  test "an undecodable cursor, a foreign cursor, and a bad limit are refused", %{
    namespace: namespace
  } do
    assert ReadModel.list_buckets(namespace, "garbage") ==
             {:error, :invalid_triage_bucket_cursor}

    assert ReadModel.list_buckets(namespace, "v1.@@@") ==
             {:error, :invalid_triage_bucket_cursor}

    foreign = "v1." <> Base.url_encode64("ctl/im_connects/elsewhere.json", padding: false)
    assert ReadModel.list_buckets(namespace, foreign) == {:error, :invalid_triage_bucket_cursor}

    assert ReadModel.list_buckets(namespace, nil, 0) == {:error, :invalid_triage_bucket_page}
    assert ReadModel.list_buckets(namespace, nil, 26) == {:error, :invalid_triage_bucket_page}
    assert ReadModel.list_buckets("", nil, 25) == {:error, :invalid_triage_bucket_page}
  end

  test "a reordered page that ignores the cursor is unavailable, never silently empty", %{
    namespace: namespace
  } do
    authority = authority()

    for {event_id, message_ts} <- [
          {"Ev-unsorted-one", "1787019000.000001"},
          {"Ev-unsorted-two", "1787019000.000002"}
        ] do
      receipt = seed_receipt(authority, event_id, 1_000, message_ts)
      assert Bucketing.append(namespace, receipt) == {:ok, :appended}
    end

    assert {:ok, healthy} = ReadModel.list_buckets(namespace, nil, 1)
    assert is_binary(healthy.next_cursor)

    Application.put_env(:salix_store, :s3_backend, NonAdvancingS3)

    assert ReadModel.list_buckets(namespace, nil, 25) == {:error, :unavailable}
    assert ReadModel.list_buckets(namespace, healthy.next_cursor, 25) == {:error, :unavailable}
  end

  test "get_bucket reads a raw locator byte-identically, trailing space included", %{
    namespace: namespace
  } do
    authority = authority()
    prefix = SalixStore.TriageKeys.ctl_im_triage_buckets_prefix(namespace)

    receipt = seed_receipt(authority, "Ev-raw-locator", 1_000, "1787019000.000001")
    assert Bucketing.append(namespace, receipt) == {:ok, :appended}

    scope = Bucketing.scope_key(receipt)
    canonical = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)
    assert {:ok, record} = CasRecord.get(canonical)

    spaced = canonical <> " "
    assert {:ok, _spaced} = CasRecord.create(spaced, record)

    assert {:ok, direct} = ReadModel.get_bucket(namespace, canonical)
    assert direct.bucket_key == canonical
    assert direct.receipts == [receipt]
    assert direct.sealed_generations == []
    assert direct.sealed_receipts == []
    assert direct.receipt_count == 1
    assert direct.connect_id == authority["connect_id"]

    # The trailing space addresses a DIFFERENT object; trimming the locator
    # would GET the canonical sibling instead of the record listed.
    assert {:ok, raw} = ReadModel.get_bucket(namespace, spaced)
    assert raw.bucket_key == spaced
    assert raw.receipts == [receipt]

    assert ReadModel.get_bucket(namespace, prefix <> String.duplicate("a", 64) <> ".json") ==
             {:error, :not_found}

    assert ReadModel.get_bucket(namespace, "ctl/im_connects/elsewhere.json") ==
             {:error, :not_found}

    assert ReadModel.get_bucket(namespace, :not_a_key) == {:error, :invalid_triage_bucket}

    malformed = prefix <> "malformed.json"
    assert {:ok, _malformed} = CasRecord.create(malformed, %{"schema" => "comma.not-a-bucket.v1"})
    assert ReadModel.get_bucket(namespace, malformed) == {:error, :invalid_triage_bucket}

    # The same objects the raw GET honors are still poison for the scan.
    assert {:ok, page} = ReadModel.list_buckets(namespace, nil, 25)
    assert Enum.map(page.buckets, & &1.bucket_key) == [canonical]
    assert page.invalid_count == 2
  end

  test "a sealed-only bucket remains valid and attributable to its connect", %{
    namespace: namespace
  } do
    authority = authority()
    receipt = seed_receipt(authority, "Ev-sealed-visible", 1_000, "1787019000.000001")
    assert Bucketing.append(namespace, receipt) == {:ok, :appended}

    scope = Bucketing.scope_key(receipt)
    {:ok, durable} = Bucketing.load(namespace, scope)

    assert {:ok, sealed} =
             Bucketing.seal(
               namespace,
               scope,
               durable["open_generation"],
               %{debounce_ms: 0, max_wait_ms: 1},
               1_000
             )

    assert sealed["receipts"] == [receipt]
    assert {:ok, sealed_bucket} = Bucketing.load(namespace, scope)
    assert Bucketing.validate_durable_bucket(sealed_bucket) == :ok

    assert {:ok, page} = ReadModel.list_buckets(namespace, nil, 25)
    assert page.invalid_count == 0
    assert [bucket] = page.buckets
    assert bucket.connect_id == authority["connect_id"]
    assert bucket.open_receipt_count == 0
    assert bucket.sealed_generation_count == 1
    assert bucket.sealed_receipt_count == 1
    assert bucket.receipt_count == 1

    assert {:ok, detail} = ReadModel.get_bucket(namespace, bucket.bucket_key)
    assert detail.receipts == []
    assert detail.sealed_receipts == [receipt]
  end

  test "the reader rejects a malformed sealed generation through the canonical validator", %{
    namespace: namespace
  } do
    receipt = seed_receipt(authority(), "Ev-sealed-malformed", 1_000, "1787019000.000001")
    assert Bucketing.append(namespace, receipt) == {:ok, :appended}

    scope = Bucketing.scope_key(receipt)
    key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)
    assert {:ok, durable} = Bucketing.load(namespace, scope)

    poisoned =
      durable
      |> Map.put("open_first_at", nil)
      |> Map.put("open_last_at", nil)
      |> Map.put("open_receipts", [])
      |> Map.put("sealed_generations", [
        %{"generation" => "sealed-malformed", "receipts" => [receipt]}
      ])

    assert Bucketing.validate_durable_bucket(poisoned) ==
             {:error, :invalid_triage_bucket}

    assert {:ok, ^poisoned} = CasRecord.update(key, fn _current -> poisoned end)
    assert ReadModel.get_bucket(namespace, key) == {:error, :invalid_triage_bucket}

    assert {:ok, page} = ReadModel.list_buckets(namespace, nil, 25)
    assert page.buckets == []
    assert page.invalid_count == 1
  end

  test "a bucket the scan cannot read is unavailable, never counted as poison", %{
    namespace: namespace
  } do
    authority = authority()

    receipt = seed_receipt(authority, "Ev-bucket-unreadable", 1_000, "1787019000.000001")
    assert Bucketing.append(namespace, receipt) == {:ok, :appended}

    scope = Bucketing.scope_key(receipt)
    key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)

    Application.put_env(:salix_store, :s3_backend, FaultingGetS3)
    FaultingGetS3.fault_get(key)

    assert {:ok, page} = ReadModel.list_buckets(namespace, nil, 25)
    assert page.buckets == []
    # The record is very likely fine; only the read failed. Counting it as
    # invalid would report a storage fault as a malformed object.
    assert page.invalid_count == 0
    assert page.unavailable_count == 1
    assert page.scan_complete

    # The same fault on a direct read is a fault, not "nothing is stored here".
    assert ReadModel.get_bucket(namespace, key) == {:error, :unavailable}
  end

  test "bucket detail refuses a durable record above the interactive body budget", %{
    namespace: namespace
  } do
    authority = authority()
    receipt = seed_receipt(authority, "Ev-bucket-too-large", 1_000, "1787019000.000001")
    assert Bucketing.append(namespace, receipt) == {:ok, :appended}

    scope = Bucketing.scope_key(receipt)
    key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)
    assert {:ok, durable} = CasRecord.get(key)

    oversized =
      update_in(durable, ["open_receipts", Access.at(0), "triage_event", "text"], fn _text ->
        String.duplicate("x", 4 * 1024 * 1024)
      end)

    assert Bucketing.validate_durable_bucket(oversized) == :ok
    assert {:ok, ^oversized} = CasRecord.update(key, fn _current -> oversized end)

    assert ReadModel.get_bucket(namespace, key) == {:error, :unavailable}
  end

  test "bucket listing shares one body budget across the whole page", %{namespace: namespace} do
    authority = authority()

    for {event_id, message_ts} <- [
          {"Ev-budget-one", "1787019000.000001"},
          {"Ev-budget-two", "1787019000.000002"}
        ] do
      receipt = seed_receipt(authority, event_id, 1_000, message_ts)
      assert Bucketing.append(namespace, receipt) == {:ok, :appended}

      scope = Bucketing.scope_key(receipt)
      key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)
      assert {:ok, durable} = CasRecord.get(key)

      large =
        update_in(durable, ["open_receipts", Access.at(0), "triage_event", "text"], fn _text ->
          String.duplicate("x", 2_200_000)
        end)

      assert Bucketing.validate_durable_bucket(large) == :ok
      assert {:ok, ^large} = CasRecord.update(key, fn _current -> large end)
    end

    assert {:ok, page} = ReadModel.list_buckets(namespace, nil, 25)
    assert length(page.buckets) == 1
    assert page.invalid_count == 0
    assert page.unavailable_count == 1
    assert page.truncated
  end

  # ---- receipts ----

  test "the receipt page delegates and passes the honest-scan counts through unchanged" do
    authority = authority()
    prefix = Keys.ctl_im_slack_event_receipts_prefix()

    healthy = seed_receipt(authority, "Ev-delegated-healthy", 1_000, "1787019000.000001")
    assert {:ok, true} = ProviderReceipts.record_slack(authority["connect_id"], "Ev-legacy")

    assert {:ok, _poison} =
             S3.put(prefix <> "!poison", Jason.encode!(%{"raw" => "poison"}), if_none_match: "*")

    assert {:ok, page} = ReadModel.list_receipts_page()
    assert page == elem(ProviderReceipts.list_slack_triage_page(:all, nil, 25), 1)

    assert page.receipts == [healthy]
    assert page.connect_ids == [authority["connect_id"]]
    assert page.legacy_count == 1
    assert page.invalid_count == 1
    assert page.unavailable_count == 0
    assert page.scanned_count == 3
    assert page.scan_complete

    assert ReadModel.list_receipts_page("garbage") ==
             {:error, :invalid_slack_triage_cursor}
  end

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

  test "the recent window flags truncation when the page budget runs out", %{
    namespace: namespace
  } do
    authority = authority()
    prefix = Keys.ctl_im_slack_event_receipts_prefix()

    for index <- 1..26 do
      key = prefix <> "!poison-" <> String.pad_leading("#{index}", 2, "0")
      assert {:ok, _poison} = S3.put(key, Jason.encode!(%{"raw" => "poison"}), if_none_match: "*")
    end

    seed_receipt(authority, "Ev-budget-1", 1_000, "1787019000.000001")
    seed_receipt(authority, "Ev-budget-2", 2_000, "1787019000.000002")

    assert {:ok, clipped} = ReadModel.recent_window(namespace, 0, page_budget: 1)
    assert clipped.receipts == []
    assert clipped.truncated
    assert clipped.scanned_pages == 1
    assert clipped.invalid_count == 25

    assert {:ok, full} = ReadModel.recent_window(namespace, 0, page_budget: 8)
    assert Enum.map(full.receipts, & &1["event_id"]) == ["Ev-budget-2", "Ev-budget-1"]
    refute full.truncated
    assert full.scanned_pages == 2
    assert full.invalid_count == 26
  end

  test "the recent window carries the receipts it could not read as their own count", %{
    namespace: namespace
  } do
    authority = authority()

    seed_receipt(authority, "Ev-window-readable", 2_000, "1787019000.000002")
    seed_receipt(authority, "Ev-window-unreadable", 1_000, "1787019000.000001")

    # Page hydration is concurrent, so the fault must belong to the shared
    # fake store rather than the caller process dictionary.
    assert :ok =
             S3.Fake.set_fault({
               :fail,
               503,
               :get,
               Keys.ctl_im_slack_event_receipt(
                 authority["connect_id"],
                 "Ev-window-unreadable"
               )
             })

    assert {:ok, window} = ReadModel.recent_window(namespace, 0)

    assert Enum.map(window.receipts, & &1["event_id"]) == ["Ev-window-readable"]
    # A hole in the window is reported, not absorbed: without this the caller
    # would render a complete-looking window that is quietly one row short.
    assert window.unavailable_count == 1
    assert window.invalid_count == 0
    assert window.legacy_count == 0
    refute window.truncated
  end

  test "a fault partway through the window walk is unavailable, not a short window", %{
    namespace: namespace
  } do
    authority = authority()
    prefix = Keys.ctl_im_slack_event_receipts_prefix()

    # 26 objects: page one fills, and the walk must ask for page two.
    for index <- 1..26 do
      key = prefix <> "!poison-" <> String.pad_leading("#{index}", 2, "0")
      assert {:ok, _poison} = S3.put(key, Jason.encode!(%{"raw" => "poison"}), if_none_match: "*")
    end

    seed_receipt(authority, "Ev-walk-fault", 1_000, "1787019000.000001")

    Application.put_env(:salix_store, :s3_backend, ContinuationFaultS3)

    assert ReadModel.recent_window(namespace, 0, page_budget: 8) == {:error, :unavailable}
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

  test "recent processing proves each state, groups generations, and never writes", %{
    namespace: namespace
  } do
    authority = authority()

    received = seed_receipt(authority, "Ev-processing-received", 1_000, "1787019000.000001")

    queued_root = "1787019000.000010"

    queued =
      seed_receipt(
        authority,
        "Ev-processing-queued-1",
        2_000,
        queued_root,
        thread_ts: queued_root
      )

    queued_reply =
      seed_receipt(
        authority,
        "Ev-processing-queued-2",
        2_100,
        "1787019000.000011",
        thread_ts: queued_root
      )

    assert Bucketing.append(namespace, queued) == {:ok, :appended}
    assert Bucketing.append(namespace, queued_reply) == {:ok, :appended}

    sealed = seed_receipt(authority, "Ev-processing-sealed", 3_000, "1787019000.000020")
    {_sealed_generation, _scope} = seal_receipts!(namespace, [sealed], 3_100)

    evaluating =
      seed_receipt(authority, "Ev-processing-evaluating", 4_000, "1787019000.000030")

    {evaluating_generation, evaluating_scope} =
      seal_receipts!(namespace, [evaluating], 4_100)

    {_creation, _input} =
      create_v2_fence!(
        namespace,
        evaluating_scope,
        evaluating_generation,
        4_200,
        40_000
      )

    finalizing =
      seed_receipt(authority, "Ev-processing-finalizing", 5_000, "1787019000.000040")

    finalizing_fence = terminal_v2_fence!(namespace, finalizing, 5_100)

    terminal = seed_receipt(authority, "Ev-processing-terminal", 6_000, "1787019000.000050")
    terminal_fence = terminal_v2_fence!(namespace, terminal, 6_100)

    assert {:ok, authorized} =
             RunFence.authorize_projection_from_storage(namespace, terminal_fence)

    assert :ok = Ledger.persist(namespace, authorized)

    unavailable =
      seed_receipt(authority, "Ev-processing-unavailable", 7_000, "1787019000.000060")

    {unavailable_generation, unavailable_scope} =
      seal_receipts!(namespace, [unavailable], 7_100)

    invalid_fence_key =
      SalixStore.TriageKeys.ctl_im_triage_bucket_seal(
        namespace,
        unavailable_scope,
        unavailable_generation["generation"]
      )

    assert {:ok, _poison} = CasRecord.create(invalid_fence_key, %{"schema" => "poison"})

    assert :ok = S3.Fake.reset_put_log()
    assert {:ok, projection} = ReadModel.recent_processing(namespace, 0)
    assert S3.Fake.put_log() == []

    assert projection.scanned_pages == 1
    assert projection.legacy_count == 0
    assert projection.invalid_count == 0
    assert projection.unavailable_count == 0
    assert projection.state_unavailable_count == 1
    refute projection.truncated

    by_state = Enum.group_by(projection.items, & &1.state)

    assert [%{receipt_ref: received_ref, receipt_count: 1}] = by_state.received
    assert received_ref == received["receipt_ref"]

    assert [%{receipt_ref: queued_ref, receipt_count: 2}] = by_state.queued
    assert queued_ref == queued_reply["receipt_ref"]

    assert [%{receipt_count: 1, terminal_status: nil, suggested_action: nil}] = by_state.sealed

    assert [%{receipt_count: 1, terminal_status: nil, suggested_action: nil}] =
             by_state.evaluating

    assert [%{receipt_count: 1, terminal_status: nil, suggested_action: nil}] =
             by_state.finalizing

    assert [
             %{
               receipt_count: 1,
               terminal_status: "failed",
               suggested_action: "silence",
               diagnostics: %{decision_reason: "evaluation_unavailable"}
             }
           ] = by_state.terminal

    assert [%{receipt_count: 1, terminal_status: nil, suggested_action: nil}] =
             by_state.unavailable

    public = inspect(projection)
    refute public =~ namespace
    refute public =~ finalizing_fence["run_id"]
    refute public =~ terminal_fence["run_id"]
    refute public =~ "identity_diagnostic_interrupted_before_transport"
  end

  test "timeline reports recorded status and verifies only the selected receipt" do
    Application.put_env(:salix_store, :triage_record_backend, SalixStore.TriageRecords)
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

  test "timeline status reads buckets and fences in a fixed number of queries" do
    Application.put_env(:salix_store, :triage_record_backend, SalixStore.TriageRecords)
    namespace = SalixStore.TriageKeys.default_namespace()
    group = "batched-processing-#{ULID.generate()}"
    authority = authority()

    # Six threads: before batching, each one cost a bucket and a fence query.
    for ordinal <- 1..6 do
      receipt =
        seed_receipt(
          authority,
          "batched-#{group}-#{ordinal}",
          30_000 + ordinal,
          "1787019100.#{String.pad_leading(to_string(ordinal), 6, "0")}"
        )

      fence = terminal_v2_fence!(namespace, receipt, 31_000 + ordinal)
      assert {:ok, authorized} = RunFence.authorize_projection_from_storage(namespace, fence)
      assert :ok = Ledger.persist(namespace, authorized)
      assert :ok = SalixStore.TriageIntake.observe(group, receipt)
    end

    test_pid = self()
    handler = "batched-processing-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:salix_store, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if self() == test_pid, do: send(test_pid, {:triage_query, query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, page} =
             ReadModel.product_activity("batched-project", group, "batched-agent",
               context_limit: 0,
               include_intake: true
             )

    :telemetry.detach(handler)

    assert {:ok, %{items: items, truncated: false}} = page.intake
    assert length(items) == 6
    assert Enum.all?(items, &(&1.state == :settled and &1.terminal_status == "failed"))

    queries = collect_triage_queries([])
    assert Enum.count(queries, &String.contains?(&1, "triage_buckets AS records")) == 1
    assert Enum.count(queries, &String.contains?(&1, "triage_run_fences")) == 1
  end

  defp collect_triage_queries(acc) do
    receive do
      {:triage_query, query} -> collect_triage_queries([query | acc])
    after
      0 -> acc
    end
  end

  test "recent processing reads a selected bucket and generation once", %{
    namespace: namespace
  } do
    authority = authority()
    root_ts = "1787019000.000090"

    first =
      seed_receipt(authority, "Ev-processing-bounded-1", 9_000, root_ts, thread_ts: root_ts)

    second =
      seed_receipt(authority, "Ev-processing-bounded-2", 9_100, "1787019000.000091",
        thread_ts: root_ts
      )

    {sealed, scope} = seal_receipts!(namespace, [first, second], 9_200)
    {_creation, _input} = create_v2_fence!(namespace, scope, sealed, 9_300, 10_000)

    bucket_key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)

    fence_key =
      SalixStore.TriageKeys.ctl_im_triage_bucket_seal(
        namespace,
        scope,
        sealed["generation"]
      )

    assert :ok = S3.Fake.reset_read_log()
    assert {:ok, projection} = ReadModel.recent_processing(namespace, 0)

    assert [%{state: :evaluating, receipt_count: 2}] = projection.items

    reads = S3.Fake.read_log()
    assert Enum.count(reads, &(&1 == {:get, bucket_key})) == 1
    assert Enum.count(reads, &(&1 == {:get, fence_key})) == 1
  end

  test "sealed connect conflicts preserve generation count and observed time", %{
    namespace: namespace
  } do
    shared_generation = ULID.generate()

    first_authority = %{authority() | "connect_generation" => shared_generation}

    second_authority = %{
      first_authority
      | "connect_id" => "connect-atlas-reconnected",
        "bot_user_id" => "U_BFT_RECONNECTED"
    }

    root_ts = "1787019000.000099"

    first =
      seed_receipt(
        first_authority,
        "Ev-processing-sealed-connect-conflict-1",
        10_500,
        root_ts,
        thread_ts: root_ts
      )

    second =
      seed_receipt(
        second_authority,
        "Ev-processing-sealed-connect-conflict-2",
        10_600,
        "1787019000.000100",
        thread_ts: root_ts
      )

    {_sealed, _scope} = seal_receipts!(namespace, [first, second], 10_700)

    assert {:ok, projection} = ReadModel.recent_processing(namespace, 0)

    assert [
             %{
               state: :unavailable,
               receipt_count: 2,
               observed_at_ms: 10_700
             }
           ] = projection.items
  end

  test "explicit receipt debug reads one existing run and refuses a foreign group", %{
    namespace: namespace
  } do
    receipt =
      seed_receipt(
        authority(),
        "Ev-model-debug-#{Ecto.UUID.generate()}",
        9_000,
        "1787019000.000099"
      )

    fence = terminal_v2_fence!(namespace, receipt, 9_100)
    assert {:ok, projection} = RunFence.authorize_projection_from_storage(namespace, fence)
    assert :ok = Ledger.persist(namespace, projection)
    group = "debug-group-#{System.unique_integer([:positive])}"
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

  test "debug retains all three stored requests and rejects an oversized record", %{
    namespace: namespace
  } do
    receipt =
      seed_receipt(
        authority(),
        "Ev-three-request-debug-#{Ecto.UUID.generate()}",
        9_000,
        "1787019000.000099"
      )

    fence = terminal_v2_fence!(namespace, receipt, 9_100)
    assert {:ok, projection} = RunFence.authorize_projection_from_storage(namespace, fence)
    assert :ok = Ledger.persist(namespace, projection)
    group = "three-request-debug-#{System.unique_integer([:positive])}"
    assert :ok = SalixStore.TriageIntake.observe(group, receipt)

    selection = %{
      "communication" => "silence",
      "investigate" => true,
      "reason" => "Read the original source before answering."
    }

    requests =
      for ordinal <- 1..3, do: %{"phase" => ordinal, "input" => String.duplicate("x", 600_000)}

    # Seed retained evidence through the fixture store; this test exercises the
    # bounded admin read, not provider provenance or model-result acceptance.
    replace_debug_evidence!(namespace, fence["run_id"], requests, selection)

    assert {:ok, debug} =
             ReadModel.model_debug(
               namespace,
               "project",
               group,
               "agent",
               "receipt",
               receipt["receipt_ref"]
             )

    assert debug.requests == requests
    assert debug.participation_decision == selection

    oversized =
      for ordinal <- 1..3, do: %{"phase" => ordinal, "input" => String.duplicate("x", 750_000)}

    replace_debug_evidence!(namespace, fence["run_id"], oversized, selection)

    assert {:error, :too_large} =
             ReadModel.model_debug(
               namespace,
               "project",
               group,
               "agent",
               "receipt",
               receipt["receipt_ref"]
             )
  end

  defp replace_debug_evidence!(namespace, run_id, requests, selection) do
    chain = Enum.map(requests, &%{"payload_bytes" => Jason.encode!(&1)})
    run_key = SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, run_id)
    replay_key = SalixStore.TriageKeys.ctl_im_triage_replay(namespace, run_id)

    assert {:ok, run} =
             CasRecord.update(run_key, fn run ->
               Map.put(run, "evaluator", %{
                 "provider_payload_chain" => chain,
                 "participation_decision" => selection
               })
             end)

    assert {:ok, _} =
             CasRecord.update(
               replay_key,
               &Map.put(&1, "run_sha256", CanonicalJSON.sha256(CanonicalJSON.encode!(run)))
             )
  end

  test "recent processing reads terminal evidence once per selected generation", %{
    namespace: namespace
  } do
    authority = authority()
    root_ts = "1787019000.000092"

    first =
      seed_receipt(authority, "Ev-processing-terminal-bounded-1", 9_400, root_ts,
        thread_ts: root_ts
      )

    second =
      seed_receipt(
        authority,
        "Ev-processing-terminal-bounded-2",
        9_500,
        "1787019000.000093",
        thread_ts: root_ts
      )

    {sealed, scope} = seal_receipts!(namespace, [first, second], 9_600)
    {creation, _input} = create_v2_fence!(namespace, scope, sealed, 9_700, 9_701)
    assert {:ok, terminal_fence} = RunFence.recover_open(namespace, creation.record, :deadline)

    assert {:ok, authorized} =
             RunFence.authorize_projection_from_storage(namespace, terminal_fence)

    assert :ok = Ledger.persist(namespace, authorized)

    bucket_key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)

    fence_key =
      SalixStore.TriageKeys.ctl_im_triage_bucket_seal(
        namespace,
        scope,
        sealed["generation"]
      )

    replay_key =
      SalixStore.TriageKeys.ctl_im_triage_replay(namespace, terminal_fence["run_id"])

    run_key =
      SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, terminal_fence["run_id"])

    assert :ok = S3.Fake.reset_read_log()
    assert {:ok, projection} = ReadModel.recent_processing(namespace, 0)
    assert [%{state: :terminal, receipt_count: 2}] = projection.items

    reads = S3.Fake.read_log()
    assert Enum.count(reads, &(&1 == {:get, bucket_key})) == 1
    assert Enum.count(reads, &(&1 == {:get, fence_key})) == 1
    assert Enum.count(reads, &(&1 == {:get, replay_key})) == 1
    assert Enum.count(reads, &(&1 == {:get, run_key})) == 1
  end

  test "recent processing rejects a bucket beyond its total record budget", %{
    namespace: namespace
  } do
    authority = authority()
    root_ts = "1787019000.000094"

    selected =
      seed_receipt(authority, "Ev-processing-oversized-selected", 9_800, root_ts,
        thread_ts: root_ts
      )

    oversized =
      selected
      |> Map.merge(%{
        "event_id" => "Ev-processing-oversized-bucket-only",
        "created_at" => 9_900,
        "receipt_ref" => "s3://oversized-bucket-only",
        "source_message_ref" => "oversized-bucket-only"
      })
      |> put_in(["triage_event", "event_id"], "Ev-processing-oversized-bucket-only")
      |> put_in(["triage_event", "message_ts"], "1787019000.000095")
      |> put_in(
        ["triage_event", "text"],
        String.duplicate("x", 4 * 1024 * 1024 + 1_024)
      )
      |> put_in(["triage_event", "endpoint_provenance", "captured_at_ms"], 9_900)

    assert Bucketing.append(namespace, selected) == {:ok, :appended}
    assert Bucketing.append(namespace, oversized) == {:ok, :appended}

    scope = Bucketing.scope_key(selected)
    bucket_key = SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope)

    assert :ok = S3.Fake.reset_read_log()
    assert {:ok, projection} = ReadModel.recent_processing(namespace, 0)

    assert [%{state: :unavailable, receipt_ref: receipt_ref}] = projection.items
    assert receipt_ref == selected["receipt_ref"]
    assert projection.state_unavailable_count == 1
    assert projection.truncated
    assert Enum.count(S3.Fake.read_log(), &(&1 == {:get, bucket_key})) == 1
  end

  test "recent processing enforces one aggregate budget across bucket scopes", %{
    namespace: namespace
  } do
    authority = authority()

    older =
      seed_receipt(authority, "Ev-processing-budget-older", 10_000, "1787019000.000096")

    newer =
      seed_receipt(authority, "Ev-processing-budget-newer", 10_100, "1787019000.000097")

    for receipt <- [older, newer] do
      assert Bucketing.append(namespace, receipt) == {:ok, :appended}

      namespace
      |> SalixStore.TriageKeys.ctl_im_triage_bucket(Bucketing.scope_key(receipt))
      |> pad_record!(div(4 * 1024 * 1024, 2) + 1_024)
    end

    bucket_keys =
      Enum.map([older, newer], fn receipt ->
        SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, Bucketing.scope_key(receipt))
      end)

    assert :ok = S3.Fake.reset_read_log()
    assert {:ok, projection} = ReadModel.recent_processing(namespace, 0)

    assert Enum.count(projection.items, &(&1.state == :queued)) == 1
    assert Enum.count(projection.items, &(&1.state == :unavailable)) == 1
    assert projection.truncated

    reads = S3.Fake.read_log()

    for bucket_key <- bucket_keys do
      assert Enum.count(reads, &(&1 == {:get, bucket_key})) == 1
    end
  end

  test "recent processing enforces one aggregate budget across terminal evidence", %{
    namespace: namespace
  } do
    authority = authority()
    root_ts = "1787019000.000098"
    receipt = seed_receipt(authority, "Ev-processing-terminal-budget", 10_200, root_ts)
    {sealed, scope} = seal_receipts!(namespace, [receipt], 10_300)
    {creation, _input} = create_v2_fence!(namespace, scope, sealed, 10_400, 10_401)
    assert {:ok, terminal_fence} = RunFence.recover_open(namespace, creation.record, :deadline)

    assert {:ok, authorized} =
             RunFence.authorize_projection_from_storage(namespace, terminal_fence)

    assert :ok = Ledger.persist(namespace, authorized)

    keys = [
      SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope),
      SalixStore.TriageKeys.ctl_im_triage_bucket_seal(
        namespace,
        scope,
        sealed["generation"]
      ),
      SalixStore.TriageKeys.ctl_im_triage_replay(namespace, terminal_fence["run_id"]),
      SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, terminal_fence["run_id"])
    ]

    Enum.each(keys, &pad_record!(&1, 1_050_000))

    assert :ok = S3.Fake.reset_read_log()
    assert {:ok, projection} = ReadModel.recent_processing(namespace, 0)

    assert [%{state: :unavailable}] = projection.items
    assert projection.truncated

    reads = S3.Fake.read_log()

    for key <- keys do
      assert Enum.count(reads, &(&1 == {:get, key})) == 1
    end
  end

  test "recent processing validates legacy v1 fences and requires ledger agreement", %{
    namespace: namespace
  } do
    authority = authority()
    receipt = seed_receipt(authority, "Ev-processing-v1", 8_000, "1787019000.000070")
    {sealed, scope} = seal_receipts!(namespace, [receipt], 8_100)
    now = 8_200

    fence = %{
      "schema" => "comma.triage-bucket-fence.v1",
      "bucket_scope" => scope,
      "generation" => sealed["generation"],
      "run_id" => ULID.generate(),
      "created_at" => now,
      "deadline_at" => now + 1_000,
      "input_snapshot" => %{
        "schema" => "comma.triage-input-snapshot.v1",
        "generation" => sealed["generation"],
        "events" => [receipt["triage_event"]],
        "receipt_refs" => [receipt["receipt_ref"]]
      },
      "terminal" => %{
        "terminal_id" => ULID.generate(),
        "status" => "evaluated",
        "decision" => %{"action" => "reply"},
        "evaluator" => %{"legacy_proof" => true},
        "settled_at" => now + 10
      }
    }

    key =
      SalixStore.TriageKeys.ctl_im_triage_bucket_seal(
        namespace,
        scope,
        sealed["generation"]
      )

    assert {:ok, ^fence} = CasRecord.create(key, fence)
    assert {:ok, before_ledger} = ReadModel.recent_processing(namespace, 0)

    assert [%{state: :finalizing, terminal_status: nil, suggested_action: nil}] =
             before_ledger.items

    assert :ok = Ledger.persist(namespace, fence)
    assert :ok = S3.Fake.reset_put_log()
    assert {:ok, after_ledger} = ReadModel.recent_processing(namespace, 0)
    assert S3.Fake.put_log() == []

    assert [
             %{
               state: :terminal,
               terminal_status: "evaluated",
               suggested_action: "reply",
               diagnostics: diagnostics
             }
           ] = after_ledger.items

    assert diagnostics.source == %{
             channel_id: "C_ATLAS",
             thread_ts: "1787019000.000070",
             event_type: "message",
             addressing_kind: "ambient",
             trigger_kind: "none",
             source_mode: "callback",
             actor_kind: "human",
             fast_path: false
           }

    assert diagnostics.milestones == %{
             received_at_ms: 8_000,
             sealed_at_ms: 8_100,
             evaluation_started_at_ms: 8_200,
             settled_at_ms: 8_210
           }

    assert diagnostics.decision_reason == nil
    assert diagnostics.evaluator == nil
    assert diagnostics.trace_ref =~ ~r/^triage-[0-9a-f]{12}$/

    assert ReadModel.recent_processing(namespace, 0, limit: 0) ==
             {:error, :invalid_triage_recent_processing}

    assert ReadModel.recent_processing(namespace, 0, limit: 21) ==
             {:error, :invalid_triage_recent_processing}

    assert ReadModel.recent_processing(namespace, 0, unknown: true) ==
             {:error, :invalid_triage_recent_processing}
  end

  test "recent processing contains a malformed legacy decision to one unavailable item", %{
    namespace: namespace
  } do
    receipt = seed_receipt(authority(), "Ev-processing-bad-v1", 8_300, "1787019000.000080")
    {sealed, scope} = seal_receipts!(namespace, [receipt], 8_400)

    fence = %{
      "schema" => "comma.triage-bucket-fence.v1",
      "bucket_scope" => scope,
      "generation" => sealed["generation"],
      "run_id" => ULID.generate(),
      "created_at" => 8_500,
      "deadline_at" => 9_500,
      "input_snapshot" => %{
        "schema" => "comma.triage-input-snapshot.v1",
        "generation" => sealed["generation"],
        "events" => [receipt["triage_event"]],
        "receipt_refs" => [receipt["receipt_ref"]]
      },
      "terminal" => %{
        "terminal_id" => ULID.generate(),
        "status" => "evaluated",
        "decision" => "malformed legacy value",
        "evaluator" => %{"legacy_proof" => true},
        "settled_at" => 8_510
      }
    }

    key =
      SalixStore.TriageKeys.ctl_im_triage_bucket_seal(
        namespace,
        scope,
        sealed["generation"]
      )

    assert {:ok, ^fence} = CasRecord.create(key, fence)
    assert {:ok, projection} = ReadModel.recent_processing(namespace, 0)

    assert projection.state_unavailable_count == 1

    assert [%{state: :unavailable, terminal_status: nil, suggested_action: nil}] =
             projection.items
  end

  # ---- ring ----

  test "ring status reports absent refs as not running" do
    assert {:ok, ring} = ReadModel.ring_status(%{runtime: nil, recovery: nil})

    assert %{
             running: false,
             mode: nil,
             namespace: nil,
             evaluation_ready: false,
             active_evaluations: 0,
             open_buckets: 0,
             scheduled_buckets: 0,
             observed_at_ms: observed_at_ms
           } = ring.runtime

    assert is_integer(observed_at_ms)

    assert ring.recovery == %{
             running: false,
             phase: nil,
             cursor: nil,
             holder: nil,
             lease_held: false,
             page_limit: nil,
             batch_limit: nil,
             backoff_ms: nil,
             pending_receipts: 0
           }

    refute ring.running

    # An unregistered supervised name is the runtime being off, not a fault.
    # Use test-only names: the production bindings are now expected to be live
    # under the admission-only product default.
    assert {:ok, unnamed} =
             ReadModel.ring_status(%{
               runtime: __MODULE__.MissingTriageReviewRuntime,
               recovery: __MODULE__.MissingTriageReceiptRecovery
             })

    refute unnamed.running
    assert ReadModel.ring_status(:not_a_map) == {:error, :unavailable}
  end

  test "ring status projects a live runtime and a stubbed recovery", %{namespace: namespace} do
    runtime =
      start_supervised!({Runtime, name: nil, mode: :review, namespace: namespace}, id: make_ref())

    status = %{
      phase: :resolve,
      cursor: "v1.cursor",
      holder: "node@host:01",
      lease_held: true,
      page_limit: 25,
      batch_limit: 5,
      backoff_ms: 250,
      pending_receipts: 3
    }

    {:ok, recovery} = StubRing.start_link(%{status: status})

    assert {:ok, ring} = ReadModel.ring_status(%{runtime: runtime, recovery: recovery})
    assert ring.running
    assert ring.recovery == Map.put(status, :running, true)
    assert ring.runtime.running
    assert ring.runtime.mode == :review
    assert ring.runtime.namespace == namespace
    refute ring.runtime.evaluation_ready
    assert ring.runtime.active_evaluations == 0
    assert ring.runtime.open_buckets == 0
    assert ring.runtime.scheduled_buckets == 0
    assert is_integer(ring.runtime.observed_at_ms)

    off =
      start_supervised!({Runtime, name: nil, mode: :off, namespace: namespace}, id: make_ref())

    assert {:ok, off_status} = ReadModel.ring_status(%{runtime: off, recovery: recovery})
    assert off_status.runtime.running
    assert off_status.runtime.mode == :off
    assert off_status.runtime.namespace == nil
    refute off_status.runtime.evaluation_ready
    assert off_status.running

    :ok = GenServer.stop(recovery)

    assert ReadModel.ring_status(%{runtime: runtime, recovery: recovery}) ==
             {:error, :unavailable}

    assert ReadModel.ring_status(%{runtime: recovery, recovery: nil}) == {:error, :unavailable}
  end

  test "ring status distinguishes product wiring from per-Agent evaluator readiness", %{
    namespace: namespace
  } do
    not_ready =
      start_supervised!({Runtime, name: nil, mode: :review, namespace: namespace}, id: make_ref())

    ready =
      start_supervised!(
        {Runtime,
         name: nil,
         mode: :review,
         namespace: namespace,
         context_port: {:"Elixir.BridgeForTeams.TriageContext", []},
         evaluator_port: {:"Elixir.Salix.Bindings.TriageEvaluator", []},
         review_projection: :slack},
        id: make_ref()
      )

    {:ok, recovery} = StubRing.start_link(%{status: %{phase: :resolve}})

    assert {:ok, dark_ring} = ReadModel.ring_status(%{runtime: not_ready, recovery: recovery})
    refute dark_ring.runtime.evaluation_ready

    assert {:ok, ready_ring} = ReadModel.ring_status(%{runtime: ready, recovery: recovery})
    # Wiring alone cannot claim that an unspecified Agent's live provider
    # template is complete.
    refute ready_ring.runtime.evaluation_ready
    assert ready_ring.runtime.active_evaluations == 0
    assert ready_ring.runtime.open_buckets == 0
    assert ready_ring.runtime.scheduled_buckets == 0
    assert is_integer(ready_ring.runtime.observed_at_ms)

    assert Runtime.status(ready).evaluator_wired

    receipt = seed_receipt(authority(), "Ev-runtime-status", 1_000, "1787019000.000010")
    assert Bucketing.append(namespace, receipt) == {:ok, :appended}
    assert {:ok, durable} = Bucketing.load(namespace, Bucketing.scope_key(receipt))

    # The cast and following status call share one sender, so the call observes
    # the admitted local bucket without polling or reaching into GenServer
    # internals. These are O(1) sizes of the runtime-owned maps, not a durable
    # keyspace scan presented as a queue total.
    GenServer.cast(ready, {:admitted, receipt, durable, %{}})
    runtime_status = Runtime.status(ready)
    assert runtime_status.open_buckets == 1
    assert runtime_status.scheduled_buckets == 1
    assert runtime_status.active_evaluations == 0

    wrong_port =
      start_supervised!(
        {Runtime,
         name: nil,
         mode: :review,
         namespace: namespace,
         context_port: {__MODULE__, []},
         evaluator_port: {:"Elixir.Salix.Bindings.TriageEvaluator", []},
         review_projection: :slack},
        id: make_ref()
      )

    refute Runtime.status(wrong_port).evaluator_wired
  end

  test "the recovery ring answers a read-only status handle", %{namespace: namespace} do
    runtime =
      start_supervised!({Runtime, name: nil, mode: :review, namespace: namespace}, id: make_ref())

    recovery =
      start_supervised!(
        {ReceiptRecovery,
         name: nil,
         runtime: runtime,
         page_limit: 1,
         interval_ms: 5,
         full_ring_idle_ms: 25,
         held_poll_ms: 25,
         lease_key: "ctl/test/triage-read-model/#{System.unique_integer([:positive])}",
         lease_ttl_ms: 5_000},
        id: make_ref()
      )

    assert {:ok, ring} = ReadModel.ring_status(%{runtime: runtime, recovery: recovery})
    assert ring.running
    assert ring.recovery.phase in [:list, :resolve, :admit]
    assert ring.recovery.page_limit == 1
    assert ring.recovery.batch_limit == 5
    assert is_binary(ring.recovery.holder)
    assert Process.alive?(recovery)
  end

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

  test "a legacy Slack connect without an inbound Agent id belongs to the current router" do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    router_agent_id = Ids.new_agent_id(group_id)

    group = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "router_agent_id" => router_agent_id,
      "router_conversation_id" => Ids.new_conversation_id()
    }

    assert {:ok, _group} = CasRecord.create(Keys.ctl_group(group_id), group)

    legacy =
      tenant_id
      |> slack_connect(group_id, "Legacy workspace", 1)
      |> Map.delete("inbound_agent_id")

    assert {:ok, _connect} =
             CasRecord.create(Keys.ctl_im_connect(group_id, legacy["connect_id"]), legacy)

    assert {:ok, [posture]} = ReadModel.connect_posture(tenant_id, group_id)
    assert posture.inbound_agent_id == router_agent_id
  end

  test "a disabled Slack installation keeps its tuple but is not a ready context source" do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    router_agent_id = Ids.new_agent_id(group_id)

    group = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "router_agent_id" => router_agent_id,
      "router_conversation_id" => Ids.new_conversation_id()
    }

    assert {:ok, _group} = CasRecord.create(Keys.ctl_group(group_id), group)

    connect =
      tenant_id
      |> slack_connect(group_id, "Disabled source", 1)
      |> Map.put("inbound_agent_id", router_agent_id)

    assert {:ok, _connect} =
             CasRecord.create(Keys.ctl_im_connect(group_id, connect["connect_id"]), connect)

    assert :ok = ProviderConnects.disable_im_connect(tenant_id, group_id, connect["connect_id"])
    assert {:ok, [posture]} = ReadModel.connect_posture(tenant_id, group_id)

    assert posture.posture_complete? == true
    assert posture.connect_generation == connect["connect_generation"]
    assert posture.workspace_id == connect["workspace_id"]
    assert posture.app_id == connect["app_id"]
    assert posture.source_ready? == false
  end

  test "a connect whose stored record cannot be read is marked incomplete, alone" do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    group = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "router_agent_id" => Ids.new_agent_id(group_id),
      "router_conversation_id" => Ids.new_conversation_id()
    }

    assert {:ok, _group} = CasRecord.create(Keys.ctl_group(group_id), group)

    healthy =
      tenant_id
      |> slack_connect(group_id, "Healthy", 2)
      |> Map.merge(%{"triage_provisioned_at" => 1, "triage_enabled" => true})

    unreadable =
      tenant_id
      |> slack_connect(group_id, "Unreadable", 1)
      |> Map.merge(%{"triage_provisioned_at" => 1, "triage_enabled" => true})

    for connect <- [healthy, unreadable] do
      assert {:ok, _connect} =
               CasRecord.create(Keys.ctl_im_connect(group_id, connect["connect_id"]), connect)
    end

    Application.put_env(:salix_store, :s3_backend, FaultingGetS3)

    # The connect list reads every record once; `posture/2` then reads the raw
    # record again per connect. Faulting only that second read is exactly the
    # partial failure this field exists for.
    FaultingGetS3.fault_get(Keys.ctl_im_connect(group_id, unreadable["connect_id"]), 1)

    assert {:ok, postures} = ReadModel.connect_posture(tenant_id, group_id)
    by_id = Map.new(postures, &{&1.connect_id, &1})

    # One unreadable record degrades one row; the group still answers.
    assert length(postures) == 2
    assert by_id[healthy["connect_id"]].posture_complete? == true
    assert by_id[healthy["connect_id"]].provisioned? == true
    assert by_id[healthy["connect_id"]].connect_generation == healthy["connect_generation"]

    row = by_id[unreadable["connect_id"]]
    assert row.posture_complete? == false
    # The display fields survive: they come from the public projection, which
    # was read successfully.
    assert row.workspace_name == "Unreadable"
    assert row.triage_enabled == true
    # These two come from the raw record and are therefore defaults, not
    # observations — which is precisely why the row must not be acted on.
    assert row.provisioned? == false
    assert row.connect_generation == nil
    assert row.workspace_id == nil
    assert row.source_ready? == false
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

  defp pad_record!(key, padding_bytes) do
    assert {:ok, %{body: body, etag: etag}} = S3.get(key)

    assert {:ok, _stored} =
             S3.put(key, [body, String.duplicate(" ", padding_bytes)], if_match: etag)
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
