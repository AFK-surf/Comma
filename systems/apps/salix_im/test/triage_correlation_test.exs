defmodule SalixIM.Triage.CorrelationTest do
  use ExUnit.Case, async: false

  alias SalixIM.Triage.{CanonicalJSON, Correlation}
  alias SalixStore.{CasRecord, S3, ULID}

  setup do
    previous_triage_backend = Application.get_env(:salix_store, :triage_record_backend)
    Application.put_env(:salix_store, :triage_record_backend, SalixStore.S3)
    S3.Fake.reset()

    on_exit(fn ->
      if previous_triage_backend do
        Application.put_env(:salix_store, :triage_record_backend, previous_triage_backend)
      else
        Application.delete_env(:salix_store, :triage_record_backend)
      end
    end)

    :ok
  end

  test "rejects empty or malformed operator selectors before storage reads" do
    namespace = "triage-correlation-invalid-#{System.unique_integer([:positive])}"

    assert {:error, :invalid_triage_correlation} =
             Correlation.lookup(namespace, {:slack_event_id, "  "})

    assert {:error, :invalid_triage_correlation} =
             Correlation.lookup(namespace, {:receipt_ref, ""})

    assert {:error, :invalid_triage_correlation} =
             Correlation.lookup(namespace, {:slack_permalink, "https://example.com/not-slack"})

    assert S3.Fake.read_log(self()) == []
  end

  test "stores only hashed selectors, detects ambiguity, and bounds time windows" do
    namespace = "triage-correlation-index-#{System.unique_integer([:positive])}"
    event_id = "Ev-private-correlation"
    receipt_ref = "s3://private/receipt/correlation"

    winning_input = %{
      "schema" => "comma.triage-input-snapshot.v2",
      "events" => [
        %{
          "event_id" => event_id,
          "message_ts" => "1710000000.000100",
          "bucket" => %{"channel_id" => "C_PRIVATE"}
        }
      ],
      "receipt_refs" => [receipt_ref]
    }

    assert {:ok, bindings} = Correlation.bindings(winning_input)
    assert length(bindings) == 3

    first = public_run(1_780_000_000_100)
    second = public_run(1_780_000_000_200)

    Enum.each([first, second], fn run ->
      persist_public_run(namespace, run)
      assert :ok = Correlation.persist(namespace, bindings, run)
    end)

    assert :ok = Correlation.persist(namespace, bindings, first)

    assert {:error, :ambiguous} =
             Correlation.lookup(namespace, {:slack_event_id, event_id})

    assert {:error, :not_found} =
             Correlation.lookup(namespace <> "-foreign", {:slack_event_id, event_id})

    assert :ok = S3.Fake.reset_read_log()

    assert {:ok,
            %{
              "runs" => [^first],
              "limit" => 1,
              "truncated" => true
            }} =
             Correlation.lookup_window(
               namespace,
               {:created_between, first["created_at"], second["created_at"]},
               limit: 1
             )

    assert [{:list, time_prefix, opts} | _reads] = S3.Fake.read_log(self())
    assert time_prefix == SalixStore.TriageKeys.ctl_im_triage_run_time_index_prefix(namespace)
    assert opts[:max_keys] == 2
    assert is_binary(opts[:start_after])

    {:ok, %{objects: correlation_objects}} =
      S3.list("ctl/im_triage/", max_keys: 100)

    stored =
      Enum.map_join(correlation_objects, "\n", fn %{key: key} ->
        case CasRecord.get(key) do
          {:ok, record} -> key <> Jason.encode!(record)
          {:error, _reason} -> key
        end
      end)

    refute stored =~ event_id
    refute stored =~ receipt_ref
    refute stored =~ "C_PRIVATE"
  end

  defp public_run(created_at) do
    %{
      "schema" => "comma.triage-run.v2",
      "run_id" => ULID.generate(),
      "bucket" => "bucket://run/scope",
      "generation" => ULID.generate(),
      "authoritative" => true,
      "created_at" => created_at,
      "status" => "evaluated",
      "input_receipt_refs" => ["receipt://run/r001"],
      "input_snapshot" => %{"schema" => "comma.triage-model-input.v3"},
      "input_snapshot_sha256" => String.duplicate("a", 64),
      "decision" => %{"action" => "silence"},
      "evaluator" => %{}
    }
  end

  defp persist_public_run(namespace, run) do
    run_key = SalixStore.TriageKeys.ctl_im_triage_ledger_run(namespace, run["run_id"])
    assert {:ok, ^run} = CasRecord.create(run_key, run)

    replay = %{
      "schema" => "comma.triage-replay.v1",
      "run_id" => run["run_id"],
      "ledger_ref" => "ledger://run/authoritative",
      "run_sha256" => run |> Jason.encode!() |> CanonicalJSON.sha256()
    }

    assert {:ok, ^replay} =
             CasRecord.create(
               SalixStore.TriageKeys.ctl_im_triage_replay(namespace, run["run_id"]),
               replay
             )
  end
end
