defmodule CommaWeb.TaskEndedAnalytics do
  @moduledoc """
  `comma_task_ended`: an owned Task of a Comma Workspace reached completed,
  cancelled or failed.

  Salix publishes a status again, with the same status version, after later
  Messages of the Task, so one job is kept per Task and version (while Oban
  keeps the job: a day) and the event's id names both. The job runs a minute
  after the status, so the token use and change totals read when the last turn
  ended (`SalixWeb.CodingSandboxes.turn_ended/2`) are kept by then; the event
  says what the sandbox reported last. The Task ended when its first job was
  queued (`ended_at`).

  The event carries the Task's kind, status, duration from its creation, and,
  for a sandbox Task, its model calls, tokens, model, change totals and pull
  request state. Never its title, Messages, repository, branch or pull request.
  """
  use Oban.Worker,
    queue: :comma_analytics,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:group_id, :task_id, :version],
      states: [:available, :scheduled, :executing, :retryable, :suspended, :completed]
    ]

  import Ecto.Query
  alias Comma.{Analytics, Repo}
  alias Comma.Data.Workspace

  @ended ~w(completed cancelled failed)
  @settle_s 60

  @doc "Queues the Task's event when its status ended it. Never fails the status publication."
  def observe(
        %{
          "agent_group_id" => group,
          "conversation_id" => task,
          "owner_user_id" => owner,
          "status" => status
        } = snapshot
      )
      when status in @ended and is_binary(group) and is_binary(task) and is_binary(owner) do
    if Analytics.configured?() do
      %{
        "group_id" => group,
        "task_id" => task,
        "owner_user_id" => owner,
        "status" => status,
        "version" => snapshot["provider_status_version"] || 0,
        "task_kind" => Analytics.task_kind(snapshot),
        "created_at" => snapshot["created_at"],
        "ended_at" => SystemsClock.system_time(:millisecond)
      }
      |> new(schedule_in: @settle_s)
      |> then(&Oban.insert(Comma.Oban, &1))
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def observe(_snapshot), do: :ok

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ended_at" => ended_at} = args}) do
    with true <- Analytics.configured?(),
         %Workspace{} = workspace <- workspace(args["group_id"]) do
      Analytics.capture(
        args["owner_user_id"],
        "comma_task_ended",
        "#{args["task_id"]}:#{args["version"]}",
        %{
          "workspace_id" => workspace.id,
          "conversation_id" => args["task_id"],
          "status" => args["status"],
          "task_kind" => args["task_kind"],
          "duration_ms" => duration_ms(args["created_at"], ended_at)
        }
        |> Map.merge(sandbox_properties(workspace, args)),
        DateTime.from_unix!(ended_at, :millisecond)
      )
    end

    :ok
  end

  # Only a standard Comma Workspace's current Group: other products' Tasks are not Comma's.
  defp workspace(group) when is_binary(group),
    do:
      Repo.one(
        from(w in Workspace,
          where: w.salix_group_id == ^group and w.kind == "standard",
          limit: 1
        )
      )

  defp workspace(_group), do: nil

  defp duration_ms(created_at, ended_at) when is_integer(created_at),
    do: ended_at - created_at

  defp duration_ms(_created_at, _ended_at), do: nil

  defp sandbox_properties(workspace, %{"task_kind" => kind, "task_id" => task})
       when kind in ~w(coding sandbox) do
    case SalixStore.CodingSandboxes.get_by_conversation(workspace.salix_tenant_id, task) do
      {:ok, workload} -> facts_properties(workload.spec["facts"] || %{}, kind)
      _none -> %{}
    end
  end

  defp sandbox_properties(_workspace, _args), do: %{}

  # `facts` holds each part as `%{"at" => ..., "value" => ...}` (`SalixWeb.CodingSandboxes.remember/4`).
  defp facts_properties(facts, kind) do
    usage = get_in(facts, ["usage", "value"]) || %{}
    changes = get_in(facts, ["changes", "value"]) || %{}

    %{
      "model_calls" => usage["modelCalls"],
      "input_tokens" => usage["inputTokens"],
      "cached_tokens" => usage["cachedTokens"],
      "output_tokens" => usage["outputTokens"],
      "model" => usage["model"],
      "files_changed" => changes["files"],
      "lines_added" => changes["additions"],
      "lines_deleted" => changes["deletions"]
    }
    |> Map.merge(pull_request_property(facts, kind))
  end

  defp pull_request_property(%{"pull_request" => %{"value" => nil}}, "coding"),
    do: %{"pull_request_state" => "none"}

  defp pull_request_property(%{"pull_request" => %{"value" => %{"state" => state}}}, "coding"),
    do: %{"pull_request_state" => state}

  defp pull_request_property(_facts, _kind), do: %{}
end
