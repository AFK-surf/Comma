defmodule SalixCalendar.ServerTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.SalixStore", "Elixir.SalixCalendar"]
  require SystemsClock

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
      case SystemsRuntime.get_env(:salix_calendar, :expiring_adapter_mode, :initial) do
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
      changes = SystemsRuntime.fetch_env!(:salix_calendar, :counting_activation_changes)

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

      SystemsRuntime.fetch_env!(:salix_calendar, :counting_activation_changes)
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
      calls = SystemsRuntime.get_env(:salix_calendar, :counting_activation_calls, 0)
      SystemsRuntime.put_env(:salix_calendar, :counting_activation_calls, calls + 1)
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
      test_pid = SystemsRuntime.fetch_env!(:salix_calendar, :racing_sync_test_pid)
      request_ref = SystemsRuntime.Proc.make_ref()

      SystemsRuntime.Proc.send(
        test_pid,
        {:racing_sync_read, SystemsRuntime.Proc.self(), request_ref, cursor}
      )

      SystemsClock.vreceive do
        {:racing_sync_page, ^request_ref, page} -> {:ok, page}
      after
        5_000 -> {:error, :racing_sync_test_timeout}
      end
    end

    @impl true
    def exact_refresh(_source, _item, _occurrence) do
      test_pid = SystemsRuntime.fetch_env!(:salix_calendar, :racing_sync_test_pid)
      request_ref = SystemsRuntime.Proc.make_ref()

      SystemsRuntime.Proc.send(
        test_pid,
        {:racing_exact_read, SystemsRuntime.Proc.self(), request_ref}
      )

      SystemsClock.vreceive do
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
      case SystemsRuntime.get_env(:salix_calendar, :controlled_source_put) do
        %{key: ^key, caller: caller, controller: controller}
        when SystemsRuntime.Proc.is_process(controller) ->
          if caller == :any or caller == SystemsRuntime.Proc.self() do
            ref = SystemsRuntime.Proc.make_ref()

            SystemsRuntime.Proc.send(
              controller,
              {:controlled_source_put, SystemsRuntime.Proc.self(), ref, key, body, opts}
            )

            SystemsClock.vreceive do
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
      fixtures = SystemsRuntime.get_env(:salix_calendar, :source_actor_fixtures, %{})
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
      test_pid = SystemsRuntime.fetch_env!(:salix_calendar, :retirement_test_pid)

      SystemsRuntime.Proc.send(
        test_pid,
        {:retire_scheduling_link, group_id, calendar_id, link_id, cursor}
      )

      SystemsRuntime.get_env(:salix_calendar, :retirement_test_result, {:ok, nil})
    end
  end

  defmodule BlockingRetirementSink do
    def cancel_scheduling_link(group_id, calendar_id, link_id, cursor) do
      test_pid = SystemsRuntime.fetch_env!(:salix_calendar, :retirement_test_pid)
      ref = SystemsRuntime.Proc.make_ref()

      SystemsRuntime.Proc.send(
        test_pid,
        {:blocking_retirement_entered, SystemsRuntime.Proc.self(), ref, group_id, calendar_id,
         link_id, cursor}
      )

      SystemsClock.vreceive do
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

    previous_adapters = SystemsRuntime.get_env(:salix_calendar, :source_adapters)
    previous_sink = SystemsRuntime.get_env(:salix_calendar, :retirement_sink)

    SystemsRuntime.put_env(:salix_calendar, :source_adapters, %{
      "salix_task_schedule" => FixtureAdapter,
      "expiring_test" => ExpiringAdapter,
      "counting_activation_test" => CountingActivationAdapter,
      "contract_change_test" => ContractChangeAdapter,
      "racing_sync_test" => RacingSyncAdapter,
      "racing_sync_timeout_test" => RacingSyncAdapter
    })

    SystemsRuntime.delete_env(:salix_calendar, :retirement_sink)

    on_exit(fn ->
      restore_env(:source_adapters, previous_adapters)
      restore_env(:retirement_sink, previous_sink)
      SystemsRuntime.delete_env(:salix_calendar, :source_actor_fixtures)
      SystemsRuntime.delete_env(:salix_calendar, :retirement_test_pid)
      SystemsRuntime.delete_env(:salix_calendar, :retirement_test_result)
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

  test "cursor expiry stages a replacement generation and atomically switches visibility",
       context do
    on_exit(fn -> SystemsRuntime.delete_env(:salix_calendar, :expiring_adapter_mode) end)

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
    SystemsRuntime.put_env(:salix_calendar, :expiring_adapter_mode, :rebuild)

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

  test "the generic source lease supports stale takeover and fences the old owner", context do
    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "contract_change_test",
               adapter_contract_id: ContractChangeAdapter.adapter_contract_id(),
               source_locator: %{kind: "test", name: "lease-takeover"},
               access_profile: "events_read"
             })

    now = SystemsClock.system_time(:millisecond)
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
    previous_test_pid = SystemsRuntime.get_env(:salix_calendar, :racing_sync_test_pid)
    SystemsRuntime.put_env(:salix_calendar, :racing_sync_test_pid, SystemsRuntime.Proc.self())
    on_exit(fn -> restore_env(:racing_sync_test_pid, previous_test_pid) end)

    assert {:ok, source} =
             Server.ensure_source(context.group_id, context.calendar["calendar_id"], %{
               adapter: "racing_sync_test",
               adapter_contract_id: RacingSyncAdapter.adapter_contract_id(),
               source_locator: %{kind: "test", name: "lease-stolen-during-provider-io"},
               access_profile: "events_read"
             })

    refresh_task =
      SystemsRuntime.Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          %{"object_type" => "Event", "coverage" => "initial"}
        )
      end)

    settle_receive({:racing_sync_read, stale_reader, stale_ref, nil})

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

    SystemsRuntime.Proc.send(stale_reader, {
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
             settled_await(refresh_task)

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

  test "a source commit accepted before timeout finishes with a definite result", context do
    previous_test_pid = SystemsRuntime.get_env(:salix_calendar, :racing_sync_test_pid)
    previous_timeout = SystemsRuntime.get_env(:salix_calendar, :source_operation_timeout_ms)
    previous_renewal = SystemsRuntime.get_env(:salix_calendar, :source_lease_renew_interval_ms)
    SystemsRuntime.put_env(:salix_calendar, :racing_sync_test_pid, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_calendar, :source_operation_timeout_ms, 100)
    SystemsRuntime.put_env(:salix_calendar, :source_lease_renew_interval_ms, 20)

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
      SystemsRuntime.Task.async(fn ->
        revalidate_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          entry["item"],
          entry["occurrence"]
        )
      end)

    settle_receive({:racing_exact_read, exact_reader, exact_ref})
    SystemsClock.sleep(30)

    refreshed_record =
      event_record("timed-out-source-commit", identity, "organizer", "Late commit", 2)

    SystemsRuntime.Proc.send(exact_reader, {:racing_exact_record, exact_ref, refreshed_record})

    assert {:ok, refreshed} = settled_await(exact_task)
    assert get_in(refreshed, ["object", "title"]) == "Late commit"

    assert {:ok, [visible]} = occurrences_on(context, ~D[2026-07-20])
    assert get_in(visible, ["item", "object", "title"]) == "Late commit"
  end

  defp apply_record(context, record) do
    apply_record(context, context.source, record)
  end

  defp apply_record(context, source, record) do
    apply_records(context, source, [record])
  end

  defp apply_records(context, source, records, query_contract \\ nil) do
    cursor = SystemsRuntime.Proc.unique_integer([:positive])

    fixtures =
      :salix_calendar
      |> SystemsRuntime.get_env(:source_actor_fixtures, %{})
      |> Map.put(source["source_id"], %{records: records, cursor: cursor})

    SystemsRuntime.put_env(:salix_calendar, :source_actor_fixtures, fixtures)

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

  defp refresh_source(group_id, calendar_id, source, adapter, query_contract) do
    adapters = SystemsRuntime.get_env(:salix_calendar, :source_adapters, %{})

    SystemsRuntime.put_env(
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
    adapters = SystemsRuntime.get_env(:salix_calendar, :source_adapters, %{})

    SystemsRuntime.put_env(
      :salix_calendar,
      :source_adapters,
      Map.put(adapters, source["adapter"], adapter)
    )

    Server.revalidate_source(group_id, calendar_id, source["source_id"], item, occurrence)
  end

  defp run_racing_refresh(context, source, record, expected_cursor, completed_cursor) do
    task =
      SystemsRuntime.Task.async(fn ->
        refresh_source(
          context.group_id,
          context.calendar["calendar_id"],
          source,
          RacingSyncAdapter,
          %{"object_type" => "Event"}
        )
      end)

    settle_receive({:racing_sync_read, reader, ref, ^expected_cursor})

    SystemsRuntime.Proc.send(reader, {
      :racing_sync_page,
      ref,
      %{
        "changes" => if(is_nil(record), do: [], else: [record]),
        "next_continuation" => nil,
        "completed_cursor" => completed_cursor
      }
    })

    settled_await(task)
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

  defp restore_env(key, nil), do: SystemsRuntime.delete_env(:salix_calendar, key)
  defp restore_env(key, value), do: SystemsRuntime.put_env(:salix_calendar, key, value)

  defp restore_env(key, nil, app), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(key, value, app), do: SystemsRuntime.put_env(app, key, value)
end
