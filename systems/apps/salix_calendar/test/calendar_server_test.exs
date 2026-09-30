defmodule SalixCalendar.ServerTest do
  use ExUnit.Case, async: false

  alias SalixCalendar.{AgentAPI, Occurrences, Placement, Recurrence, Server, SourceActor}
  alias SalixCalendar.SourceAdapter.SalixTaskSchedule
  alias SalixStore.{Crypto, Ids, JSON, Keys, Lease, S3}

  defmodule ExpiringAdapter do
    @behaviour SalixCalendar.SourceAdapter

    @impl true
    def adapter_contract_id, do: "test.expiring.v1"

    @impl true
    def normalize(record, _opts), do: {:ok, record}

    @impl true
    def start_sync(_source, _query, "expired"), do: {:error, :cursor_expired}

    def start_sync(_source, _query, nil) do
      case Application.get_env(:salix_calendar, :expiring_adapter_mode, :initial) do
        :initial ->
          {:ok,
           %{
             "changes" => [record("kept", "Before rebuild"), record("removed", "Removed")],
             "next_continuation" => nil,
             "completed_cursor" => "expired"
           }}

        :unchanged ->
          {:ok,
           %{
             "changes" => [record("kept", "Before rebuild"), record("added", "New meeting")],
             "next_continuation" => "rebuild-page-2",
             "completed_cursor" => nil
           }}

        :rebuild ->
          {:ok,
           %{
             "changes" => [record("kept", "After rebuild")],
             "next_continuation" => "rebuild-page-2",
             "completed_cursor" => nil
           }}
      end
    end

    @impl true
    def continue_sync(_source, _query, "rebuild-page-2") do
      {:ok,
       %{
         "changes" => [],
         "next_continuation" => nil,
         "completed_cursor" => "fresh"
       }}
    end

    defp record(locator, title) do
      %{
        "external_locator" => %{"event_id" => locator},
        "source_revision" => [if(title == "After rebuild", do: 2, else: 1)],
        "source_version" => %{"etag" => title},
        "copy_role" => "organizer",
        "object" => %{
          "@type" => "Event",
          "uid" => locator,
          "title" => title,
          "start" => "2026-07-20T10:00:00",
          "duration" => "PT30M",
          "timeZone" => "Asia/Shanghai"
        },
        "scheduling_identity" => %{
          "identity_version" => "test.v1",
          "namespace" => "test",
          "series_uid" => locator,
          "scheduling_authority_key" => "owner@example.com"
        },
        "scheduling_revision" => %{
          "sequence" => if(title == "After rebuild", do: 2, else: 1),
          "updated" => "2026-07-20T00:00:00Z",
          "shared_fact_hash" => title
        },
        "normalization_state" => "complete"
      }
    end
  end

  defmodule CountingActivationAdapter do
    @behaviour SalixCalendar.SourceAdapter

    @impl true
    def adapter_contract_id, do: "test.counting-activation.v1"

    @impl true
    def normalize(record, _opts), do: {:ok, record}

    @impl true
    def start_sync(_source, _query, nil) do
      count_call()
      changes = Application.fetch_env!(:salix_calendar, :counting_activation_changes)

      if length(changes) > 200 do
        {:ok,
         %{
           "changes" => Enum.take(changes, 200),
           "next_continuation" => "counting-page-2",
           "completed_cursor" => nil
         }}
      else
        page(changes)
      end
    end

    def start_sync(_source, _query, _cursor), do: start_sync(nil, nil, nil)

    @impl true
    def continue_sync(_source, _query, "counting-page-2") do
      count_call()

      Application.fetch_env!(:salix_calendar, :counting_activation_changes)
      |> Enum.drop(200)
      |> page()
    end

    defp page(changes) do
      {:ok,
       %{
         "changes" => changes,
         "next_continuation" => nil,
         "completed_cursor" => "counting-sync-1"
       }}
    end

    defp count_call do
      calls = Application.get_env(:salix_calendar, :counting_activation_calls, 0)
      Application.put_env(:salix_calendar, :counting_activation_calls, calls + 1)
    end
  end

  defmodule ContractChangeAdapter do
    @behaviour SalixCalendar.SourceAdapter

    @impl true
    def adapter_contract_id, do: "test.contract-change.v1"

    @impl true
    def normalize(record, _opts), do: {:ok, record}

    @impl true
    def start_sync(_source, %{"coverage" => "initial"}, nil),
      do: page([record("existing", "Existing")], "initial-cursor")

    def start_sync(_source, %{"coverage" => "expanded"}, nil),
      do:
        page(
          [record("existing", "Existing"), record("newly-covered", "Newly covered")],
          "expanded-cursor"
        )

    def start_sync(_source, %{"coverage" => "staged-a"}, nil) do
      {:ok,
       %{
         "changes" => [record("staged-a", "Staged contract A")],
         "next_continuation" => "staged-a-page-2",
         "completed_cursor" => nil
       }}
    end

    def start_sync(_source, %{"coverage" => "shared-initial"}, nil),
      do: page([record("shared", "Existing shared fact")], "shared-initial-cursor")

    def start_sync(_source, %{"coverage" => "shared-staged-a"}, nil) do
      {:ok,
       %{
         "changes" => [record("shared", "Stale staged contract A")],
         "next_continuation" => "shared-staged-a-page-2",
         "completed_cursor" => nil
       }}
    end

    def start_sync(_source, %{"coverage" => "shared-latest-b"}, nil) do
      {:ok,
       %{
         "changes" => [record("shared", "Latest staged contract B")],
         "next_continuation" => "shared-latest-b-page-2",
         "completed_cursor" => nil
       }}
    end

    def start_sync(_source, %{"coverage" => "latest-b"}, nil),
      do: page([record("latest-b", "Latest contract B")], "latest-b-cursor")

    # A provider delta cursor cannot backfill facts that were outside the old query
    # coverage. Sync must therefore never replay it under a changed query contract.
    def start_sync(_source, %{"coverage" => "expanded"}, "initial-cursor"),
      do: page([], "expanded-cursor")

    @impl true
    def continue_sync(_source, %{"coverage" => "staged-a"}, "staged-a-page-2"),
      do: page([], "staged-a-cursor")

    def continue_sync(
          _source,
          %{"coverage" => "shared-staged-a"},
          "shared-staged-a-page-2"
        ),
        do: page([], "shared-staged-a-cursor")

    def continue_sync(
          _source,
          %{"coverage" => "shared-latest-b"},
          "shared-latest-b-page-2"
        ),
        do: page([], "shared-latest-b-cursor")

    defp page(changes, cursor) do
      {:ok,
       %{
         "changes" => changes,
         "next_continuation" => nil,
         "completed_cursor" => cursor
       }}
    end

    defp record(locator, title) do
      %{
        "external_locator" => %{"event_id" => locator},
        "copy_role" => "organizer",
        "object" => %{
          "@type" => "Event",
          "uid" => locator,
          "title" => title,
          "start" => "2026-07-20T10:00:00",
          "duration" => "PT30M",
          "timeZone" => "Asia/Shanghai"
        },
        "scheduling_identity" => %{
          "identity_version" => "test.v1",
          "namespace" => "test",
          "series_uid" => locator,
          "scheduling_authority_key" => "owner@example.com"
        },
        "scheduling_revision" => %{
          "sequence" => contract_change_sequence(title),
          "updated" => "2026-07-20T00:00:00Z",
          "shared_fact_hash" => title
        },
        "normalization_state" => "complete"
      }
    end

    defp contract_change_sequence("Stale staged contract A"), do: 2
    defp contract_change_sequence("Latest staged contract B"), do: 3
    defp contract_change_sequence(_title), do: 1
  end

  defmodule RacingSyncAdapter do
    @behaviour SalixCalendar.SourceAdapter

    @impl true
    def adapter_contract_id, do: "test.racing-sync.v1"

    @impl true
    def normalize(record, _opts), do: {:ok, record}

    @impl true
    def start_sync(_source, _query, completed_cursor), do: read_page(completed_cursor)

    @impl true
    def continue_sync(_source, _query, continuation), do: read_page(continuation)

    defp read_page(cursor) do
      test_pid = Application.fetch_env!(:salix_calendar, :racing_sync_test_pid)
      request_ref = make_ref()
      send(test_pid, {:racing_sync_read, self(), request_ref, cursor})

      receive do
        {:racing_sync_page, ^request_ref, page} -> {:ok, page}
      after
        5_000 -> {:error, :racing_sync_test_timeout}
      end
    end

    @impl true
    def exact_refresh(_source, _item, _occurrence) do
      test_pid = Application.fetch_env!(:salix_calendar, :racing_sync_test_pid)
      request_ref = make_ref()
      send(test_pid, {:racing_exact_read, self(), request_ref})

      receive do
        {:racing_exact_record, ^request_ref, record} -> {:ok, record}
      after
        5_000 -> {:error, :racing_exact_test_timeout}
      end
    end
  end

  defmodule ControlledS3 do
    @behaviour SalixStore.S3

    alias SalixStore.S3.Fake

    @impl true
    def put(key, body, opts) do
      case Application.get_env(:salix_calendar, :controlled_source_put) do
        %{key: ^key, caller: caller, controller: controller}
        when is_pid(controller) ->
          if caller == :any or caller == self() do
            ref = make_ref()
            send(controller, {:controlled_source_put, self(), ref, key, body, opts})

            receive do
              {:controlled_source_put_continue, ^ref} -> Fake.put(key, body, opts)
              {:controlled_source_put_reply, ^ref, reply} -> reply
            after
              5_000 -> {:error, :controlled_source_put_timeout}
            end
          else
            Fake.put(key, body, opts)
          end

        _ ->
          Fake.put(key, body, opts)
      end
    end

    @impl true
    defdelegate put_stream(key, stream, opts), to: Fake

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

    @impl true
    defdelegate get(key, opts), to: Fake

    @impl true
    defdelegate stream(key, opts), to: Fake

    @impl true
    defdelegate head(key), to: Fake

    @impl true
    defdelegate delete(key, opts), to: Fake

    @impl true
    defdelegate list(prefix, opts), to: Fake
  end

  defmodule FixtureAdapter do
    @behaviour SalixCalendar.SourceAdapter

    @impl true
    def adapter_contract_id, do: SalixTaskSchedule.adapter_contract_id()

    @impl true
    def normalize(record, _opts), do: {:ok, record}

    @impl true
    def start_sync(source, _query, _cursor), do: page(source)

    @impl true
    def continue_sync(source, _query, _continuation), do: page(source)

    defp page(source) do
      source_id = source["source_id"]
      fixtures = Application.get_env(:salix_calendar, :source_actor_fixtures, %{})
      fixture = Map.get(fixtures, source_id, %{records: [], cursor: 0})

      {:ok,
       %{
         "changes" => fixture.records,
         "next_continuation" => nil,
         "completed_cursor" => "fixture-#{fixture.cursor}"
       }}
    end
  end

  defmodule RetirementSink do
    def cancel_scheduling_link(group_id, calendar_id, link_id, cursor) do
      test_pid = Application.fetch_env!(:salix_calendar, :retirement_test_pid)
      send(test_pid, {:retire_scheduling_link, group_id, calendar_id, link_id, cursor})
      Application.get_env(:salix_calendar, :retirement_test_result, {:ok, nil})
    end
  end

  defmodule BlockingRetirementSink do
    def cancel_scheduling_link(group_id, calendar_id, link_id, cursor) do
      test_pid = Application.fetch_env!(:salix_calendar, :retirement_test_pid)
      ref = make_ref()

      send(
        test_pid,
        {:blocking_retirement_entered, self(), ref, group_id, calendar_id, link_id, cursor}
      )

      receive do
        {:continue_retirement, ^ref} -> {:ok, nil}
      after
        5_000 -> {:error, :blocking_retirement_timeout}
      end
    end
  end

  setup do
    S3.Fake.reset()

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    assert {:ok, _} =
             S3.put(
               SalixStore.Keys.ctl_group(group_id),
               Jason.encode!(%{"group_id" => group_id, "tenant_id" => tenant_id}),
               if_none_match: "*"
             )

    assert {:ok, calendar} =
             Server.create_calendar(group_id, %{
               name: "Team calendar",
               default_time_zone: "Asia/Shanghai"
             })

    source_attrs = %{
      adapter: "salix_task_schedule",
      adapter_contract_id: SalixTaskSchedule.adapter_contract_id(),
      source_locator: %{kind: "group_agent_tasks", group_id: group_id},
      access_profile: "scheduled_tasks_read"
    }

    assert {:ok, source} = Server.ensure_source(group_id, calendar["calendar_id"], source_attrs)

    previous_adapters = Application.get_env(:salix_calendar, :source_adapters)
    previous_sink = Application.get_env(:salix_calendar, :retirement_sink)

    Application.put_env(:salix_calendar, :source_adapters, %{
      "salix_task_schedule" => FixtureAdapter,
      "expiring_test" => ExpiringAdapter,
      "counting_activation_test" => CountingActivationAdapter,
      "contract_change_test" => ContractChangeAdapter,
      "racing_sync_test" => RacingSyncAdapter,
      "racing_sync_timeout_test" => RacingSyncAdapter
    })

    Application.delete_env(:salix_calendar, :retirement_sink)

    on_exit(fn ->
      restore_env(:source_adapters, previous_adapters)
      restore_env(:retirement_sink, previous_sink)
      Application.delete_env(:salix_calendar, :source_actor_fixtures)
      Application.delete_env(:salix_calendar, :retirement_test_pid)
      Application.delete_env(:salix_calendar, :retirement_test_result)
    end)

    {:ok, group_id: group_id, calendar: calendar, source: source, source_attrs: source_attrs}
  end

  test "calendar and source identities are canonical and source ensure is idempotent", context do
    assert Ids.valid_calendar_id?(context.calendar["calendar_id"])
    assert Ids.valid_calendar_source_id?(context.source["source_id"])
    assert context.calendar["tenant_id"] == Ids.tenant_id_from_group!(context.group_id)
    assert context.source["access_profile"] == "scheduled_tasks_read"

    assert {:ok, same_source} =
             Server.ensure_source(
               context.group_id,
               context.calendar["calendar_id"],
               context.source_attrs
             )

    assert same_source["source_id"] == context.source["source_id"]

    assert {:ok, updated_policy} =
             Server.ensure_source(
               context.group_id,
               context.calendar["calendar_id"],
               Map.put(context.source_attrs, :sync_policy, %{"page_size" => 50})
             )

    assert updated_policy["source_id"] == context.source["source_id"]
    assert updated_policy["sync_policy"] == %{"page_size" => 50}
    assert updated_policy["revision"] == context.source["revision"] + 1

    assert {:error, :source_identity_conflict} =
             Server.ensure_source(
               context.group_id,
               context.calendar["calendar_id"],
               Map.put(context.source_attrs, :access_profile, "redacted")
             )
  end

  test "32 concurrent natural-identity ensures resolve one Calendar id and one actor", context do
    identity = %{"kind" => "concurrent-calendar"}
    attrs = %{"name" => "Concurrent calendar", "default_time_zone" => "UTC"}

    calendars =
      1..32
      |> Task.async_stream(
        fn _ -> Server.ensure_calendar(context.group_id, identity, attrs) end,
        max_concurrency: 32,
        timeout: 10_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, {:ok, calendar}} -> calendar end)

    assert length(calendars) == 32
    assert [calendar_id] = calendars |> Enum.map(& &1["calendar_id"]) |> Enum.uniq()

    assert [{pid, _value}] =
             Registry.lookup(SalixCalendar.Registry, {:calendar, context.group_id, calendar_id})

    assert Process.alive?(pid)
  end

  test "natural-identity CAS recovers an ambiguous landed write and rejects a conflicting binding",
       context do
    identity = %{"kind" => "ambiguous-calendar"}
    key = calendar_identity_key(context.group_id, identity)
    :ok = S3.Fake.set_fault({:ambiguous_after, :put, key})

    assert {:ok, calendar} =
             Server.ensure_calendar(context.group_id, identity, %{
               "name" => "Ambiguous calendar",
               "default_time_zone" => "UTC"
             })

    assert {:ok, same} =
             Server.ensure_calendar(context.group_id, identity, %{
               "name" => "Ambiguous calendar",
               "default_time_zone" => "UTC"
             })

    assert same["calendar_id"] == calendar["calendar_id"]

    conflicting_identity = %{"kind" => "conflicting-binding"}

    assert {:ok, _} =
             S3.put(
               calendar_identity_key(context.group_id, conflicting_identity),
               Jason.encode!(%{
                 "calendar_id" => Ids.new_calendar_id(),
                 "identity" => %{"kind" => "different"}
               }),
               if_none_match: "*"
             )

    assert {:error, :calendar_identity_conflict} =
             Server.ensure_calendar(context.group_id, conflicting_identity, %{})
  end

  test "read-only Task import keeps stable item/link ids and excludes private execution data",
       context do
    projection = task_projection()

    assert {:ok, normalized} = SalixTaskSchedule.normalize(projection)
    refute get_in(normalized, ["object", "command"])
    refute get_in(normalized, ["object", "messages"])
    refute get_in(normalized, ["object", "artifacts"])

    assert {:ok, [first]} = apply_record(context, normalized)
    assert Ids.valid_calendar_item_id?(first["calendar_item_id"])
    assert Ids.valid_scheduling_link_id?(first["scheduling_link_id"])
    assert first["revision"] == 1

    assert {:ok, [same]} = apply_record(context, normalized)
    assert same["calendar_item_id"] == first["calendar_item_id"]
    assert same["scheduling_link_id"] == first["scheduling_link_id"]
    assert same["revision"] == 1

    assert {:ok, %{"data" => [listed]}} =
             Server.list_items(context.group_id, context.calendar["calendar_id"])

    assert listed["calendar_item_id"] == first["calendar_item_id"]

    tombstone_projection =
      projection
      |> put_in(["schedule", "schedule_id"], nil)
      |> Map.put("next_fire_at", nil)
      |> Map.put("revision", 5)

    assert {:ok, tombstone} = SalixTaskSchedule.normalize(tombstone_projection)
    assert {:ok, [removed]} = apply_record(context, tombstone)
    assert removed["calendar_item_id"] == first["calendar_item_id"]
    assert removed["tombstoned_at"]

    assert {:ok, [same_removal]} = apply_record(context, tombstone)
    assert same_removal["revision"] == removed["revision"]
    assert same_removal["tombstoned_at"] == removed["tombstoned_at"]

    assert {:ok, restored_record} =
             projection
             |> Map.put("revision", 6)
             |> SalixTaskSchedule.normalize()

    assert {:ok, [restored]} = apply_record(context, restored_record)
    assert restored["calendar_item_id"] == first["calendar_item_id"]
    assert restored["scheduling_link_id"] == first["scheduling_link_id"]
    assert restored["tombstoned_at"] == nil
  end

  test "unsupported Task timing preserves an undated source item without blocking the page",
       context do
    projection = put_in(task_projection(), ["schedule_definition", "cron"], "0 10 1 * *")

    assert {:ok, normalized} = SalixTaskSchedule.normalize(projection)
    assert normalized["normalization_state"] == "unsupported_timing"
    refute Map.has_key?(normalized["object"], "due")
    refute Map.has_key?(normalized["object"], "recurrenceRules")

    assert {:ok, [item]} = apply_record(context, normalized)
    assert item["normalization_state"] == "unsupported_timing"
    assert get_in(item, ["object", "@type"]) == "Task"

    assert {:error, :occurrence_not_found} =
             Occurrences.get(
               context.group_id,
               context.calendar["calendar_id"],
               item["calendar_item_id"],
               %{
                 "calendar_id" => context.calendar["calendar_id"],
                 "scheduling_link_id" => item["scheduling_link_id"],
                 "recurrence_key" => %{"kind" => "single"}
               }
             )

    assert {:error, :occurrence_not_found} =
             Server.update_context(
               context.group_id,
               context.calendar["calendar_id"],
               %{
                 "calendar_id" => context.calendar["calendar_id"],
                 "scheduling_link_id" => item["scheduling_link_id"],
                 "recurrence_key" => %{"kind" => "single"}
               },
               %{"expected_revision" => 0, "objective" => "must not be accepted"}
             )
  end

  test "an item that becomes unsupported stops producing occurrences and retires its link",
       context do
    capture_retirements()
    identity = scheduling_identity("unsupported-transition@example.com")

    supported =
      event_record("unsupported-transition", identity, "organizer", "Supported", 1)

    assert {:ok, [first]} = apply_record(context, supported)

    unsupported =
      supported
      |> Map.put("normalization_state", "unsupported_timing")
      |> put_in(["scheduling_revision", "sequence"], 2)
      |> put_in(["source_version", "sequence"], 2)

    assert {:ok, [updated]} = apply_record(context, unsupported)
    assert updated["calendar_item_id"] == first["calendar_item_id"]

    assert {:ok, []} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )

    assert_receive {:retire_scheduling_link, _, _, link_id, nil}
    assert link_id == first["scheduling_link_id"]
  end

  test "occurrence context is independent of source refresh and uses revision CAS", context do
    assert {:ok, normalized} = SalixTaskSchedule.normalize(task_projection())
    assert {:ok, [item]} = apply_record(context, normalized)

    from = unix_ms(~D[2026-07-20], ~T[00:00:00])
    until = unix_ms(~D[2026-07-27], ~T[00:00:00])

    assert {:ok, [occurrence | _]} = Recurrence.expand(item, from, until)
    occurrence_ref = occurrence["occurrence_ref"]

    assert {:ok, first} =
             Server.update_context(
               context.group_id,
               context.calendar["calendar_id"],
               occurrence_ref,
               %{
                 expected_revision: 0,
                 objective: "Decide the rollout plan",
                 background: "Customer asked for staged delivery",
                 updated_by: "router"
               }
             )

    assert first["revision"] == 1

    assert {:error, :conflict} =
             Server.update_context(
               context.group_id,
               context.calendar["calendar_id"],
               occurrence_ref,
               %{expected_revision: 0, objective: "stale write"}
             )

    fabricated_ref =
      put_in(
        occurrence_ref,
        ["recurrence_key", "value"],
        "2026-07-21T08:01:00"
      )

    assert {:error, :occurrence_not_found} =
             Server.update_context(
               context.group_id,
               context.calendar["calendar_id"],
               fabricated_ref,
               %{expected_revision: 0, objective: "fabricated slot"}
             )

    noncanonical_ref = Map.put(occurrence_ref, "provider_event_id", "must-not-be-part-of-key")

    assert {:error, :invalid_occurrence_ref} =
             Server.update_context(
               context.group_id,
               context.calendar["calendar_id"],
               noncanonical_ref,
               %{expected_revision: 0, objective: "noncanonical key"}
             )

    assert {:ok, [same_item]} = apply_record(context, normalized)
    assert same_item["revision"] == item["revision"]

    assert {:ok, stored} =
             Server.get_context(
               context.group_id,
               context.calendar["calendar_id"],
               occurrence_ref
             )

    assert stored["objective"] == "Decide the rollout plan"

    assert {:ok, updated} =
             Server.update_context(
               context.group_id,
               context.calendar["calendar_id"],
               occurrence_ref,
               %{expected_revision: 1, questions: ["Who owns the rollout?"]}
             )

    assert updated["revision"] == 2
    assert updated["background"] == "Customer asked for staged delivery"
  end

  test "refreshing identical source facts updates freshness without changing fact revision",
       context do
    first_record =
      event_record(
        "freshness-only",
        scheduling_identity("freshness-only@example.com"),
        "organizer",
        "Freshness only",
        1
      )
      |> Map.put("source_fresh_at", 100)

    assert {:ok, [first]} = apply_record(context, first_record)

    assert {:ok, [refreshed]} =
             apply_record(context, Map.put(first_record, "source_fresh_at", 200))

    assert refreshed["revision"] == first["revision"]
    assert refreshed["source_fresh_at"] == 200

    assert {:ok, [changed]} =
             apply_record(
               context,
               first_record
               |> Map.put("source_fresh_at", 300)
               |> put_in(["object", "title"], "Changed facts")
               |> put_in(["scheduling_revision", "sequence"], 2)
               |> put_in(["source_version", "sequence"], 2)
             )

    assert changed["revision"] == first["revision"] + 1
  end

  test "agent API exposes bounded occurrences and context only, never source locators", context do
    assert {:ok, normalized} = SalixTaskSchedule.normalize(task_projection())
    assert {:ok, [item]} = apply_record(context, normalized)
    from = unix_ms(~D[2026-07-20], ~T[00:00:00])
    until = unix_ms(~D[2026-07-21], ~T[00:00:00])

    assert {:ok,
            %{
              "data" => [
                %{
                  "item" => listed_item,
                  "occurrence" => occurrence,
                  "calendar_context" => %{"revision" => 0}
                }
              ]
            }} =
             AgentAPI.list_items(context.group_id, %{
               "calendar_id" => context.calendar["calendar_id"],
               "range_start_ms" => from,
               "range_end_ms" => until,
               "object_type" => "task",
               "limit" => 10
             })

    assert listed_item["calendar_item_id"] == item["calendar_item_id"]

    for private <-
          ~w(origin source_version source_generation scheduling_identity scheduling_revision) do
      refute Map.has_key?(listed_item, private)
    end

    assert {:ok,
            %{
              "item" => public_item,
              "occurrence" => resolved,
              "calendar_context" => %{"revision" => 0}
            }} =
             AgentAPI.get_item(context.group_id, %{
               "calendar_id" => context.calendar["calendar_id"],
               "calendar_item_id" => item["calendar_item_id"],
               "occurrence_ref" => occurrence["occurrence_ref"]
             })

    for private <-
          ~w(origin source_version source_generation scheduling_identity scheduling_revision) do
      refute Map.has_key?(public_item, private)
    end

    assert resolved["occurrence_ref"] == occurrence["occurrence_ref"]

    assert {:ok, context_record} =
             AgentAPI.update_context(context.group_id, %{
               "calendar_id" => context.calendar["calendar_id"],
               "occurrence_ref" => occurrence["occurrence_ref"],
               "expected_revision" => 0,
               "background" => "Router supplied context",
               "actor" => %{"agent_id" => Ids.new_agent_id(context.group_id)}
             })

    assert context_record["revision"] == 1
    assert context_record["background"] == "Router supplied context"

    assert {:ok, %{"calendar_context" => ^context_record}} =
             AgentAPI.get_item(context.group_id, %{
               "calendar_id" => context.calendar["calendar_id"],
               "calendar_item_id" => item["calendar_item_id"],
               "occurrence_ref" => occurrence["occurrence_ref"]
             })
  end

  test "agent occurrence queries fail explicitly instead of truncating a recurrence", context do
    recurring =
      event_record(
        "bounded-agent-query",
        scheduling_identity("bounded-agent-query@example.com"),
        "organizer",
        "Bounded agent query",
        1
      )
      |> put_in(["object", "recurrenceRules"], [
        %{"@type" => "RecurrenceRule", "frequency" => "daily"}
      ])

    assert {:ok, [_item]} = apply_record(context, recurring)

    assert {:error, :occurrence_limit_exceeded} =
             AgentAPI.list_items(context.group_id, %{
               "calendar_id" => context.calendar["calendar_id"],
               "range_start_ms" => unix_ms(~D[2026-07-20], ~T[00:00:00]),
               "range_end_ms" => unix_ms(~D[2026-07-23], ~T[00:00:00]),
               "object_type" => "event",
               "limit" => 1
             })
  end

  test "exact scheduling identity correlates source copies and organizer facts win", context do
    source_two = ensure_source(context, "second")
    identity = scheduling_identity("series-1@example.com")

    attendee = event_record("source-copy-a", identity, "attendee", "Attendee copy", 1)
    organizer = event_record("source-copy-b", identity, "organizer", "Organizer copy", 2)

    assert {:ok, [attendee_item]} = apply_record(context, attendee)
    assert {:ok, [organizer_item]} = apply_record(context, source_two, organizer)
    assert organizer_item["scheduling_link_id"] == attendee_item["scheduling_link_id"]

    assert {:ok, [occurrence]} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )

    assert get_in(occurrence, ["item", "calendar_item_id"]) ==
             organizer_item["calendar_item_id"]

    assert get_in(occurrence, ["item", "object", "title"]) == "Organizer copy"

    assert {:ok, [attendee_only]} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00]),
               source_ids: [context.source["source_id"]]
             )

    assert get_in(attendee_only, ["item", "calendar_item_id"]) ==
             attendee_item["calendar_item_id"]

    assert {:ok, [organizer_only]} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00]),
               source_ids: [source_two["source_id"]]
             )

    assert get_in(organizer_only, ["item", "calendar_item_id"]) ==
             organizer_item["calendar_item_id"]

    occurrence_ref = get_in(occurrence, ["occurrence", "occurrence_ref"])

    assert {:error, :occurrence_copy_changed} =
             Occurrences.get(
               context.group_id,
               context.calendar["calendar_id"],
               attendee_item["calendar_item_id"],
               occurrence_ref
             )

    assert {:ok, attendee_selected} =
             Occurrences.get(
               context.group_id,
               context.calendar["calendar_id"],
               attendee_item["calendar_item_id"],
               occurrence_ref,
               source_ids: [context.source["source_id"]]
             )

    assert get_in(attendee_selected, ["item", "calendar_item_id"]) ==
             attendee_item["calendar_item_id"]

    assert {:error, :occurrence_copy_changed} =
             AgentAPI.get_item(context.group_id, %{
               "calendar_id" => context.calendar["calendar_id"],
               "calendar_item_id" => attendee_item["calendar_item_id"],
               "occurrence_ref" => occurrence_ref
             })

    assert {:ok, selected} =
             Occurrences.get(
               context.group_id,
               context.calendar["calendar_id"],
               organizer_item["calendar_item_id"],
               occurrence_ref
             )

    assert get_in(selected, ["item", "calendar_item_id"]) == organizer_item["calendar_item_id"]
  end

  test "similar presentation fields never correlate different scheduling identities", context do
    source_two = ensure_source(context, "second")

    first =
      event_record(
        "source-copy-a",
        scheduling_identity("series-a@example.com"),
        "organizer",
        "Same title",
        1
      )

    second =
      event_record(
        "source-copy-b",
        scheduling_identity("series-b@example.com"),
        "organizer",
        "Same title",
        1
      )

    assert {:ok, [first_item]} = apply_record(context, first)
    assert {:ok, [second_item]} = apply_record(context, source_two, second)
    refute first_item["scheduling_link_id"] == second_item["scheduling_link_id"]

    assert {:ok, occurrences} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )

    assert length(occurrences) == 2
  end

  test "an exact source copy can move to a new scheduling identity without stalling sync",
       context do
    capture_retirements()

    original =
      event_record(
        "rewritten-identity",
        scheduling_identity("old-series@example.com"),
        "organizer",
        "Before identity rewrite",
        1
      )

    assert {:ok, [before]} = apply_record(context, original)

    rewritten =
      event_record(
        "rewritten-identity",
        scheduling_identity("new-series@example.com"),
        "organizer",
        "After identity rewrite",
        2
      )

    assert {:ok, [after_rewrite]} = apply_record(context, rewritten)
    assert after_rewrite["calendar_item_id"] == before["calendar_item_id"]
    refute after_rewrite["scheduling_link_id"] == before["scheduling_link_id"]

    assert {:ok, [occurrence]} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )

    assert get_in(occurrence, ["item", "object", "title"]) == "After identity rewrite"

    assert get_in(occurrence, ["occurrence", "occurrence_ref", "scheduling_link_id"]) ==
             after_rewrite["scheduling_link_id"]

    assert_receive {:retire_scheduling_link, _, _, retired_link, nil}
    assert retired_link == before["scheduling_link_id"]
  end

  test "time-index candidates load every SchedulingLink copy before organizer selection",
       context do
    source_two = ensure_source(context, "organizer-copy")
    identity = scheduling_identity("moved-organizer@example.com")

    attendee = event_record("attendee-copy", identity, "attendee", "Stale attendee", 1)

    organizer =
      event_record("organizer-copy", identity, "organizer", "Moved organizer", 2)
      |> put_in(["object", "start"], "2026-08-20T10:00:00")

    assert {:ok, [_attendee]} = apply_record(context, attendee)
    assert {:ok, [_organizer]} = apply_record(context, source_two, organizer)

    assert {:ok, []} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )

    assert {:ok, [occurrence]} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-08-20], ~T[00:00:00]),
               unix_ms(~D[2026-08-21], ~T[00:00:00])
             )

    assert get_in(occurrence, ["item", "object", "title"]) == "Moved organizer"
  end

  test "equal organizer revisions with conflicting shared facts fail closed", context do
    source_two = ensure_source(context, "second")
    identity = scheduling_identity("series-ambiguous@example.com")

    first = event_record("source-copy-a", identity, "organizer", "First facts", 1)
    second = event_record("source-copy-b", identity, "organizer", "Conflicting facts", 1)

    assert {:ok, [_first_item]} = apply_record(context, first)
    assert {:ok, [_second_item]} = apply_record(context, source_two, second)

    assert {:error, {:ambiguous_scheduling_link, _link_id}} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )
  end

  test "multiple observations with incomparable revisions fail closed", context do
    source_two = ensure_source(context, "second-observer")
    identity = scheduling_identity("series-incomparable@example.com")

    first =
      event_record("source-copy-a", identity, "attendee", "First observation", 1)
      |> Map.delete("scheduling_revision")

    second =
      event_record("source-copy-b", identity, "attendee", "Second observation", 1)
      |> Map.delete("scheduling_revision")

    assert {:ok, [_first_item]} = apply_record(context, first)
    assert {:ok, [_second_item]} = apply_record(context, source_two, second)

    assert {:error, {:ambiguous_scheduling_link, _link_id}} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )
  end

  test "retiring one source copy keeps a SchedulingLink live while another copy remains",
       context do
    capture_retirements()
    source_two = ensure_source(context, "surviving-copy")
    identity = scheduling_identity("multi-copy@example.com")
    first = event_record("copy-a", identity, "attendee", "First copy", 1)
    second = event_record("copy-b", identity, "organizer", "Organizer copy", 2)

    assert {:ok, [first_item]} = apply_record(context, first)
    assert {:ok, [second_item]} = apply_record(context, source_two, second)
    link_id = first_item["scheduling_link_id"]
    assert second_item["scheduling_link_id"] == link_id

    assert {:ok, [_first_removed]} =
             apply_record(context, %{
               "external_locator" => first["external_locator"],
               "tombstone" => true,
               "source_revision" => [2, 0]
             })

    refute_receive {:retire_scheduling_link, _, _, ^link_id, _}, 50

    assert {:ok, [remaining]} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )

    assert get_in(remaining, ["item", "calendar_item_id"]) ==
             second_item["calendar_item_id"]

    assert {:ok, [_second_removed]} =
             apply_record(context, source_two, %{
               "external_locator" => second["external_locator"],
               "tombstone" => true,
               "source_revision" => [3, 0]
             })

    assert_receive {:retire_scheduling_link, _, _, ^link_id, nil}
  end

  test "link retirement is bounded by candidate members rather than total calendar size",
       context do
    capture_retirements({:ok, "opaque:next-meeting-plan-page"})

    target =
      event_record(
        "retirement-target",
        scheduling_identity("retirement-target@example.com"),
        "organizer",
        "Retirement target",
        1
      )

    assert {:ok, [target_item]} = apply_record(context, target)

    unrelated =
      Enum.map(1..200, fn index ->
        event_record(
          "unrelated-#{index}",
          scheduling_identity("unrelated-#{index}@example.com"),
          "organizer",
          "Unrelated #{index}",
          1
        )
      end)

    assert {:ok, unrelated_items} = apply_records(context, context.source, unrelated)

    assert length(unrelated_items) == 200

    link_id = target_item["scheduling_link_id"]

    assert {:ok, replacement_items} =
             apply_records(
               context,
               context.source,
               unrelated,
               %{"fixture_source_id" => context.source["source_id"], "coverage" => "replacement"}
             )

    assert length(replacement_items) == 200

    assert_receive {:retire_scheduling_link, _, _, ^link_id, nil}

    Application.put_env(:salix_calendar, :retirement_test_result, {:ok, nil})

    assert :ok =
             Server.drain_source_retirements(
               context.group_id,
               context.calendar["calendar_id"],
               context.source["source_id"]
             )

    assert_receive {:retire_scheduling_link, _, _, ^link_id, "opaque:next-meeting-plan-page"}
    refute_receive {:retire_scheduling_link, _, _, ^link_id, _}, 50
  end

  test "source-scoped retirement survives a crash across replacement generations", context do
    capture_retirements({:ok, "resume-after-crash"})

    removed =
      event_record(
        "retirement-crash",
        scheduling_identity("retirement-crash@example.com"),
        "organizer",
        "Retirement crash",
        1
      )

    assert {:ok, [removed_item]} = apply_record(context, removed)

    assert {:ok, []} =
             apply_records(
               context,
               context.source,
               [],
               %{"fixture_source_id" => context.source["source_id"], "coverage" => "empty"}
             )

    link_id = removed_item["scheduling_link_id"]
    assert_receive {:retire_scheduling_link, _, _, ^link_id, nil}

    Application.put_env(:salix_calendar, :retirement_test_result, {:ok, nil})

    assert :ok =
             Server.drain_source_retirements(
               context.group_id,
               context.calendar["calendar_id"],
               context.source["source_id"]
             )

    assert_receive {:retire_scheduling_link, _, _, ^link_id, "resume-after-crash"}
  end

  test "occurrence queries use the time index instead of scanning a large item collection",
       context do
    recurring =
      event_record(
        "old-recurring-master",
        scheduling_identity("old-recurring-master@example.com"),
        "organizer",
        "Old recurring master",
        1
      )
      |> put_in(["object", "start"], "2020-01-06T10:00:00")
      |> put_in(["object", "recurrenceRules"], [
        %{"@type" => "RecurrenceRule", "frequency" => "weekly"}
      ])

    assert {:ok, [_recurring]} = apply_record(context, recurring)

    history =
      Enum.map(1..200, fn index ->
        event_record(
          "historical-#{index}",
          scheduling_identity("historical-#{index}@example.com"),
          "organizer",
          "Historical #{index}",
          1
        )
        |> put_in(["object", "start"], "2020-02-03T10:00:00")
      end)

    assert {:ok, imported} = apply_records(context, context.source, history)

    assert length(imported) == 200

    assert {:ok, [occurrence]} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )

    assert get_in(occurrence, ["item", "object", "title"]) == "Old recurring master"
  end

  test "source audience cannot escape its owning group", context do
    other_tenant = Ids.new_tenant_id()
    other_group = Ids.new_group_id(other_tenant)

    assert {:error, :calendar_source_audience_mismatch} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "salix_task_schedule",
               adapter_contract_id: SalixTaskSchedule.adapter_contract_id(),
               source_locator: %{kind: "test", name: "wrong-audience"},
               access_profile: "scheduled_tasks_read",
               audience: %{kind: "group", group_id: other_group}
             })
  end

  test "a non-recurring item keeps its occurrence ref when its start changes", context do
    identity = scheduling_identity("single-event@example.com")
    original = event_record("single", identity, "organizer", "One-off", 1)
    assert {:ok, [first_item]} = apply_record(context, original)

    assert {:ok, [first_occurrence]} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )

    occurrence_ref = get_in(first_occurrence, ["occurrence", "occurrence_ref"])
    assert occurrence_ref["recurrence_key"] == %{"kind" => "single"}

    changed =
      original
      |> put_in(["object", "start"], "2026-08-20T15:00:00")
      |> put_in(["scheduling_revision", "sequence"], 2)
      |> put_in(["scheduling_revision", "shared_fact_hash"], "facts-2")
      |> put_in(["source_version", "sequence"], 2)

    assert {:ok, [changed_item]} = apply_record(context, changed)
    assert changed_item["calendar_item_id"] == first_item["calendar_item_id"]

    assert {:ok, resolved} =
             Occurrences.get(
               context.group_id,
               context.calendar["calendar_id"],
               changed_item["calendar_item_id"],
               occurrence_ref
             )

    assert get_in(resolved, ["occurrence", "occurrence_ref"]) == occurrence_ref
    assert get_in(resolved, ["occurrence", "effective", "start"]) == "2026-08-20T15:00:00"

    assert {:ok, []} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )

    assert {:ok, [_moved]} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-08-20], ~T[00:00:00]),
               unix_ms(~D[2026-08-21], ~T[00:00:00])
             )
  end

  test "replacement activation resumes bounded retirement pages without rereading provider data",
       context do
    capture_retirements()

    on_exit(fn ->
      Application.delete_env(:salix_calendar, :counting_activation_calls)
      Application.delete_env(:salix_calendar, :counting_activation_changes)
    end)

    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "counting_activation_test",
               adapter_contract_id: CountingActivationAdapter.adapter_contract_id(),
               source_locator: %{kind: "test", name: "counting-activation"},
               access_profile: "events_read"
             })

    records =
      Enum.map(1..201, fn index ->
        event_record(
          "activation-#{index}",
          scheduling_identity("activation-#{index}@example.com"),
          "organizer",
          "Activation #{index}",
          1
        )
      end)

    Application.put_env(:salix_calendar, :counting_activation_changes, records)
    Application.put_env(:salix_calendar, :counting_activation_calls, 0)
    initial_query = %{"group_id" => context.group_id, "object_type" => "Event"}

    assert {:ok, %{"sync_status" => "active", "applied" => applied}} =
             refresh_source(
               context.group_id,
               context.calendar["calendar_id"],
               source,
               CountingActivationAdapter,
               initial_query
             )

    assert length(applied) == 201
    assert Application.fetch_env!(:salix_calendar, :counting_activation_calls) == 2

    Application.put_env(:salix_calendar, :counting_activation_changes, [])
    Application.put_env(:salix_calendar, :counting_activation_calls, 0)

    assert {:ok, %{"sync_status" => "active"}} =
             refresh_source(
               context.group_id,
               context.calendar["calendar_id"],
               source,
               CountingActivationAdapter,
               Map.put(initial_query, "coverage", "empty")
             )

    assert Application.fetch_env!(:salix_calendar, :counting_activation_calls) == 1

    retirements =
      Enum.map(1..201, fn _ ->
        assert_receive {:retire_scheduling_link, _, _, link_id, nil}
        link_id
      end)

    assert length(Enum.uniq(retirements)) == 201
  end

  test "cursor expiry stages a replacement generation and atomically switches visibility",
       context do
    on_exit(fn -> Application.delete_env(:salix_calendar, :expiring_adapter_mode) end)

    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "expiring_test",
               adapter_contract_id: ExpiringAdapter.adapter_contract_id(),
               source_locator: %{kind: "test", name: "expiring"},
               access_profile: "events_read"
             })

    query = %{"group_id" => context.group_id, "object_type" => "Event"}

    assert {:ok, initial} =
             refresh_source(
               context.group_id,
               context.calendar["calendar_id"],
               source,
               ExpiringAdapter,
               query
             )

    assert initial["sync"]["generation"] == 1
    assert initial["sync"]["status"] == "active"

    assert {:ok, before} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )

    assert Enum.map(before, &get_in(&1, ["item", "object", "title"])) |> Enum.sort() ==
             ["Before rebuild", "Removed"]

    kept = Enum.find(before, &(get_in(&1, ["item", "object", "title"]) == "Before rebuild"))
    occurrence_ref = get_in(kept, ["occurrence", "occurrence_ref"])

    assert {:ok, context_record} =
             Server.update_context(
               context.group_id,
               context.calendar["calendar_id"],
               occurrence_ref,
               %{expected_revision: 0, background: "Must survive rebuild"}
             )

    assert context_record["revision"] == 1
    Application.put_env(:salix_calendar, :expiring_adapter_mode, :rebuild)

    assert {:ok, completed} =
             refresh_source(
               context.group_id,
               context.calendar["calendar_id"],
               source,
               ExpiringAdapter,
               query
             )

    assert completed["sync"]["generation"] == 2
    assert completed["sync"]["status"] == "active"

    assert {:ok, [after_rebuild]} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )

    assert get_in(after_rebuild, ["item", "object", "title"]) == "After rebuild"
    assert get_in(after_rebuild, ["occurrence", "occurrence_ref"]) == occurrence_ref

    assert {:ok, stored_context} =
             Server.get_context(
               context.group_id,
               context.calendar["calendar_id"],
               occurrence_ref
             )

    assert stored_context["background"] == "Must survive rebuild"
  end

  test "cursor expiry accepts an unchanged versioned event and imports a new meeting", context do
    on_exit(fn -> Application.delete_env(:salix_calendar, :expiring_adapter_mode) end)

    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "expiring_test",
               adapter_contract_id: ExpiringAdapter.adapter_contract_id(),
               source_locator: %{kind: "test", name: "unchanged-after-expiry"},
               access_profile: "events_read"
             })

    query = %{"group_id" => context.group_id, "object_type" => "Event"}

    assert {:ok, _initial} =
             Server.refresh_source(
               context.group_id,
               context.calendar["calendar_id"],
               source["source_id"],
               query
             )

    assert {:ok, before} = occurrences_on(context, ~D[2026-07-20])
    kept = Enum.find(before, &(get_in(&1, ["item", "object", "title"]) == "Before rebuild"))
    occurrence_ref = kept["occurrence"]["occurrence_ref"]

    assert {:ok, _context} =
             Server.update_context(
               context.group_id,
               context.calendar["calendar_id"],
               occurrence_ref,
               %{expected_revision: 0, background: "Preserve preparation notes"}
             )

    Application.put_env(:salix_calendar, :expiring_adapter_mode, :unchanged)

    assert {:ok, completed} =
             Server.refresh_source(
               context.group_id,
               context.calendar["calendar_id"],
               source["source_id"],
               query
             )

    assert completed["sync"]["generation"] == 2
    assert completed["sync"]["status"] == "active"
    assert visible_titles(context) == ["Before rebuild", "New meeting"]
    assert {:ok, after_rebuild} = occurrences_on(context, ~D[2026-07-20])

    unchanged =
      Enum.find(after_rebuild, &(get_in(&1, ["item", "object", "title"]) == "Before rebuild"))

    assert unchanged["item"]["calendar_item_id"] == kept["item"]["calendar_item_id"]
    assert unchanged["item"]["revision"] == kept["item"]["revision"]
    assert unchanged["occurrence"]["occurrence_ref"] == occurrence_ref

    assert {:ok, saved} =
             Server.get_context(context.group_id, context.calendar["calendar_id"], occurrence_ref)

    assert saved["background"] == "Preserve preparation notes"
  end

  test "a replacement still rejects different source facts at the same provider revision",
       context do
    record =
      event_record(
        "equal-rank-conflict",
        scheduling_identity("equal-rank@example.com"),
        "organizer",
        "Original meeting",
        1
      )
      |> Map.put("source_revision", [1])

    assert {:ok, [original]} = apply_record(context, record)
    conflict = put_in(record, ["object", "title"], "Conflicting meeting")

    assert {:error, %{reason: :source_revision_conflict, applied: []}} =
             apply_records(context, context.source, [conflict], %{
               "fixture_source_id" => context.source["source_id"],
               "coverage" => "replacement"
             })

    assert {:ok, visible} =
             Server.get_item(
               context.group_id,
               context.calendar["calendar_id"],
               original["calendar_item_id"]
             )

    assert visible["object"]["title"] == "Original meeting"
    assert visible["source_revision"] == [1]
  end

  test "a changed sync query contract stages above the active generation before replacing visibility",
       context do
    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "contract_change_test",
               adapter_contract_id: ContractChangeAdapter.adapter_contract_id(),
               source_locator: %{kind: "test", name: "changed-query-contract"},
               access_profile: "events_read"
             })

    initial_query = %{"object_type" => "Event", "coverage" => "initial"}

    assert {:ok, %{"sync" => %{"status" => "active"}}} =
             refresh_source(
               context.group_id,
               context.calendar["calendar_id"],
               source,
               ContractChangeAdapter,
               initial_query
             )

    assert {:ok, [initial]} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )

    assert get_in(initial, ["item", "object", "title"]) == "Existing"

    changed_query = Map.put(initial_query, "coverage", "expanded")

    assert {:ok, _expanded_sync} =
             refresh_source(
               context.group_id,
               context.calendar["calendar_id"],
               source,
               ContractChangeAdapter,
               changed_query
             )

    assert {:ok, expanded} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )

    assert Enum.map(expanded, &get_in(&1, ["item", "object", "title"])) |> Enum.sort() ==
             ["Existing", "Newly covered"]
  end

  test "a policy change during bootstrap cannot mix two sync contracts into one generation",
       context do
    previous_test_pid = Application.get_env(:salix_calendar, :racing_sync_test_pid)
    Application.put_env(:salix_calendar, :racing_sync_test_pid, self())
    on_exit(fn -> restore_env(:racing_sync_test_pid, previous_test_pid) end)

    source_attrs = %{
      adapter: "racing_sync_test",
      adapter_contract_id: RacingSyncAdapter.adapter_contract_id(),
      source_locator: %{kind: "test", name: "bootstrap-policy-change"},
      access_profile: "events_read",
      sync_policy: %{"coverage" => "initial"}
    }

    assert {:ok, source} =
             Server.ensure_source(
               context.group_id,
               context.calendar["calendar_id"],
               source_attrs
             )

    stale_task =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          %{"object_type" => "Event", "coverage" => "staged-a"}
        )
      end)

    assert_receive {:racing_sync_read, stale_reader, stale_ref, nil}

    assert {:ok, latest_source} =
             Server.ensure_source(
               context.group_id,
               context.calendar["calendar_id"],
               put_in(source_attrs, [:sync_policy, "coverage"], "latest-b")
             )

    send(stale_reader, {
      :racing_sync_page,
      stale_ref,
      %{
        "changes" => [
          event_record(
            "policy-fence",
            scheduling_identity("policy-fence@example.com"),
            "organizer",
            "Stale contract A",
            1
          )
        ],
        "next_continuation" => nil,
        "completed_cursor" => "stale-a"
      }
    })

    assert {:error, :calendar_source_contract_mismatch} = Task.await(stale_task)

    latest_task =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          latest_source,
          RacingSyncAdapter,
          %{"object_type" => "Event", "coverage" => "latest-b"}
        )
      end)

    assert_receive {:racing_sync_read, latest_reader, latest_ref, nil}

    send(latest_reader, {
      :racing_sync_page,
      latest_ref,
      %{
        "changes" => [
          event_record(
            "policy-fence",
            scheduling_identity("policy-fence@example.com"),
            "organizer",
            "Latest contract B",
            2
          )
        ],
        "next_continuation" => nil,
        "completed_cursor" => "latest-b"
      }
    })

    assert {:ok, _latest} = Task.await(latest_task)

    assert {:ok, visible} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )

    assert Enum.map(visible, &get_in(&1, ["item", "object", "title"])) ==
             ["Latest contract B"]
  end

  test "an older staging track cannot publish after a newer source policy starts staging",
       context do
    previous_test_pid = Application.get_env(:salix_calendar, :racing_sync_test_pid)
    Application.put_env(:salix_calendar, :racing_sync_test_pid, self())
    on_exit(fn -> restore_env(:racing_sync_test_pid, previous_test_pid) end)

    source_attrs = %{
      adapter: "racing_sync_test",
      adapter_contract_id: RacingSyncAdapter.adapter_contract_id(),
      source_locator: %{kind: "test", name: "overlapping-staging-policy-change"},
      access_profile: "events_read",
      sync_policy: %{"coverage" => "shared-initial"}
    }

    assert {:ok, source} =
             Server.ensure_source(
               context.group_id,
               context.calendar["calendar_id"],
               source_attrs
             )

    initial_task =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          %{"object_type" => "Event", "coverage" => "shared-initial"}
        )
      end)

    assert_receive {:racing_sync_read, initial_reader, initial_ref, nil}

    send(initial_reader, {
      :racing_sync_page,
      initial_ref,
      %{
        "changes" => [
          event_record(
            "shared-policy",
            scheduling_identity("shared-policy@example.com"),
            "organizer",
            "Existing shared fact",
            1
          )
        ],
        "next_continuation" => nil,
        "completed_cursor" => "shared-initial"
      }
    })

    assert {:ok, _initial} = Task.await(initial_task)

    assert visible_titles(context) == ["Existing shared fact"]

    assert {:ok, latest_b_source} =
             Server.ensure_source(
               context.group_id,
               context.calendar["calendar_id"],
               put_in(source_attrs, [:sync_policy, "coverage"], "shared-latest-b")
             )

    latest_task =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          latest_b_source,
          RacingSyncAdapter,
          %{"object_type" => "Event", "coverage" => "shared-latest-b"}
        )
      end)

    assert_receive {:racing_sync_read, latest_reader, latest_ref, nil}

    assert visible_titles(context) == ["Existing shared fact"]

    send(latest_reader, {
      :racing_sync_page,
      latest_ref,
      %{
        "changes" => [
          event_record(
            "shared-policy",
            scheduling_identity("shared-policy@example.com"),
            "organizer",
            "Latest staged contract B",
            3
          )
        ],
        "next_continuation" => nil,
        "completed_cursor" => "shared-latest-b"
      }
    })

    assert {:ok, _latest} = Task.await(latest_task)

    assert visible_titles(context) == ["Latest staged contract B"]
  end

  test "the generic source lease supports stale takeover and fences the old owner", context do
    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "contract_change_test",
               adapter_contract_id: ContractChangeAdapter.adapter_contract_id(),
               source_locator: %{kind: "test", name: "lease-takeover"},
               access_profile: "events_read"
             })

    now = System.system_time(:millisecond)
    lease_ms = 5_000

    lease_key = "test/lease/#{context.group_id}/#{source["source_id"]}"

    assert {:ok, old_holder} =
             Lease.acquire(lease_key, "old-holder", now: now, ttl_ms: lease_ms)

    assert {:error, {:held_by, "old-holder", _until}} =
             Lease.acquire(
               lease_key,
               "early-contender",
               now: now + lease_ms - 1,
               ttl_ms: lease_ms
             )

    assert {:ok, new_holder} =
             Lease.acquire(
               lease_key,
               "takeover-holder",
               now: now + lease_ms,
               ttl_ms: lease_ms
             )

    assert new_holder.epoch == old_holder.epoch + 1
    assert {:error, :lost} = Lease.renew(old_holder, now: now + lease_ms)
    assert :ok = Lease.release(old_holder)
    assert {:ok, renewed} = Lease.renew(new_holder, now: now + lease_ms)
    assert :ok = Lease.release(renewed)
  end

  test "a source refresh keeps its lease while a retirement commit is still in flight", context do
    previous_renewal = Application.get_env(:salix_calendar, :source_lease_renew_interval_ms)
    Application.put_env(:salix_calendar, :source_lease_renew_interval_ms, 20)
    Application.put_env(:salix_calendar, :retirement_sink, BlockingRetirementSink)
    Application.put_env(:salix_calendar, :retirement_test_pid, self())

    on_exit(fn ->
      restore_env(:source_lease_renew_interval_ms, previous_renewal)
    end)

    identity = scheduling_identity("long-retirement-commit@example.com")

    supported =
      event_record("long-retirement-commit", identity, "organizer", "Supported", 1)

    assert {:ok, [_first]} = apply_record(context, supported)

    unsupported =
      supported
      |> Map.put("normalization_state", "unsupported_timing")
      |> put_in(["scheduling_revision", "sequence"], 2)
      |> put_in(["source_version", "sequence"], 2)

    refresh_task = Task.async(fn -> apply_record(context, unsupported) end)

    assert_receive {:blocking_retirement_entered, sink, sink_ref, _, _, _, nil}, 2_000

    lease_key =
      Keys.ctl_calendar_source_lease(
        context.group_id,
        context.calendar["calendar_id"],
        context.source["source_id"]
      )

    assert {:ok, %{body: lease_body}} = S3.get(lease_key)
    lease_until = Jason.decode!(lease_body)["lease_until"]

    retirements_prefix =
      Keys.ctl_calendar_retirements_source_prefix(
        context.group_id,
        context.calendar["calendar_id"],
        context.source["source_id"]
      )

    assert {:ok, %{objects: [_candidate]}} = S3.list(retirements_prefix)

    Process.sleep(100)

    takeover_result =
      Lease.acquire(
        lease_key,
        "long-commit-contender",
        now: lease_until,
        ttl_ms: 300_000
      )

    send(sink, {:continue_retirement, sink_ref})
    refresh_result = Task.await(refresh_task, 5_000)

    case takeover_result do
      {:ok, contender_lease} -> Lease.release(contender_lease)
      {:error, _reason} -> :ok
    end

    assert {:ok, [_updated]} = refresh_result
    assert {:ok, %{objects: []}} = S3.list(retirements_prefix)

    assert {:error, {:held_by, _holder, renewed_until}} = takeover_result
    assert renewed_until > lease_until
  end

  test "source lease assertions are coalesced within one renewal interval", context do
    lease_key =
      Keys.ctl_calendar_source_lease(
        context.group_id,
        context.calendar["calendar_id"],
        context.source["source_id"]
      )

    records =
      Enum.map(1..25, fn index ->
        event_record(
          "coalesced-lease-#{index}",
          scheduling_identity("coalesced-lease-#{index}@example.com"),
          "organizer",
          "Coalesced lease #{index}",
          1
        )
      end)

    :ok = S3.Fake.reset_put_log()
    assert {:ok, imported} = apply_records(context, context.source, records)
    assert length(imported) == 25

    assert S3.Fake.put_log() |> Enum.count(&(&1 == lease_key)) == 1
  end

  test "one source page composes recurrence exceptions into one CalendarItem mutation", context do
    locator = %{"event_id" => "coalesced-recurrence-series"}

    master =
      event_record(
        locator["event_id"],
        scheduling_identity("coalesced-recurrence-series@example.com"),
        "organizer",
        "Coalesced recurrence series",
        1
      )
      |> put_in(["object", "recurrenceRules"], [
        %{"frequency" => "weekly", "interval" => 1, "byDay" => [%{"day" => "mo"}]}
      ])

    first_patch =
      recurrence_patch(locator, "2026-07-27T10:00:00", "2026-07-27T11:00:00", 0, [2])

    second_patch =
      recurrence_patch(locator, "2026-08-03T10:00:00", "2026-08-03T12:00:00", 1, [3])

    independent =
      event_record(
        "coalesced-independent",
        scheduling_identity("coalesced-independent@example.com"),
        "organizer",
        "Independent event",
        1
      )

    :ok = S3.Fake.reset_put_log()

    assert {:ok, [first, other, second, imported_master]} =
             apply_records(
               context,
               context.source,
               [first_patch, independent, second_patch, master]
             )

    assert first["status"] == "deferred"
    assert second["status"] == "deferred"
    assert other["calendar_item_id"] != first["calendar_item_id"]
    assert imported_master["calendar_item_id"] == first["calendar_item_id"]
    assert second["calendar_item_id"] == first["calendar_item_id"]

    item_key =
      Keys.ctl_calendar_item(
        context.group_id,
        context.calendar["calendar_id"],
        first["calendar_item_id"]
      )

    assert S3.Fake.put_log() |> Enum.count(&(&1 == item_key)) == 1
    assert occurrence_start(context, ~D[2026-07-27]) == "2026-07-27T11:00:00"
    assert occurrence_start(context, ~D[2026-08-03]) == "2026-08-03T12:00:00"
  end

  test "a stolen source lease fences the old refresh before it can mutate", context do
    previous_test_pid = Application.get_env(:salix_calendar, :racing_sync_test_pid)
    Application.put_env(:salix_calendar, :racing_sync_test_pid, self())
    on_exit(fn -> restore_env(:racing_sync_test_pid, previous_test_pid) end)

    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "racing_sync_test",
               adapter_contract_id: RacingSyncAdapter.adapter_contract_id(),
               source_locator: %{kind: "test", name: "lease-stolen-during-provider-io"},
               access_profile: "events_read"
             })

    refresh_task =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          %{"object_type" => "Event", "coverage" => "initial"}
        )
      end)

    assert_receive {:racing_sync_read, stale_reader, stale_ref, nil}

    lease_key =
      Keys.ctl_calendar_source_lease(
        context.group_id,
        context.calendar["calendar_id"],
        source["source_id"]
      )

    assert {:ok, %{body: lease_body}} = S3.get(lease_key)
    lease_until = Jason.decode!(lease_body)["lease_until"]

    assert {:ok, contender} =
             Lease.acquire(
               lease_key,
               "source-refresh-contender",
               now: lease_until,
               ttl_ms: 300_000
             )

    on_exit(fn -> Lease.release(contender) end)

    send(stale_reader, {
      :racing_sync_page,
      stale_ref,
      %{
        "changes" => [
          event_record(
            "stolen-source-lease",
            scheduling_identity("stolen-source-lease@example.com"),
            "organizer",
            "Must never import",
            1
          )
        ],
        "next_continuation" => nil,
        "completed_cursor" => "stale-owner-cursor"
      }
    })

    assert {:error, %{reason: {:source_lease_failed, :lost}, applied: []}} =
             Task.await(refresh_task)

    assert {:ok,
            %{
              "active_generation" => 0,
              "sync" => %{"completed_cursor" => nil, "status" => "bootstrap"}
            }} =
             Server.get_source(
               context.group_id,
               context.calendar["calendar_id"],
               source["source_id"]
             )

    assert {:ok, %{objects: []}} =
             S3.list(
               Keys.ctl_calendar_items_prefix(context.group_id, context.calendar["calendar_id"])
             )

    assert visible_titles(context) == []
  end

  test "a refresh rejected before provider I/O releases the source lease", context do
    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "unconfigured_test",
               adapter_contract_id: "test.unconfigured.v1",
               source_locator: %{kind: "test", name: "unconfigured"},
               access_profile: "events_read"
             })

    assert {:error, :calendar_source_adapter_not_configured} =
             Server.refresh_source(
               context.group_id,
               context.calendar["calendar_id"],
               source["source_id"],
               %{"object_type" => "Event"}
             )

    lease_key =
      Keys.ctl_calendar_source_lease(
        context.group_id,
        context.calendar["calendar_id"],
        source["source_id"]
      )

    assert {:ok, lease} = Lease.acquire(lease_key, "post-error-probe")
    assert :ok = Lease.release(lease)
  end

  test "the source owner keeps concurrent callers out of the adapter and advances one cursor",
       context do
    previous_test_pid = Application.get_env(:salix_calendar, :racing_sync_test_pid)
    Application.put_env(:salix_calendar, :racing_sync_test_pid, self())

    on_exit(fn ->
      if previous_test_pid,
        do: Application.put_env(:salix_calendar, :racing_sync_test_pid, previous_test_pid),
        else: Application.delete_env(:salix_calendar, :racing_sync_test_pid)
    end)

    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "racing_sync_test",
               adapter_contract_id: RacingSyncAdapter.adapter_contract_id(),
               source_locator: %{kind: "test", name: "racing-sync"},
               access_profile: "events_read"
             })

    query = %{"object_type" => "Event"}

    page = fn record, completed_cursor ->
      %{
        "changes" => [record],
        "next_continuation" => nil,
        "completed_cursor" => completed_cursor
      }
    end

    initial_task =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          query
        )
      end)

    assert_receive {:racing_sync_read, initial_reader, initial_ref, nil}

    send(
      initial_reader,
      {:racing_sync_page, initial_ref,
       page.(
         event_record(
           "racing-event",
           scheduling_identity("racing-event@example.com"),
           "organizer",
           "Initial provider fact",
           1
         ),
         "cursor-1"
       )}
    )

    assert {:ok, _initial} = Task.await(initial_task)

    holder_task =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          query
        )
      end)

    assert_receive {:racing_sync_read, holder_reader, holder_ref, "cursor-1"}

    queued_task =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          query
        )
      end)

    refute_receive {:racing_sync_read, _reader, _ref, _cursor}, 100

    send(
      holder_reader,
      {:racing_sync_page, holder_ref,
       page.(
         event_record(
           "racing-event",
           scheduling_identity("racing-event@example.com"),
           "organizer",
           "Holder provider fact",
           2
         ),
         "cursor-2"
       )}
    )

    assert {:ok, _holder} = Task.await(holder_task)

    assert_receive {:racing_sync_read, queued_reader, queued_ref, "cursor-2"}

    send(
      queued_reader,
      {:racing_sync_page, queued_ref,
       page.(
         event_record(
           "racing-event",
           scheduling_identity("racing-event@example.com"),
           "organizer",
           "Newest provider fact",
           3
         ),
         "cursor-3"
       )}
    )

    assert {:ok, _queued} = Task.await(queued_task)

    assert {:ok, [visible]} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )

    assert get_in(visible, ["item", "object", "title"]) == "Newest provider fact"
  end

  test "a timed-out source operation releases ownership for the next sync", context do
    previous_test_pid = Application.get_env(:salix_calendar, :racing_sync_test_pid)
    previous_timeout = Application.get_env(:salix_calendar, :source_operation_timeout_ms)
    Application.put_env(:salix_calendar, :racing_sync_test_pid, self())
    Application.put_env(:salix_calendar, :source_operation_timeout_ms, 20)

    on_exit(fn ->
      restore_env(:racing_sync_test_pid, previous_test_pid)
      restore_env(:source_operation_timeout_ms, previous_timeout)
    end)

    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "racing_sync_timeout_test",
               adapter_contract_id: RacingSyncAdapter.adapter_contract_id(),
               source_locator: %{kind: "test", name: "racing-sync-timeout"},
               access_profile: "events_read"
             })

    query = %{"object_type" => "Event"}

    assert {:error, :source_operation_timeout} =
             refresh_source(
               context.group_id,
               context.calendar["calendar_id"],
               source,
               RacingSyncAdapter,
               query
             )

    assert_receive {:racing_sync_read, first_reader, _first_ref, nil}
    refute Process.alive?(first_reader)

    Application.put_env(:salix_calendar, :source_operation_timeout_ms, 5_000)

    retry =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          query
        )
      end)

    assert_receive {:racing_sync_read, retry_reader, retry_ref, nil}

    send(retry_reader, {
      :racing_sync_page,
      retry_ref,
      %{"changes" => [], "next_continuation" => nil, "completed_cursor" => "cursor-1"}
    })

    assert {:ok, %{"sync_status" => "active"}} = Task.await(retry)
  end

  test "an active refresh keeps a post-provider failure until a complete sync", context do
    previous_test_pid = Application.get_env(:salix_calendar, :racing_sync_test_pid)
    Application.put_env(:salix_calendar, :racing_sync_test_pid, self())
    on_exit(fn -> restore_env(:racing_sync_test_pid, previous_test_pid) end)

    source_attrs = %{
      adapter: "racing_sync_test",
      adapter_contract_id: RacingSyncAdapter.adapter_contract_id(),
      source_locator: %{kind: "test", name: "durable-refresh-outcome"},
      access_profile: "events_read"
    }

    assert {:ok, source} =
             Server.ensure_source(
               context.group_id,
               context.calendar["calendar_id"],
               source_attrs
             )

    query = %{"object_type" => "Event"}

    initial =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          query
        )
      end)

    assert_receive {:racing_sync_read, initial_reader, initial_ref, nil}

    send(initial_reader, {
      :racing_sync_page,
      initial_ref,
      %{"changes" => [], "next_continuation" => nil, "completed_cursor" => "cursor-1"}
    })

    assert {:ok, %{"sync_status" => "active"}} = Task.await(initial)

    failed =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          query
        )
      end)

    assert_receive {:racing_sync_read, failed_reader, failed_ref, "cursor-1"}

    send(failed_reader, {
      :racing_sync_page,
      failed_ref,
      %{
        "changes" => List.duplicate(%{}, 201),
        "next_continuation" => nil,
        "completed_cursor" => "must-not-commit"
      }
    })

    assert {:error, :source_refresh_budget_exceeded} = Task.await(failed)

    assert {:ok, failed_source} =
             Server.get_source(
               context.group_id,
               context.calendar["calendar_id"],
               source["source_id"]
             )

    assert %{
             "status" => "error",
             "attempted_at" => attempted_at,
             "reason" => %{
               "kind" => "other",
               "class" => "source_refresh_budget_exceeded"
             }
           } = retained_outcome = get_in(failed_source, ["sync", "last_outcome"])

    assert is_integer(attempted_at)
    assert get_in(failed_source, ["sync", "completed_cursor"]) == "cursor-1"

    assert {:ok, policy_source} =
             Server.ensure_source(
               context.group_id,
               context.calendar["calendar_id"],
               Map.put(source_attrs, :sync_policy, %{"coverage" => "replacement"})
             )

    assert policy_source["sync"] == %{"last_outcome" => retained_outcome}

    replacement_query = %{"object_type" => "Event", "coverage" => "replacement"}

    recovered =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          replacement_query
        )
      end)

    assert_receive {:racing_sync_read, recovered_reader, recovered_ref, nil}

    assert {:ok, staging_source} =
             Server.get_source(
               context.group_id,
               context.calendar["calendar_id"],
               source["source_id"]
             )

    assert get_in(staging_source, ["sync", "last_outcome"]) == retained_outcome

    send(recovered_reader, {
      :racing_sync_page,
      recovered_ref,
      %{"changes" => [], "next_continuation" => nil, "completed_cursor" => "cursor-2"}
    })

    assert {:ok, %{"sync_status" => "active"}} = Task.await(recovered)

    assert {:ok, recovered_source} =
             Server.get_source(
               context.group_id,
               context.calendar["calendar_id"],
               source["source_id"]
             )

    refute get_in(recovered_source, ["sync", "last_outcome"])
    assert get_in(recovered_source, ["sync", "completed_cursor"]) == "cursor-2"
  end

  test "a failed outcome clear fails the refresh until a later success persists it", context do
    previous_test_pid = Application.get_env(:salix_calendar, :racing_sync_test_pid)
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_calendar, :racing_sync_test_pid, self())
    Application.put_env(:salix_store, :s3_backend, ControlledS3)

    on_exit(fn ->
      restore_env(:racing_sync_test_pid, previous_test_pid)
      restore_env(:s3_backend, previous_backend, :salix_store)
      Application.delete_env(:salix_calendar, :controlled_source_put)
    end)

    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "racing_sync_test",
               adapter_contract_id: RacingSyncAdapter.adapter_contract_id(),
               source_locator: %{kind: "test", name: "outcome-clear-failure"},
               access_profile: "events_read"
             })

    query = %{"object_type" => "Event"}
    assert {:ok, _initial} = run_racing_refresh(context, source, nil, nil, "cursor-1")

    failed =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          query
        )
      end)

    assert_receive {:racing_sync_read, failed_reader, failed_ref, "cursor-1"}

    send(failed_reader, {
      :racing_sync_page,
      failed_ref,
      %{
        "changes" => List.duplicate(%{}, 201),
        "next_continuation" => nil,
        "completed_cursor" => "must-not-commit"
      }
    })

    assert {:error, :source_refresh_budget_exceeded} = Task.await(failed)

    assert {:ok, actor} =
             Placement.ensure_source_started(
               context.group_id,
               context.calendar["calendar_id"],
               source["source_id"]
             )

    recovery =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          query
        )
      end)

    assert_receive {:racing_sync_read, recovery_reader, recovery_ref, "cursor-1"}

    source_key =
      Keys.ctl_calendar_source(
        context.group_id,
        context.calendar["calendar_id"],
        source["source_id"]
      )

    Application.put_env(:salix_calendar, :controlled_source_put, %{
      key: source_key,
      caller: actor,
      controller: self()
    })

    send(recovery_reader, {
      :racing_sync_page,
      recovery_ref,
      %{"changes" => [], "next_continuation" => nil, "completed_cursor" => "cursor-2"}
    })

    assert_receive {:controlled_source_put, ^actor, checkpoint_ref, ^source_key, _body, _opts}
    send(actor, {:controlled_source_put_continue, checkpoint_ref})

    assert_receive {:controlled_source_put, ^actor, clear_ref, ^source_key, _body, _opts}
    Application.delete_env(:salix_calendar, :controlled_source_put)
    send(actor, {:controlled_source_put_reply, clear_ref, {:error, {:http, 503}}})

    assert {:error, {:http, 503}} = Task.await(recovery)

    assert {:ok, unsettled_source} =
             SourceActor.read_source(
               context.group_id,
               context.calendar["calendar_id"],
               source["source_id"]
             )

    assert get_in(unsettled_source, ["sync", "completed_cursor"]) == "cursor-2"
    assert get_in(unsettled_source, ["sync", "last_outcome", "status"]) == "error"

    assert {:ok, _settled} = run_racing_refresh(context, source, nil, "cursor-2", "cursor-3")

    assert {:ok, settled_source} =
             SourceActor.read_source(
               context.group_id,
               context.calendar["calendar_id"],
               source["source_id"]
             )

    refute get_in(settled_source, ["sync", "last_outcome"])
  end

  test "a post-checkpoint failure stays unsettled when its outcome write also fails", context do
    previous_test_pid = Application.get_env(:salix_calendar, :racing_sync_test_pid)
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_calendar, :racing_sync_test_pid, self())
    Application.put_env(:salix_store, :s3_backend, ControlledS3)

    on_exit(fn ->
      restore_env(:racing_sync_test_pid, previous_test_pid)
      restore_env(:s3_backend, previous_backend, :salix_store)
      Application.delete_env(:salix_calendar, :controlled_source_put)
    end)

    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "racing_sync_test",
               adapter_contract_id: RacingSyncAdapter.adapter_contract_id(),
               source_locator: %{kind: "test", name: "post-checkpoint-outcome-failure"},
               access_profile: "events_read"
             })

    query = %{"object_type" => "Event"}
    assert {:ok, _initial} = run_racing_refresh(context, source, nil, nil, "cursor-1")

    assert {:ok, actor} =
             Placement.ensure_source_started(
               context.group_id,
               context.calendar["calendar_id"],
               source["source_id"]
             )

    refresh =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          query
        )
      end)

    assert_receive {:racing_sync_read, reader, reader_ref, "cursor-1"}

    source_key =
      Keys.ctl_calendar_source(
        context.group_id,
        context.calendar["calendar_id"],
        source["source_id"]
      )

    retirements_prefix =
      Keys.ctl_calendar_retirements_source_prefix(
        context.group_id,
        context.calendar["calendar_id"],
        source["source_id"]
      )

    Application.put_env(:salix_calendar, :controlled_source_put, %{
      key: source_key,
      caller: actor,
      controller: self()
    })

    :ok = S3.Fake.set_fault({:fail, 503, :list, retirements_prefix})

    send(reader, {
      :racing_sync_page,
      reader_ref,
      %{"changes" => [], "next_continuation" => nil, "completed_cursor" => "cursor-2"}
    })

    assert_receive {:controlled_source_put, ^actor, checkpoint_ref, ^source_key, _body, _opts}
    send(actor, {:controlled_source_put_continue, checkpoint_ref})

    assert_receive {:controlled_source_put, ^actor, outcome_ref, ^source_key, _body, _opts}
    Application.delete_env(:salix_calendar, :controlled_source_put)
    send(actor, {:controlled_source_put_reply, outcome_ref, {:error, {:http, 504}}})

    assert {:error, {:http, 503}} = Task.await(refresh)

    assert {:ok, unsettled_source} =
             SourceActor.read_source(
               context.group_id,
               context.calendar["calendar_id"],
               source["source_id"]
             )

    assert get_in(unsettled_source, ["sync", "completed_cursor"]) == "cursor-2"
    assert is_integer(get_in(unsettled_source, ["sync", "completed_at"]))
    assert get_in(unsettled_source, ["sync", "settlement_pending"]) == true
    refute get_in(unsettled_source, ["sync", "last_outcome"])
  end

  test "a stale outcome CAS retry cannot cross a lost source lease", context do
    previous_test_pid = Application.get_env(:salix_calendar, :racing_sync_test_pid)
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_calendar, :racing_sync_test_pid, self())

    on_exit(fn ->
      restore_env(:racing_sync_test_pid, previous_test_pid)
      restore_env(:s3_backend, previous_backend, :salix_store)
      Application.delete_env(:salix_calendar, :controlled_source_put)
    end)

    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "racing_sync_test",
               adapter_contract_id: RacingSyncAdapter.adapter_contract_id(),
               source_locator: %{kind: "test", name: "outcome-lease-fence"},
               access_profile: "events_read"
             })

    query = %{"object_type" => "Event"}
    assert {:ok, _initial} = run_racing_refresh(context, source, nil, nil, "cursor-1")

    actor_key =
      SourceActor.key(context.group_id, context.calendar["calendar_id"], source["source_id"])

    assert [{registered_actor, _}] = Registry.lookup(SalixCalendar.Registry, actor_key)

    assert :ok =
             DynamicSupervisor.terminate_child(SalixCalendar.FleetSupervisor, registered_actor)

    Application.put_env(:salix_store, :s3_backend, ControlledS3)

    actor_opts = [
      group_id: context.group_id,
      calendar_id: context.calendar["calendar_id"],
      source_id: source["source_id"]
    ]

    stale_actor = start_unnamed_test_server!(SourceActor, actor_opts)

    stale_refresh =
      Task.async(fn -> GenServer.call(stale_actor, {:refresh, query}, :infinity) end)

    assert_receive {:racing_sync_read, stale_reader, stale_ref, "cursor-1"}
    stale_guard = :sys.get_state(stale_actor).lease_guard

    source_key =
      Keys.ctl_calendar_source(
        context.group_id,
        context.calendar["calendar_id"],
        source["source_id"]
      )

    Application.put_env(:salix_calendar, :controlled_source_put, %{
      key: source_key,
      caller: stale_actor,
      controller: self()
    })

    send(stale_reader, {
      :racing_sync_page,
      stale_ref,
      %{
        "changes" => List.duplicate(%{}, 201),
        "next_continuation" => nil,
        "completed_cursor" => "stale-cursor"
      }
    })

    assert_receive {:controlled_source_put, ^stale_actor, stale_put_ref, ^source_key, _body,
                    _opts}

    Process.exit(stale_guard, :kill)

    lease_key =
      Keys.ctl_calendar_source_lease(
        context.group_id,
        context.calendar["calendar_id"],
        source["source_id"]
      )

    assert :ok = S3.delete(lease_key)

    latest_actor = start_unnamed_test_server!(SourceActor, actor_opts)

    latest_refresh =
      Task.async(fn -> GenServer.call(latest_actor, {:refresh, query}, :infinity) end)

    assert_receive {:racing_sync_read, latest_reader, latest_ref, "cursor-1"}

    send(latest_reader, {
      :racing_sync_page,
      latest_ref,
      %{"changes" => [], "next_continuation" => nil, "completed_cursor" => "cursor-2"}
    })

    assert {:ok, %{"sync_status" => "active"}} = Task.await(latest_refresh)

    send(stale_actor, {:controlled_source_put_continue, stale_put_ref})

    assert {:error, :source_refresh_budget_exceeded} = Task.await(stale_refresh)
    Application.delete_env(:salix_calendar, :controlled_source_put)

    assert {:ok, latest_source} =
             SourceActor.read_source(
               context.group_id,
               context.calendar["calendar_id"],
               source["source_id"]
             )

    assert get_in(latest_source, ["sync", "completed_cursor"]) == "cursor-2"
    refute get_in(latest_source, ["sync", "last_outcome"])
  end

  test "replacement-generation recurrence patches cannot mutate the visible generation",
       context do
    locator = %{"event_id" => "series-staging"}
    recurrence_key = "2026-07-27T10:00:00"

    master =
      event_record(
        locator["event_id"],
        scheduling_identity("series-staging@example.com"),
        "organizer",
        "Generation-isolated series",
        1
      )
      |> put_in(["object", "recurrenceRules"], [
        %{"frequency" => "weekly", "interval" => 1, "byDay" => [%{"day" => "mo"}]}
      ])

    active_patch = recurrence_patch(locator, recurrence_key, "2026-07-27T11:00:00", 0)

    assert {:ok, [_master]} = apply_record(context, Map.put(master, "source_generation", 0))
    assert {:ok, [_patch]} = apply_record(context, active_patch)
    assert occurrence_start(context, ~D[2026-07-27]) == "2026-07-27T11:00:00"

    staging_patch = recurrence_patch(locator, recurrence_key, "2026-07-27T12:00:00", 1)

    assert {:ok, [_staged_master, _staging_patch]} =
             apply_records(
               context,
               context.source,
               [master, staging_patch],
               %{"fixture_source_id" => context.source["source_id"], "coverage" => "replacement"}
             )

    assert occurrence_start(context, ~D[2026-07-27]) == "2026-07-27T12:00:00"
  end

  test "bootstrap ignores a deleted recurring master after its exception patches", context do
    locator = %{"event_id" => "deleted-series"}
    recurrence_key = "2026-07-27T10:00:00"

    patch =
      recurrence_patch(locator, recurrence_key, "2026-07-27T11:00:00", 1, [2])

    tombstone = %{
      "external_locator" => locator,
      "tombstone" => true,
      "source_version" => %{"sequence" => 2},
      "source_revision" => [2]
    }

    assert {:ok, [deferred, ignored]} =
             apply_records(context, context.source, [patch, tombstone])

    assert deferred["status"] == "deferred"
    assert ignored["status"] == "ignored"
    assert ignored["calendar_item_id"] == deferred["calendar_item_id"]

    assert {:error, :not_found} =
             Server.get_item(
               context.group_id,
               context.calendar["calendar_id"],
               deferred["calendar_item_id"]
             )

    assert {:ok, %{"sync" => %{"status" => "active"}}} =
             Server.get_source(
               context.group_id,
               context.calendar["calendar_id"],
               context.source["source_id"]
             )
  end

  test "replacement activation cannot roll back an exact refresh after an earlier staging page",
       context do
    locator = "replacement-exact-race"
    identity = scheduling_identity("replacement-exact-race@example.com")

    initial =
      event_record(locator, identity, "organizer", "Initial provider fact", 1)
      |> Map.put("source_revision", [1])

    assert {:ok, [item]} = apply_record(context, initial)

    exact_refresh =
      initial
      |> Map.put("source_revision", [3])
      |> put_in(["object", "title"], "Newest exact provider fact")
      |> put_in(["scheduling_revision", "sequence"], 3)
      |> put_in(["scheduling_revision", "shared_fact_hash"], "newest-exact-provider-fact")
      |> put_in(["source_version", "sequence"], 3)

    assert {:ok, [_refreshed]} = apply_record(context, exact_refresh)

    stale_replacement =
      initial
      |> Map.put("source_revision", [1])

    page_two_copy =
      event_record(
        "replacement-page-two",
        scheduling_identity("replacement-page-two@example.com"),
        "organizer",
        "Replacement page two",
        1
      )
      |> Map.put("source_revision", [1])

    assert {:ok, [_retained, _page_two]} =
             apply_records(
               context,
               context.source,
               [stale_replacement, page_two_copy],
               %{"fixture_source_id" => context.source["source_id"], "coverage" => "replacement"}
             )

    assert {:ok, visible} =
             Server.get_item(
               context.group_id,
               context.calendar["calendar_id"],
               item["calendar_item_id"]
             )

    assert get_in(visible, ["object", "title"]) == "Newest exact provider fact"
    assert visible["source_revision"] == [3]
  end

  for order <- [:master_first, :patch_first] do
    @tag replacement_order: order
    test "#{order} replacement retains an unchanged master and a newer exact recurrence override",
         context do
      locator = %{"event_id" => "replacement-exact-override-race"}
      recurrence_key = "2026-07-27T10:00:00"

      master =
        event_record(
          locator["event_id"],
          scheduling_identity("replacement-exact-override-race@example.com"),
          "organizer",
          "Replacement override race",
          1
        )
        |> Map.put("source_revision", [1])
        |> put_in(["object", "recurrenceRules"], [
          %{"frequency" => "weekly", "interval" => 1, "byDay" => [%{"day" => "mo"}]}
        ])

      initial_patch =
        recurrence_patch(locator, recurrence_key, "2026-07-27T11:00:00", 0, [1])

      assert {:ok, [_master]} = apply_record(context, master)
      assert {:ok, [_initial]} = apply_record(context, initial_patch)

      staged_patch =
        recurrence_patch(locator, recurrence_key, "2026-07-27T11:00:00", 1, [1])
        |> put_in(
          ["source_version_patch", "recurrence_instances", recurrence_key],
          "instance-0"
        )

      exact_patch =
        recurrence_patch(locator, recurrence_key, "2026-07-27T12:00:00", 0, [3])

      assert {:ok, [_refreshed]} = apply_record(context, exact_patch)
      assert occurrence_start(context, ~D[2026-07-27]) == "2026-07-27T12:00:00"

      page_two_copy =
        event_record(
          "replacement-override-page-two",
          scheduling_identity("replacement-override-page-two@example.com"),
          "organizer",
          "Replacement override page two",
          1
        )
        |> Map.put("source_revision", [1])

      records =
        if context.replacement_order == :master_first,
          do: [master, staged_patch, page_two_copy],
          else: [staged_patch, master, page_two_copy]

      assert {:ok, [_first, _second, _page_two]} =
               apply_records(
                 context,
                 context.source,
                 records,
                 %{
                   "fixture_source_id" => context.source["source_id"],
                   "coverage" => "replacement"
                 }
               )

      assert occurrence_start(context, ~D[2026-07-27]) == "2026-07-27T12:00:00"
    end
  end

  test "exact refresh and collection reads cannot overlap for one source", context do
    previous_test_pid = Application.get_env(:salix_calendar, :racing_sync_test_pid)
    Application.put_env(:salix_calendar, :racing_sync_test_pid, self())

    on_exit(fn ->
      if previous_test_pid,
        do: Application.put_env(:salix_calendar, :racing_sync_test_pid, previous_test_pid),
        else: Application.delete_env(:salix_calendar, :racing_sync_test_pid)
    end)

    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "racing_sync_test",
               adapter_contract_id: RacingSyncAdapter.adapter_contract_id(),
               source_locator: %{kind: "test", name: "racing-exact"},
               access_profile: "events_read"
             })

    query = %{"object_type" => "Event"}
    identity = scheduling_identity("racing-exact@example.com")
    initial = event_record("racing-exact", identity, "organizer", "Initial source fact", 1)

    initial_task =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          query
        )
      end)

    assert_receive {:racing_sync_read, initial_reader, initial_ref, nil}

    send(
      initial_reader,
      {:racing_sync_page, initial_ref,
       %{
         "changes" => [initial],
         "next_continuation" => nil,
         "completed_cursor" => "cursor-1"
       }}
    )

    assert {:ok, _result} = Task.await(initial_task)
    assert {:ok, [entry]} = occurrences_on(context, ~D[2026-07-20])

    exact_task =
      Task.async(fn ->
        revalidate_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          entry["item"],
          entry["occurrence"]
        )
      end)

    assert_receive {:racing_exact_read, exact_reader, exact_ref}

    queued_refresh =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          query
        )
      end)

    refute_receive {:racing_sync_read, _reader, _ref, _cursor}, 100

    newest = event_record("racing-exact", identity, "organizer", "Newest exact fact", 3)
    send(exact_reader, {:racing_exact_record, exact_ref, newest})
    assert {:ok, refreshed} = Task.await(exact_task)
    assert get_in(refreshed, ["object", "title"]) == "Newest exact fact"

    assert_receive {:racing_sync_read, queued_reader, queued_ref, "cursor-1"}

    send(queued_reader, {
      :racing_sync_page,
      queued_ref,
      %{"changes" => [], "next_continuation" => nil, "completed_cursor" => "cursor-2"}
    })

    assert {:ok, _queued} = Task.await(queued_refresh)

    assert {:ok, [visible]} = occurrences_on(context, ~D[2026-07-20])
    assert get_in(visible, ["item", "object", "title"]) == "Newest exact fact"
  end

  test "a source policy change after provider read fences the pending exact commit",
       context do
    previous_test_pid = Application.get_env(:salix_calendar, :racing_sync_test_pid)
    Application.put_env(:salix_calendar, :racing_sync_test_pid, self())

    on_exit(fn ->
      if previous_test_pid,
        do: Application.put_env(:salix_calendar, :racing_sync_test_pid, previous_test_pid),
        else: Application.delete_env(:salix_calendar, :racing_sync_test_pid)
    end)

    source_attrs = %{
      adapter: "racing_sync_test",
      adapter_contract_id: RacingSyncAdapter.adapter_contract_id(),
      source_locator: %{kind: "test", name: "racing-policy-change"},
      access_profile: "events_read",
      sync_policy: %{"provider_default_timezone" => "Asia/Shanghai"}
    }

    assert {:ok, source} =
             Server.ensure_source(
               context.group_id,
               context.calendar["calendar_id"],
               source_attrs
             )

    identity = scheduling_identity("racing-policy-change@example.com")
    initial = event_record("racing-policy-change", identity, "organizer", "Initial fact", 1)

    initial_task =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          %{"object_type" => "Event"}
        )
      end)

    assert_receive {:racing_sync_read, initial_reader, initial_ref, nil}

    send(
      initial_reader,
      {:racing_sync_page, initial_ref,
       %{
         "changes" => [initial],
         "next_continuation" => nil,
         "completed_cursor" => "cursor-1"
       }}
    )

    assert {:ok, _result} = Task.await(initial_task)
    assert {:ok, [entry]} = occurrences_on(context, ~D[2026-07-20])

    exact_task =
      Task.async(fn ->
        revalidate_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          entry["item"],
          entry["occurrence"]
        )
      end)

    assert_receive {:racing_exact_read, exact_reader, exact_ref}

    assert {:ok, changed_source} =
             Server.ensure_source(
               context.group_id,
               context.calendar["calendar_id"],
               put_in(
                 source_attrs,
                 [:sync_policy, "provider_default_timezone"],
                 "America/Los_Angeles"
               )
             )

    assert changed_source["sync_policy_revision"] == source["sync_policy_revision"] + 1

    stale = event_record("racing-policy-change", identity, "organizer", "Stale exact fact", 2)
    send(exact_reader, {:racing_exact_record, exact_ref, stale})

    assert {:error, :calendar_source_contract_mismatch} = Task.await(exact_task)
    assert {:ok, [visible]} = occurrences_on(context, ~D[2026-07-20])
    assert get_in(visible, ["item", "object", "title"]) == "Initial fact"
  end

  test "a source commit accepted before timeout finishes with a definite result", context do
    previous_test_pid = Application.get_env(:salix_calendar, :racing_sync_test_pid)
    previous_timeout = Application.get_env(:salix_calendar, :source_operation_timeout_ms)
    previous_renewal = Application.get_env(:salix_calendar, :source_lease_renew_interval_ms)
    Application.put_env(:salix_calendar, :racing_sync_test_pid, self())
    Application.put_env(:salix_calendar, :source_operation_timeout_ms, 100)
    Application.put_env(:salix_calendar, :source_lease_renew_interval_ms, 20)

    on_exit(fn ->
      restore_env(:racing_sync_test_pid, previous_test_pid)
      restore_env(:source_operation_timeout_ms, previous_timeout)
      restore_env(:source_lease_renew_interval_ms, previous_renewal)
    end)

    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "racing_sync_test",
               adapter_contract_id: RacingSyncAdapter.adapter_contract_id(),
               source_locator: %{kind: "test", name: "timed-out-source-commit"},
               access_profile: "events_read"
             })

    identity = scheduling_identity("timed-out-source-commit@example.com")
    initial = event_record("timed-out-source-commit", identity, "organizer", "Initial fact", 1)
    assert {:ok, _initial} = run_racing_refresh(context, source, initial, nil, "cursor-1")

    assert {:ok, [entry]} = occurrences_on(context, ~D[2026-07-20])

    exact_task =
      Task.async(fn ->
        revalidate_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          entry["item"],
          entry["occurrence"]
        )
      end)

    assert_receive {:racing_exact_read, exact_reader, exact_ref}
    Process.sleep(30)

    refreshed_record =
      event_record("timed-out-source-commit", identity, "organizer", "Late commit", 2)

    send(exact_reader, {:racing_exact_record, exact_ref, refreshed_record})

    assert {:ok, refreshed} = Task.await(exact_task)
    assert get_in(refreshed, ["object", "title"]) == "Late commit"

    assert {:ok, [visible]} = occurrences_on(context, ~D[2026-07-20])
    assert get_in(visible, ["item", "object", "title"]) == "Late commit"
  end

  test "a commit queued before its timeout survives an actor mailbox backlog", context do
    previous_test_pid = Application.get_env(:salix_calendar, :racing_sync_test_pid)
    previous_timeout = Application.get_env(:salix_calendar, :source_operation_timeout_ms)
    Application.put_env(:salix_calendar, :racing_sync_test_pid, self())
    Application.put_env(:salix_calendar, :source_operation_timeout_ms, 100)

    on_exit(fn ->
      restore_env(:racing_sync_test_pid, previous_test_pid)
      restore_env(:source_operation_timeout_ms, previous_timeout)
    end)

    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "racing_sync_test",
               adapter_contract_id: RacingSyncAdapter.adapter_contract_id(),
               source_locator: %{kind: "test", name: "queued-commit-timeout"},
               access_profile: "events_read"
             })

    identity = scheduling_identity("queued-commit-timeout@example.com")
    initial = event_record("queued-commit-timeout", identity, "organizer", "Initial fact", 1)
    assert {:ok, _initial} = run_racing_refresh(context, source, initial, nil, "cursor-1")

    assert {:ok, [entry]} = occurrences_on(context, ~D[2026-07-20])

    assert {:ok, source_actor} =
             Placement.ensure_source_started(
               context.group_id,
               context.calendar["calendar_id"],
               source["source_id"]
             )

    exact_task =
      Task.async(fn ->
        revalidate_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          entry["item"],
          entry["occurrence"]
        )
      end)

    assert_receive {:racing_exact_read, exact_reader, exact_ref}
    :ok = :sys.suspend(source_actor)

    refreshed =
      event_record("queued-commit-timeout", identity, "organizer", "Accepted commit", 2)

    send(exact_reader, {:racing_exact_record, exact_ref, refreshed})
    Process.sleep(150)

    :ok = :sys.resume(source_actor)

    assert {:ok, result} = Task.await(exact_task)
    assert get_in(result, ["object", "title"]) == "Accepted commit"

    assert {:ok, [visible]} = occurrences_on(context, ~D[2026-07-20])
    assert get_in(visible, ["item", "object", "title"]) == "Accepted commit"
  end

  test "an older recurrence override cannot roll back a newer exact override", context do
    locator = %{"event_id" => "stale-recurrence-override"}
    recurrence_key = "2026-07-27T10:00:00"

    master =
      event_record(
        locator["event_id"],
        scheduling_identity("stale-recurrence-override@example.com"),
        "organizer",
        "Versioned recurring event",
        1
      )
      |> put_in(["object", "recurrenceRules"], [
        %{"frequency" => "weekly", "interval" => 1, "byDay" => [%{"day" => "mo"}]}
      ])

    assert {:ok, [_master]} = apply_record(context, master)

    newest_patch =
      recurrence_patch(locator, recurrence_key, "2026-07-27T12:00:00", 0, [3])

    assert {:ok, [_newest]} = apply_record(context, newest_patch)
    assert occurrence_start(context, ~D[2026-07-27]) == "2026-07-27T12:00:00"

    stale_patch =
      recurrence_patch(locator, recurrence_key, "2026-07-27T11:00:00", 0, [2])

    assert {:ok, [_unchanged]} = apply_record(context, stale_patch)
    assert occurrence_start(context, ~D[2026-07-27]) == "2026-07-27T12:00:00"
  end

  defp apply_record(context, record) do
    apply_record(context, context.source, record)
  end

  defp apply_record(context, source, record) do
    apply_records(context, source, [record])
  end

  defp apply_records(context, source, records, query_contract \\ nil) do
    cursor = System.unique_integer([:positive])

    fixtures =
      :salix_calendar
      |> Application.get_env(:source_actor_fixtures, %{})
      |> Map.put(source["source_id"], %{records: records, cursor: cursor})

    Application.put_env(:salix_calendar, :source_actor_fixtures, fixtures)

    with {:ok, %{"applied" => applied}} <-
           Server.refresh_source(
             context.group_id,
             context.calendar["calendar_id"],
             source["source_id"],
             query_contract || %{"fixture_source_id" => source["source_id"]}
           ) do
      {:ok, applied}
    end
  end

  defp capture_retirements(result \\ {:ok, nil}) do
    Application.put_env(:salix_calendar, :retirement_sink, RetirementSink)
    Application.put_env(:salix_calendar, :retirement_test_pid, self())
    Application.put_env(:salix_calendar, :retirement_test_result, result)
  end

  defp refresh_source(group_id, calendar_id, source, adapter, query_contract) do
    adapters = Application.get_env(:salix_calendar, :source_adapters, %{})

    Application.put_env(
      :salix_calendar,
      :source_adapters,
      Map.put(adapters, source["adapter"], adapter)
    )

    Server.refresh_source(
      group_id,
      calendar_id,
      source["source_id"],
      query_contract
    )
  end

  defp revalidate_source(group_id, calendar_id, source, adapter, item, occurrence) do
    adapters = Application.get_env(:salix_calendar, :source_adapters, %{})

    Application.put_env(
      :salix_calendar,
      :source_adapters,
      Map.put(adapters, source["adapter"], adapter)
    )

    Server.revalidate_source(group_id, calendar_id, source["source_id"], item, occurrence)
  end

  defp run_racing_refresh(context, source, record, expected_cursor, completed_cursor) do
    task =
      Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          %{"object_type" => "Event"}
        )
      end)

    assert_receive {:racing_sync_read, reader, ref, ^expected_cursor}

    send(reader, {
      :racing_sync_page,
      ref,
      %{
        "changes" => if(is_nil(record), do: [], else: [record]),
        "next_continuation" => nil,
        "completed_cursor" => completed_cursor
      }
    })

    Task.await(task)
  end

  defp ensure_source(context, suffix) do
    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "salix_task_schedule",
               adapter_contract_id: SalixTaskSchedule.adapter_contract_id(),
               source_locator: %{kind: "test", name: suffix},
               access_profile: "scheduled_tasks_read"
             })

    source
  end

  defp scheduling_identity(uid) do
    %{
      "identity_version" => "test.v1",
      "namespace" => "test",
      "series_uid" => uid,
      "scheduling_authority_key" => "owner@example.com"
    }
  end

  defp event_record(locator, identity, copy_role, title, sequence) do
    %{
      "external_locator" => %{"event_id" => locator},
      "copy_role" => copy_role,
      "object" => %{
        "@type" => "Event",
        "uid" => identity["series_uid"],
        "title" => title,
        "start" => "2026-07-20T10:00:00",
        "duration" => "PT30M",
        "timeZone" => "Asia/Shanghai"
      },
      "scheduling_identity" => identity,
      "scheduling_revision" => %{
        "sequence" => sequence,
        "updated" => "2026-07-20T00:00:00Z",
        "shared_fact_hash" => "facts-#{title}"
      },
      "source_version" => %{"sequence" => sequence},
      "normalization_state" => "complete"
    }
  end

  defp recurrence_patch(locator, recurrence_key, start, generation) do
    recurrence_patch(locator, recurrence_key, start, generation, [generation + 1])
  end

  defp recurrence_patch(locator, recurrence_key, start, generation, source_revision) do
    %{
      "external_locator" => locator,
      "source_generation" => generation,
      "object_patch" => %{
        "recurrenceOverrides" => %{
          recurrence_key => %{"start" => start, "duration" => "PT30M"}
        }
      },
      "source_version_patch" => %{
        "recurrence_instances" => %{recurrence_key => "instance-#{generation}"}
      },
      "source_revision_patch" => %{recurrence_key => source_revision}
    }
  end

  defp occurrence_start(context, date) do
    assert {:ok, [entry]} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(date, ~T[00:00:00]),
               unix_ms(Date.add(date, 1), ~T[00:00:00])
             )

    get_in(entry, ["occurrence", "effective", "start"])
  end

  defp occurrences_on(context, date) do
    Occurrences.list(
      context.group_id,
      context.calendar["calendar_id"],
      unix_ms(date, ~T[00:00:00]),
      unix_ms(Date.add(date, 1), ~T[00:00:00])
    )
  end

  defp visible_titles(context) do
    assert {:ok, entries} =
             Occurrences.list(
               context.group_id,
               context.calendar["calendar_id"],
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )

    entries
    |> Enum.map(&get_in(&1, ["item", "object", "title"]))
    |> Enum.sort()
  end

  defp task_projection do
    conversation_id = Ids.new_conversation_id()
    schedule_id = Ids.new_schedule_id()

    %{
      "conversation_id" => conversation_id,
      "kind" => "agent_task",
      "title" => "Prepare weekday standup",
      "status" => "active",
      "revision" => 4,
      "recurrence_anchor_at" => unix_ms(~D[2026-07-20], ~T[10:00:00]),
      "next_fire_at" => unix_ms(~D[2026-07-20], ~T[10:00:00]),
      "schedule" => %{"schedule_id" => schedule_id},
      "schedule_definition" => %{
        "id" => schedule_id,
        "receiver" => "task",
        "payload" => %{"conversation_id" => conversation_id},
        "cron" => "0 10 * * 1-5",
        "timezone" => "Asia/Shanghai"
      }
    }
  end

  defp unix_ms(date, time) do
    date
    |> DateTime.new!(time, "Asia/Shanghai")
    |> DateTime.to_unix(:millisecond)
  end

  defp calendar_identity_key(group_id, identity) do
    digest =
      identity
      |> JSON.stringify()
      |> :erlang.term_to_binary([:deterministic])
      |> Crypto.hex()

    Keys.ctl_calendar_ensure(group_id, digest)
  end

  defp start_unnamed_test_server!(module, init_arg) do
    start_supervised!(%{
      id: {module, make_ref()},
      start: {GenServer, :start_link, [module, init_arg]},
      restart: :temporary,
      type: :worker
    })
  end

  defp restore_env(key, nil), do: Application.delete_env(:salix_calendar, key)
  defp restore_env(key, value), do: Application.put_env(:salix_calendar, key, value)

  defp restore_env(key, nil, app), do: Application.delete_env(app, key)
  defp restore_env(key, value, app), do: Application.put_env(app, key, value)
end
