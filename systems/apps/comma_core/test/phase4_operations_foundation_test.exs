defmodule Comma.Phase4OperationsFoundationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Comma.Data.ExternalOperation

  defmodule Worker do
    use Oban.Worker,
      queue: :comma_external,
      max_attempts: 5,
      unique: [period: 300, fields: [:worker, :queue, :args]]

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"operation_id" => _operation_id}}), do: :ok
  end

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Comma.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  test "operation and operation-id-only job commit atomically" do
    attrs = operation_attrs(1)
    operation_id = attrs.operation_id

    assert {:ok, %{comma_operation_row: operation, comma_operation_job: job}} =
             Comma.Operations.create_with_job(
               attrs,
               Worker.new(%{"operation_id" => operation_id})
             )

    assert operation.operation_id == operation_id
    assert job.args == %{"operation_id" => operation_id}
    assert job.queue == "comma_external"
    assert Comma.Repo.get!(ExternalOperation, operation_id).status == "pending"

    assert_raise ArgumentError, ~r/only operation_id/, fn ->
      Comma.Operations.create_with_job(
        operation_attrs(2),
        Worker.new(%{"operation_id" => unique("wrong"), "payload" => "must-not-persist"})
      )
    end

    conflicting_attrs =
      operation_attrs(1)
      |> Map.put(:external_idempotency_key, attrs.external_idempotency_key)

    assert {:error, :comma_operation_row, :operation_identity_conflict, _changes} =
             Comma.Operations.create_with_job(
               conflicting_attrs,
               Worker.new(%{"operation_id" => conflicting_attrs.operation_id})
             )
  end

  test "six-state reducer recovers an orphan and preserves terminal evidence" do
    attrs = operation_attrs(1)
    operation_id = attrs.operation_id
    insert_operation!(attrs)

    assert {:ok, {:execute, executing}} = Comma.Operations.claim(operation_id, 1)
    assert executing.status == "executing"
    assert executing.attempt == 1
    assert {:error, :not_due} = Comma.Operations.claim(operation_id, 1)

    stale_at = DateTime.add(DateTime.utc_now(), -600, :second)

    Comma.Repo.update_all(
      from(operation in ExternalOperation,
        where: operation.operation_id == ^operation_id
      ),
      set: [updated_at: stale_at]
    )

    assert {:ok, {:execute, recovered}} = Comma.Operations.claim(operation_id, 1)
    assert recovered.attempt == 2

    next_attempt_at = DateTime.add(DateTime.utc_now(), 60, :second)

    assert {:ok, {:updated, retryable}} =
             Comma.Operations.retryable(operation_id, 1, "provider_unavailable", next_attempt_at)

    assert retryable.status == "retryable"
    assert retryable.last_error_class == "provider_unavailable"
    assert {:error, :not_due} = Comma.Operations.claim(operation_id, 1)

    Comma.Repo.update_all(
      from(operation in ExternalOperation,
        where: operation.operation_id == ^operation_id
      ),
      set: [next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:ok, {:execute, final_attempt}} = Comma.Operations.claim(operation_id, 1)
    assert final_attempt.attempt == 3

    assert {:ok, {:updated, succeeded}} =
             Comma.Operations.succeed(operation_id, 1, "salix-conversation-123", %{
               "provider_status" => "ready"
             })

    assert succeeded.status == "succeeded"
    assert succeeded.finished_at
    assert succeeded.external_identity == "salix-conversation-123"
    assert succeeded.metadata["terminal_evidence"] == %{"provider_status" => "ready"}

    assert {:ok, {:complete, repeated}} =
             Comma.Operations.succeed(operation_id, 1, "different", %{
               "provider_status" => "must-not-replace"
             })

    assert repeated.external_identity == "salix-conversation-123"
    assert repeated.metadata == succeeded.metadata
    assert repeated.finished_at == succeeded.finished_at

    terminal_attrs = operation_attrs(1)
    terminal_id = terminal_attrs.operation_id
    insert_operation!(terminal_attrs)
    assert {:ok, {:execute, _}} = Comma.Operations.claim(terminal_id, 1)

    assert {:ok, {:updated, terminal}} =
             Comma.Operations.terminal_failed(terminal_id, 1, "invalid_owner", %{
               "provider_status" => "rejected"
             })

    assert terminal.status == "terminal_failed"
    assert terminal.last_error_class == "invalid_owner"
    assert terminal.finished_at
  end

  test "desired generation supersedes stale operation before any external call" do
    attrs = operation_attrs(1)
    insert_operation!(attrs)

    assert {:ok, {:superseded, stale}} = Comma.Operations.claim(attrs.operation_id, 2)
    assert stale.status == "superseded"
    assert stale.finished_at
    assert {:ok, {:complete, same}} = Comma.Operations.claim(attrs.operation_id, 1)
    assert same.status == "superseded"
  end

  test "lower generation arriving after current generation cannot execute" do
    owner_id = unique("owner")
    current_attrs = operation_attrs(2, owner_id)
    stale_attrs = operation_attrs(1, owner_id)
    insert_operation!(current_attrs)
    insert_operation!(stale_attrs)

    assert Comma.Repo.get!(ExternalOperation, stale_attrs.operation_id).status == "pending"

    assert {:ok, {:superseded, stale}} =
             Comma.Operations.claim(stale_attrs.operation_id, current_attrs.generation)

    assert stale.status == "superseded"
    assert stale.finished_at
    assert Comma.Repo.get!(ExternalOperation, current_attrs.operation_id).status == "pending"
  end

  test "two independent Repo clients allow only one fresh claim" do
    attrs = operation_attrs(1)
    {repo_a, repo_b} = start_independent_repos()
    on_repo(repo_a, fn -> insert_operation!(attrs) end)

    results =
      concurrent(repo_a, repo_b, fn ->
        Comma.Operations.claim(attrs.operation_id, 1)
      end)

    assert Enum.count(results, &match?({:ok, {:execute, _}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :not_due})) == 1

    operation = on_repo(repo_a, fn -> Comma.Repo.get!(ExternalOperation, attrs.operation_id) end)
    assert operation.status == "executing"
    assert operation.attempt == 1
  end

  test "two Repo clients converge a repeated stable generation and only one may claim" do
    attrs = operation_attrs(1)
    {repo_a, repo_b} = start_independent_repos()
    job_changeset = fn -> Worker.new(%{"operation_id" => attrs.operation_id}) end

    create_results =
      concurrent(repo_a, repo_b, fn ->
        Comma.Operations.create_with_job(attrs, job_changeset.())
      end)

    assert Enum.all?(create_results, &match?({:ok, _}, &1))

    operation_ids =
      Enum.map(create_results, fn {:ok, changes} ->
        changes.comma_operation_row.operation_id
      end)

    assert Enum.uniq(operation_ids) == [attrs.operation_id]

    claim_results =
      concurrent(repo_a, repo_b, fn ->
        Comma.Operations.claim(attrs.operation_id, 1)
      end)

    assert Enum.count(claim_results, &match?({:ok, {:execute, _}}, &1)) == 1
    assert Enum.count(claim_results, &(&1 == {:error, :not_due})) == 1
  end

  test "new generation atomically supersedes older active generation" do
    owner_id = unique("owner")
    old_attrs = operation_attrs(1, owner_id)
    new_attrs = operation_attrs(2, owner_id)
    insert_operation!(old_attrs)

    assert {:ok, %{comma_operation_row: current, comma_superseded_operations: 1}} =
             Comma.Operations.create_with_job(
               new_attrs,
               Worker.new(%{"operation_id" => new_attrs.operation_id})
             )

    assert current.generation == 2
    assert Comma.Repo.get!(ExternalOperation, old_attrs.operation_id).status == "superseded"
    assert Comma.Repo.get!(ExternalOperation, old_attrs.operation_id).finished_at
  end

  test "Oban telemetry exports only bounded queue and state dimensions" do
    handler_id = "phase4-telemetry-#{unique("handler")}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:comma, :oban, :job, :exception],
        fn event, measurements, metadata, _ ->
          send(parent, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Comma.ObanTelemetry.handle_event(
      [:oban, :job, :exception],
      %{duration: 10, queue_time: 2, memory: 999},
      %{
        conf: %{name: Comma.Oban},
        job: %Oban.Job{queue: "unbounded-user-input"},
        state: :failure,
        reason: "must not be exported"
      },
      nil
    )

    assert_receive {
      [:comma, :oban, :job, :exception],
      %{duration: 10, queue_time: 2},
      %{queue: "other", state: "failure"}
    }
  end

  test "worker errors handed to Oban are bounded low-cardinality classes" do
    missing_operation_id = unique("missing-operation")

    assert {:ok, job} =
             Oban.insert(
               Comma.Oban,
               Comma.Workers.WorkspaceConvergence.new(
                 %{
                   "operation_id" => missing_operation_id
                 },
                 queue: :comma_error_test,
                 priority: 0
               )
             )

    drain_result =
      Oban.drain_queue(
        Comma.Oban,
        queue: :comma_error_test,
        with_limit: 1
      )

    assert drain_result.failure == 1

    persisted = Comma.Repo.get!(Oban.Job, job.id)
    assert [%{"error" => oban_error}] = persisted.errors
    assert byte_size(oban_error) <= 160
    refute String.contains?(oban_error, missing_operation_id)
  end

  test "retry, terminal failure, and bounded queue backlog are emitted into a real scrape" do
    reporter = Module.concat(__MODULE__, BacklogReporter)

    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: reporter,
       metrics: SystemsObservability.Metrics.enabled_metrics([:comma_product]),
       start_async: false}
    )

    retry_attrs = operation_attrs(1)
    insert_operation!(retry_attrs)
    assert {:ok, {:execute, _}} = Comma.Operations.claim(retry_attrs.operation_id, 1)

    assert {:ok, {:updated, _}} =
             Comma.Operations.retryable(
               retry_attrs.operation_id,
               1,
               "provider_unavailable",
               DateTime.add(DateTime.utc_now(), 60, :second)
             )

    terminal_attrs = operation_attrs(1)
    insert_operation!(terminal_attrs)
    assert {:ok, {:execute, _}} = Comma.Operations.claim(terminal_attrs.operation_id, 1)

    assert {:ok, {:updated, _}} =
             Comma.Operations.terminal_failed(
               terminal_attrs.operation_id,
               1,
               "invalid_owner"
             )

    assert :ok = Comma.ObanBacklogSampler.sample(Comma.Repo)

    scrape = TelemetryMetricsPrometheus.Core.scrape(reporter)

    assert scrape =~ ~s(comma_product_backlog_retries_total{queue="comma_external"} 1)

    assert scrape =~
             ~s(comma_product_backlog_terminal_failures_total{queue="comma_external"} 1)

    assert scrape =~ ~s(comma_product_backlog_depth{queue="comma_external"})
    assert scrape =~ ~s(comma_product_backlog_oldest_age_seconds{queue="comma_external"})
    refute scrape =~ retry_attrs.operation_id
    refute scrape =~ terminal_attrs.operation_id
  end

  defp insert_operation!(attrs) do
    assert {:ok, _changes} =
             Comma.Operations.create_with_job(
               attrs,
               Worker.new(%{"operation_id" => attrs.operation_id})
             )
  end

  defp operation_attrs(generation, owner_id \\ nil) do
    owner_id = owner_id || unique("owner")
    operation_id = unique("operation")

    %{
      operation_id: operation_id,
      operation_type: "workspace_provisioning",
      owner_type: "workspace",
      owner_id: owner_id,
      generation: generation,
      status: "pending",
      attempt: 0,
      external_idempotency_key: "#{owner_id}:#{generation}",
      metadata: %{}
    }
  end

  defp start_independent_repos do
    opts = [name: nil, pool: DBConnection.ConnectionPool, pool_size: 1]
    {:ok, repo_a} = Comma.Repo.start_link(opts)
    {:ok, repo_b} = Comma.Repo.start_link(opts)
    Process.unlink(repo_a)
    Process.unlink(repo_b)

    on_exit(fn ->
      for repo <- [repo_a, repo_b], Process.alive?(repo), do: Supervisor.stop(repo)
    end)

    {repo_a, repo_b}
  end

  defp concurrent(repo_a, repo_b, fun) do
    parent = self()
    ref = make_ref()

    tasks =
      for repo <- [repo_a, repo_b] do
        Task.async(fn ->
          send(parent, {ref, :ready, self()})
          receive do: ({^ref, :go} -> on_repo(repo, fun))
        end)
      end

    for task <- tasks, do: assert_receive({^ref, :ready, pid} when pid == task.pid)
    for task <- tasks, do: send(task.pid, {ref, :go})
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp on_repo(repo, fun) do
    previous = Comma.Repo.get_dynamic_repo()
    Comma.Repo.put_dynamic_repo(repo)

    try do
      fun.()
    after
      Comma.Repo.put_dynamic_repo(previous)
    end
  end

  defp unique(prefix),
    do: prefix <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
