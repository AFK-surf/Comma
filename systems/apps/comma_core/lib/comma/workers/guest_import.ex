defmodule Comma.Workers.GuestImport do
  @moduledoc """
  Imports a guest's Router chat into the signed-up account's Router chat.

  The worker renders the guest chat's user and assistant text as a Markdown
  transcript, writes it to a fixed path in the account Router's files, and
  sends one ordinary user message that attaches it. The message wakes the
  account's Router, which continues the conversation.

  The operation row owns claim, retry and terminal failure. A retry writes the
  same path and sends the same `client_request_id` and text, so the Salix
  Conversation keeps one import message.
  """

  use Oban.Worker,
    queue: :comma_external,
    max_attempts: 12,
    unique: [period: :infinity, fields: [:worker, :queue, :args]]

  import Ecto.Query

  require Logger

  alias Comma.Data.{ExternalOperation, Workspace}
  alias Comma.{Accounts, AssistantChats, Conversations, Operations, Repo, WorkspaceBootstrap}

  @page_limit 200
  @max_messages 2_000
  @max_transcript_bytes 9_000_000
  @generation 1

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"operation_id" => operation_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case run(operation_id, final_attempt?: attempt >= max_attempts) do
      {:ok, _result} -> :ok
      {:busy, seconds} -> {:snooze, seconds}
      {:error, reason} -> {:error, "guest_import:" <> classify(reason)}
    end
  end

  @doc false
  def run(operation_id, opts \\ []) when is_binary(operation_id) do
    case Operations.claim(operation_id, @generation) do
      {:ok, {:execute, operation}} ->
        import_chat(operation, Keyword.get(opts, :final_attempt?, false))

      {:ok, {_complete, operation}} ->
        {:ok, operation}

      {:error, :not_due} ->
        {:busy, 1}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp import_chat(%ExternalOperation{} = operation, final_attempt?) do
    result =
      try do
        with {:ok, guest} <- Accounts.get_user(operation.owner_id),
             {:ok, target} <- Accounts.get_user(operation.metadata["target_user_id"]),
             {:ok, messages} <- guest_messages(guest),
             {:ok, target_workspace} <- ready_workspace(target["id"]) do
          deliver(operation, target, target_workspace, messages)
        end
      rescue
        exception ->
          Logger.warning("Guest chat import failed", exception: inspect(exception.__struct__))
          {:error, {:provider_exception, exception.__struct__}}
      end

    case result do
      {:ok, evidence} -> succeed(operation, evidence)
      {:busy, seconds} -> retry(operation, "target_workspace_provisioning", seconds, {:busy, seconds})
      {:error, reason} -> fail(operation, reason, final_attempt?)
    end
  end

  defp deliver(_operation, _target, _workspace, []), do: {:ok, %{"messages" => 0}}

  defp deliver(operation, target, workspace, messages) do
    {transcript, count} = render(messages)
    path = "/uploads/guest-chat-#{operation.operation_id}.md"
    session = %{"restricted" => false}

    with {:ok, _file} <- Comma.Salix.Client.impl().write_agent_file(workspace, path, transcript),
         {:ok, chat} <- AssistantChats.ensure_chat(target, session, workspace["default_group_id"]),
         {:ok, _conversation} <-
           Conversations.send_message(target, session, workspace["default_group_id"], chat["id"], %{
             "client_request_id" => "guest-import:" <> operation.operation_id,
             "text" => message_text(path)
           }) do
      {:ok, %{"messages" => count}}
    end
  end

  # The attachment marker is the existing user-upload reference format.
  defp message_text(path) do
    """
    I started this conversation in guest mode before signing up. The transcript is attached. Please read it and continue where we left off.

    Attached files in your workspace:
    - guest-chat.md (workspace file: #{path})\
    """
  end

  defp guest_messages(guest) do
    case guest_workspace(guest["id"]) do
      nil ->
        {:ok, []}

      workspace ->
        session = %{"restricted" => false}

        with {:ok, chat} <- AssistantChats.ensure_chat(guest, session, workspace.salix_group_id) do
          collect(guest, session, workspace.salix_group_id, chat["id"], [], nil)
        end
    end
  end

  # Newest pages first; the transcript keeps the newest messages within bounds.
  defp collect(guest, session, group_id, chat_id, acc, before) do
    opts = if before, do: [before: before, limit: @page_limit], else: [limit: @page_limit]

    with {:ok, page} <- Conversations.message_page(guest, session, group_id, chat_id, opts) do
      acc = Enum.flat_map(page["messages"] || [], &Comma.TaskShares.public_message/1) ++ acc

      case page do
        %{"has_older" => true, "covered" => %{"first_seq" => first_seq}}
        when length(acc) < @max_messages ->
          collect(guest, session, group_id, chat_id, acc, first_seq)

        _last ->
          {:ok, Enum.take(acc, -@max_messages)}
      end
    end
  end

  defp guest_workspace(guest_id) do
    Repo.one(
      from(workspace in Workspace,
        where:
          workspace.owner_user_id == ^guest_id and workspace.kind == "guest" and
            workspace.status == "active",
        limit: 1
      )
    )
  end

  defp ready_workspace(user_id) do
    case WorkspaceBootstrap.ensure_default(user_id) do
      {:ok, %{"status" => "ready", "workspace" => %{"id" => id}}} -> Comma.Workspaces.get(id)
      {:ok, %{"status" => "provisioning", "retry_after_seconds" => seconds}} -> {:busy, seconds}
      {:error, _reason} = error -> error
    end
  end

  defp render(messages) do
    sections =
      messages
      |> Enum.map(&render_message/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn section, {kept, bytes} ->
        size = byte_size(section) + 2

        if bytes + size > @max_transcript_bytes,
          do: {:halt, {kept, bytes}},
          else: {:cont, {[section | kept], bytes + size}}
      end)
      |> elem(0)

    omitted = length(messages) - length(sections)

    header =
      "# Guest chat transcript\n\n" <>
        if(omitted > 0, do: "_#{omitted} older messages were omitted._\n\n", else: "")

    {header <> Enum.join(sections, "\n\n") <> "\n", length(sections)}
  end

  defp render_message(%{"role" => role, "content" => blocks} = message) do
    body =
      blocks
      |> Enum.map(fn
        %{"type" => "text", "text" => text} -> text
        %{"name" => name} when is_binary(name) -> "[attachment: #{name}]"
        _other -> ""
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    if body == "" do
      ""
    else
      speaker = if role == "assistant", do: "Comma", else: "Me"
      "## #{speaker}#{timestamp(message["created_at"])}\n\n#{body}"
    end
  end

  # Salix Message timestamps are Unix milliseconds.
  defp timestamp(unix_ms) when is_integer(unix_ms) and unix_ms >= 0,
    do: " · " <> (unix_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601())

  defp timestamp(_created_at), do: ""

  defp succeed(operation, evidence) do
    case Operations.succeed(operation.operation_id, @generation, operation.owner_id, evidence) do
      {:ok, {_kind, succeeded}} -> {:ok, succeeded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry(operation, error_class, seconds, result) do
    next_attempt_at = DateTime.add(DateTime.utc_now(), seconds, :second)

    case Operations.retryable(operation.operation_id, @generation, error_class, next_attempt_at) do
      {:ok, _transition} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp fail(operation, reason, final_attempt?) do
    error_class = classify(reason)

    if final_attempt? or terminal?(reason) do
      case Operations.terminal_failed(operation.operation_id, @generation, error_class) do
        {:ok, _transition} -> {:error, reason}
        {:error, transition_reason} -> {:error, transition_reason}
      end
    else
      retry(operation, error_class, 30, {:error, reason})
    end
  end

  defp terminal?({:billing_unavailable, _decision}), do: true
  defp terminal?(reason), do: reason in [:not_found, :forbidden, :disabled, :workspace_invariant]

  defp classify({:provider_exception, _module}), do: "provider_exception"
  defp classify({:bad_request, _message}), do: "bad_request"
  defp classify({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  defp classify(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp classify(_reason), do: "unknown"
end
