defmodule Comma.Phase4OperationsFoundationTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.Comma"]
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

    stale_at = DateTime.add(SystemsClock.utc_now(), -600, :second)

    Comma.Repo.update_all(
      from(operation in ExternalOperation,
        where: operation.operation_id == ^operation_id
      ),
      set: [updated_at: stale_at]
    )

    assert {:ok, {:execute, recovered}} = Comma.Operations.claim(operation_id, 1)
    assert recovered.attempt == 2

    next_attempt_at = DateTime.add(SystemsClock.utc_now(), 60, :second)

    assert {:ok, {:updated, retryable}} =
             Comma.Operations.retryable(operation_id, 1, "provider_unavailable", next_attempt_at)

    assert retryable.status == "retryable"
    assert retryable.last_error_class == "provider_unavailable"
    assert {:error, :not_due} = Comma.Operations.claim(operation_id, 1)

    Comma.Repo.update_all(
      from(operation in ExternalOperation,
        where: operation.operation_id == ^operation_id
      ),
      set: [next_attempt_at: DateTime.add(SystemsClock.utc_now(), -1, :second)]
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
    SystemsRuntime.Proc.unlink(repo_a)
    SystemsRuntime.Proc.unlink(repo_b)

    on_exit(fn ->
      for repo <- [repo_a, repo_b], SystemsRuntime.Proc.alive?(repo), do: Supervisor.stop(repo)
    end)

    {repo_a, repo_b}
  end

  defp concurrent(repo_a, repo_b, fun) do
    parent = SystemsRuntime.Proc.self()
    ref = SystemsRuntime.Proc.make_ref()

    tasks =
      for repo <- [repo_a, repo_b] do
        SystemsRuntime.Task.async(fn ->
          SystemsRuntime.Proc.send(parent, {ref, :ready, SystemsRuntime.Proc.self()})
          SystemsRuntime.Proc.receive(do: ({^ref, :go} -> on_repo(repo, fun)))
        end)
      end

    for task <- tasks, do: settle_receive({^ref, :ready, pid} when pid == task.pid)
    for task <- tasks, do: SystemsRuntime.Proc.send(task.pid, {ref, :go})
    Enum.map(tasks, &settled_await/1)
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
    do: prefix <> "_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(9), padding: false)
end
