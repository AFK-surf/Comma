defmodule Comma.Analytics do
  @moduledoc """
  Comma product analytics. Email belongs only to server-owned person properties.

  `comma_user_registered` observes new accounts at their canonical creation time.
  It names the signup client (`client_kind`, `client_platform`) when the
  sign-in request reported one. Admin-created and self-host accounts have none.
  Profile sweeps and login refreshes do not resend registration events.
  `comma_workspace_ready` observes successful first-generation convergence.
  `comma_user_message_committed` observes newly inserted Messages through Comma.
  Capture precedes the response read. Direct provider ingress and lost append
  responses are not covered. Duplicate appends produce no second observation.
  `comma_task_review_accepted` names the accepted review version.
  `comma_task_created` observes Task input with a Comma Workspace. It is Agent
  activity attributed to the Workspace owner, never proof of human engagement.
  It names where the Task runs (`task_kind`: coding, sandbox, station or cloud)
  and the runtime and model it asked for, never its title, command or repository.
  `comma_task_ended` observes an owned Task reaching completed, cancelled or failed
  (`CommaWeb.TaskEndedAnalytics`), with its duration and, for a sandbox Task, the
  token use, change totals and pull request state its sandbox last reported.
  `comma_integration_connected` observes tracked plugin OAuth commits. Other
  connection mechanisms are outside that event's coverage.

  Engaged-user metrics count committed human Messages and accepted reviews.
  Profile updates, imports, background Tasks, and app opens are not engagement.
  Activation joins the first committed Message to a client's visible reply using
  `message_id` and `source_message_id`. Count distinct source Messages across
  windows. Historical reply visibility cannot be reconstructed by this exporter.
  """

  alias Comma.Accounts.SessionClientMetadata
  alias Comma.Analytics.Worker

  @events ~w(comma_workspace_ready comma_user_message_committed comma_task_review_accepted comma_integration_connected comma_task_created comma_task_ended)
  @properties ~w(workspace_id conversation_id message_id conversation_kind initiator_kind integration
                 task_kind runtime model mini_app status duration_ms model_calls input_tokens
                 cached_tokens output_tokens files_changed lines_added lines_deleted pull_request_state)
  @counts ~w(duration_ms model_calls input_tokens cached_tokens output_tokens files_changed lines_added lines_deleted)

  def excluded_user_ids(value), do: value |> List.wrap() |> Enum.filter(&is_binary/1)

  def internal_user?(email) when is_binary(email) do
    domain = email |> String.downcase() |> String.split("@") |> List.last()

    config()
    |> Keyword.get(:internal_email_domains, ~w(cue.surf comma.surf))
    |> List.wrap()
    |> Enum.any?(fn
      candidate when is_binary(candidate) ->
        String.downcase(String.trim(candidate)) == domain

      _ ->
        false
    end)
  end

  def internal_user?(_email), do: false

  def config, do: SystemsRuntime.get_env(:comma_core, :analytics, [])

  def configured? do
    is_binary(config()[:api_key]) and
      config()[:api_key] != "" and is_binary(config()[:host]) and config()[:host] != ""
  end

  def children, do: if(configured?(), do: [Worker], else: [])

  # Capture performs no DB, network, mailbox send, or telemetry handler call.
  # A missing worker, malformed observation, or full buffer never changes the operation.
  def capture(user_id, event, source_id, properties, occurred_at \\ SystemsClock.utc_now()) do
    if configured?() and not Process.get(:comma_analytics_suppressed, false) and
         event in @events and valid_id?(user_id) and valid_id?(source_id) do
      properties = allowed_properties(properties)

      Worker.enqueue(%{
        user_id: user_id,
        event: event,
        source_id: source_id,
        properties: properties,
        occurred_at: occurred_at
      })
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Task creation is Agent activity. Resolve its Comma Workspace off the owner path.
  # `placement` is the Task's `runs_on`, `repo`, `mini_app` and `session_model`;
  # only their kinds leave this function.
  def task_created(group_id, conversation_id, created_at, placement \\ %{}) do
    if configured?() and not Process.get(:comma_analytics_suppressed, false) and
         valid_id?(group_id) and valid_id?(conversation_id) do
      Worker.enqueue(%{
        event: "comma_task_created",
        user_id: nil,
        group_id: group_id,
        source_id: conversation_id,
        occurred_at: DateTime.from_unix!(created_at, :millisecond),
        properties:
          placement
          |> placement_properties()
          |> Map.merge(%{"conversation_id" => conversation_id, "initiator_kind" => "agent"})
          |> allowed_properties()
      })
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Observes a new account. `client` is the sign-in request: only the client kind
  and OS it reported for its Session (`SessionClientMetadata`) leave it, so a
  signup without first-touch attribution still names the app it came from.
  """
  def registered(user_id, client \\ %{}), do: identify(user_id, :registration, client)

  def identify(user_id), do: identify(user_id, :profile, %{})

  defp identify(user_id, event, client) do
    if configured?() and not Process.get(:comma_analytics_suppressed, false) and
         valid_id?(user_id),
       do:
         Worker.enqueue(%{
           user_id: user_id,
           event: event,
           properties: SessionClientMetadata.attributes(client)
         })

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def message_committed(user, workspace, binding, %{"inserted" => true} = result) do
    capture(user["id"], "comma_user_message_committed", result["message_id"], %{
      "workspace_id" => workspace["id"],
      "conversation_id" => binding["id"],
      "message_id" => result["message_id"],
      "conversation_kind" => binding["kind"],
      "initiator_kind" => "human"
    })
  end

  def message_committed(_, _, _, _), do: :ok

  @doc """
  Where a Task runs, from its `runs_on` and `repo`: `coding` (a sandbox with a
  repository), `sandbox`, `station` (a device's station) or `cloud` (inside Salix).
  """
  def task_kind(%{"runs_on" => %{"kind" => "sandbox"}, "repo" => %{}}), do: "coding"
  def task_kind(%{"runs_on" => %{"kind" => "sandbox"}}), do: "sandbox"
  def task_kind(%{"runs_on" => %{"device_id" => device}}) when is_binary(device), do: "station"
  def task_kind(_task), do: "cloud"

  defp placement_properties(placement) when is_map(placement) do
    %{"task_kind" => task_kind(placement), "mini_app" => is_map(placement["mini_app"])}
    |> Map.merge(model_properties(placement["session_model"]))
  end

  defp placement_properties(_placement), do: %{}

  defp model_properties(%{"kind" => "runtime", "provider" => provider} = choice),
    do: %{"runtime" => provider, "model" => choice["model"]}

  defp model_properties(%{"kind" => kind} = choice) when kind in ~w(catalog platform),
    do: %{"runtime" => "salix", "model" => choice["model"]}

  defp model_properties(_choice), do: %{"runtime" => "default"}

  defp allowed_properties(properties) do
    properties
    |> Map.take(@properties)
    |> Enum.filter(fn {key, value} -> valid_property?(key, value) end)
    |> Map.new()
  end

  defp valid_property?("message_id", value), do: SalixStore.Ids.valid_message_id?(value)
  defp valid_property?("conversation_id", value), do: SalixStore.Ids.valid_conversation_id?(value)

  defp valid_property?("workspace_id", value),
    do: is_binary(value) and Regex.match?(~r/^wsp_[A-Za-z0-9_-]{1,128}$/, value)

  defp valid_property?("initiator_kind", value), do: value in ~w(human agent system)
  defp valid_property?("conversation_kind", value), do: value in ~w(user_chat agent_task)
  defp valid_property?("integration", value), do: value == "plugin"
  defp valid_property?("task_kind", value), do: value in ~w(coding sandbox station cloud)
  defp valid_property?("runtime", value), do: value in ~w(claude codex salix default)
  defp valid_property?("mini_app", value), do: is_boolean(value)
  defp valid_property?("status", value), do: value in ~w(completed cancelled failed)

  defp valid_property?("pull_request_state", value),
    do: value in ~w(none open draft closed merged)

  # A model id names a catalog or runtime model, never user text.
  defp valid_property?("model", value),
    do: is_binary(value) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._:\/@-]{0,127}$/, value)

  defp valid_property?(key, value) when key in @counts, do: is_integer(value) and value >= 0

  defp valid_id?(value), do: is_binary(value) and byte_size(value) in 1..256
end
