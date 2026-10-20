defmodule SalixStore.ConvergenceTest do
  @moduledoc """
  The generic derived-storage convergence engine: paged/bounded passes with
  a durable resumable cursor, fail-closed record handling, monotonic
  converged? gating, page-batch mode, and honest telemetry on every
  attempt's true final outcome.
  """
  use SystemsClock.Case, async: false

  use SystemsClock.Test, scope: ["Elixir.SalixStore"]
  alias SalixStore.{CasDirectory, Convergence, S3}

  @source "ctl/test_convergence_source/"
  @marker "ctl/test_convergence_marker.json"
  @dir "ctl/test_convergence_dir.json"

  defmodule PerRecord do
    @behaviour SalixStore.Convergence

    @impl true
    def name, do: "test_per_record"
    @impl true
    def source_prefix, do: "ctl/test_convergence_source/"
    @impl true
    def marker_key, do: "ctl/test_convergence_marker.json"
    @impl true
    def reconcile_ms, do: :timer.hours(1)

    @impl true
    def converge_record(key) do
      case SalixStore.S3.get(key) do
        {:ok, %{body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"id" => id} = rec} ->
              # The changed/verified split the engine's converged count
              # relies on: an already-correct entry reports :unchanged.
              case CasDirectory.get("ctl/test_convergence_dir.json", id) do
                {:ok, ^rec} ->
                  :unchanged

                _ ->
                  case CasDirectory.put("ctl/test_convergence_dir.json", id, rec) do
                    {:ok, _} -> :changed
                    {:error, reason} -> {:error, reason}
                  end
              end

            {:ok, _} ->
              :skip

            {:error, reason} ->
              {:error, reason}
          end

        {:error, :not_found} ->
          :skip

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defmodule PerPage do
    @behaviour SalixStore.Convergence

    @impl true
    def name, do: "test_per_page"
    @impl true
    def source_prefix, do: "ctl/test_convergence_source/"
    @impl true
    def marker_key, do: "ctl/test_convergence_marker.json"

    @impl true
    def converge_page(keys) do
      with {:ok, recs} <- read_all(keys),
           {:ok, changed} <-
             CasDirectory.transact(
               "ctl/test_convergence_dir.json",
               fn entries ->
                 {next, changed} =
                   Enum.reduce(recs, {entries, 0}, fn rec, {acc, n} ->
                     case Map.get(acc, rec["id"]) do
                       ^rec -> {acc, n}
                       _ -> {Map.put(acc, rec["id"], rec), n + 1}
                     end
                   end)

                 {:commit, next, changed}
               end,
               materialize: true
             ) do
        {:ok,
         %{
           converged: changed,
           unchanged: length(recs) - changed,
           skipped: length(keys) - length(recs)
         }}
      end
    end

    defp read_all(keys) do
      Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
        case SalixStore.S3.get(key) do
          {:ok, %{body: body}} ->
            case Jason.decode(body) do
              {:ok, %{"id" => _} = rec} -> {:cont, {:ok, [rec | acc]}}
              _ -> {:cont, {:ok, acc}}
            end

          {:error, :not_found} ->
            {:cont, {:ok, acc}}

          {:error, reason} ->
            {:halt, {:error, {:read_failed, key, reason}}}
        end
      end)
    end
  end

  setup do
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    Convergence.reset_converged_cache(PerRecord)
    Convergence.reset_converged_cache(PerPage)
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, prev) end)
    :ok
  end

  defp seed!(id, rec \\ nil) do
    {:ok, _} = S3.put(@source <> id <> ".json", Jason.encode!(rec || %{"id" => id}))
  end

  test "a pass is page-bounded, cursor-resumable, and durably converged" do
    for id <- ~w(a b c), do: seed!(id)

    assert {:ok, :partial} = Convergence.ensure(PerRecord, pages_per_run: 1, page_size: 1)
    refute Convergence.converged?(PerRecord)

    assert {:ok, %{body: marker}} = S3.get(@marker)
    assert %{"cursor" => cursor, "completed_ever" => false} = Jason.decode!(marker)
    assert is_binary(cursor) and cursor != ""

    assert {:ok, :partial} = Convergence.ensure(PerRecord, pages_per_run: 1, page_size: 1)
    assert {:ok, :complete} = Convergence.ensure(PerRecord, pages_per_run: 2, page_size: 1)
    assert Convergence.converged?(PerRecord)

    assert {:ok, entries} = CasDirectory.entries(@dir)
    assert Map.keys(entries) |> Enum.sort() == ~w(a b c)

    # Fresh marker → ensure is one GET, no scan, and it reports the
    # REMAINING deadline so schedulers can align to the durable cadence.
    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, :fresh, remaining} = Convergence.ensure(PerRecord)
    assert remaining > 0 and remaining <= :timer.hours(1)
    assert SalixStore.S3.Fake.read_log() == [{:get, @marker}]
  end

  test "an unreadable record fails the pass closed" do
    seed!("a")
    seed!("bad")
    SalixStore.S3.Fake.set_fault({:fail, 503, :get, @source <> "bad.json"})

    assert {:error, {:convergence_failed, "test_per_record", %{failed: 1}}} =
             Convergence.ensure(PerRecord)

    refute Convergence.converged?(PerRecord)

    assert {:ok, :complete} = Convergence.ensure(PerRecord)
    assert Convergence.converged?(PerRecord)
  end

  defmodule LegacyReturn do
    @behaviour SalixStore.Convergence

    @impl true
    def name, do: "test_legacy_return"
    @impl true
    def source_prefix, do: "ctl/test_convergence_source/"
    @impl true
    def marker_key, do: "ctl/test_convergence_marker.json"

    # The retired pre-changed/unchanged shape — malformed under the current
    # contract.
    @impl true
    def converge_record(_key), do: :ok
  end

  defmodule NegativePage do
    @behaviour SalixStore.Convergence

    @impl true
    def name, do: "test_negative_page"
    @impl true
    def source_prefix, do: "ctl/test_convergence_source/"
    @impl true
    def marker_key, do: "ctl/test_convergence_marker.json"

    @impl true
    def converge_page(_keys), do: {:ok, %{converged: -3, skipped: 0}}
  end

  defmodule WorkUnitsPage do
    @behaviour SalixStore.Convergence

    @impl true
    def name, do: "test_work_units_page"
    @impl true
    def source_prefix, do: "ctl/test_convergence_source/"
    @impl true
    def marker_key, do: "ctl/test_convergence_marker.json"

    # Implementation-defined work units: more units than the page has
    # records (e.g. one record fanning out into several directory
    # mutations plus verified slots).
    @impl true
    def converge_page(_keys), do: {:ok, %{converged: 7, unchanged: 5, skipped: 3}}
  end

  defmodule SlowPass do
    @behaviour SalixStore.Convergence

    @impl true
    def name, do: "test_slow_pass"
    @impl true
    def source_prefix, do: "ctl/test_convergence_source/"
    @impl true
    def marker_key, do: "ctl/test_convergence_marker.json"

    @impl true
    def converge_record(_key) do
      SystemsClock.sleep(150)
      :changed
    end
  end

  defmodule MarkerRace do
    @behaviour SalixStore.Convergence

    @impl true
    def name, do: "test_marker_race"
    @impl true
    def source_prefix, do: "ctl/test_convergence_source/"
    @impl true
    def marker_key, do: "ctl/test_convergence_marker.json"

    # While this pass processes record "b", a concurrent worker (simulated
    # inline) advances the shared marker — the exact slow-worker interleaving.
    @impl true
    def converge_record(key) do
      if String.ends_with?(key, "/b.json") do
        {:ok, _} =
          SalixStore.S3.put(
            "ctl/test_convergence_marker.json",
            Jason.encode!(%{"cursor" => "ctl/test_convergence_source/z.json"}),
            []
          )
      end

      :changed
    end
  end

  test "a superseded pass cannot overwrite a newer pass's cursor" do
    for id <- ~w(a b c d), do: seed!(id)

    # The pass's page-boundary cursor write is CAS-chained on the marker
    # state it observed; the concurrent write during record "b" invalidates
    # that chain, so this pass aborts instead of clobbering the newer cursor.
    assert {:error, {:superseded_pass, _}} =
             Convergence.ensure(MarkerRace, pages_per_run: 4, page_size: 2)

    assert {:ok, %{body: marker}} = S3.get(@marker)
    assert %{"cursor" => "ctl/test_convergence_source/z.json"} = Jason.decode!(marker)
  end

  test "a stale worker overwriting the progress marker cannot regress convergence" do
    seed!("a")
    assert {:ok, :complete} = Convergence.ensure(PerRecord)
    assert Convergence.converged?(PerRecord)

    # A slow worker resumes with a pre-completion view and clobbers the
    # mutable marker (cursor + completed_ever=false) — the cross-pod
    # overwrite. The create-once completed_ever object is untouched, so a
    # fresh process (no cached flag) still reports converged.
    {:ok, _} =
      S3.put(
        @marker,
        Jason.encode!(%{"cursor" => @source <> "somewhere", "completed_ever" => false})
      )

    Convergence.reset_converged_cache(PerRecord)
    assert Convergence.converged?(PerRecord)

    # The stale cursor merely finishes an idempotent pass on the next ensure.
    assert {:ok, :complete} = Convergence.ensure(PerRecord)
    assert Convergence.converged?(PerRecord)
  end
end
