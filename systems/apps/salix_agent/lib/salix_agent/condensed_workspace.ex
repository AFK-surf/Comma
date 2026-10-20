defmodule SalixAgent.CondensedWorkspace do
  @moduledoc """
  The Group's Condensed Workspace in the Agent runtime
  (docs/agent-runtime.md#condensed-workspace).

  `SalixStore.CondensedWorkspaces` owns the statements. This module owns what
  an internal Router or Worker Session sees of them:

    * the `condensed_workspace.update` tool;
    * the context provider that puts the latest content into every
      participating Session at its next round. Its state
      (`known["condensed_workspace"]`) is the revision the Session saw and the
      compaction boundary it saw it at. A new Session, a compacted Session and
      a Session behind the current revision receive the full content. The
      Session that made the latest write already holds that content in its
      tool result, so it adopts the revision without a message. When the
      Group flag goes off, a Session that saw content receives one notice.

  Nothing here wakes a Session. A Session that is idle when the content
  changes receives it when it next runs a round.
  """

  require Logger
  require SalixAgent.InternalSession

  alias SalixAgent.{GroupContext, InternalSession}
  alias SalixAgent.CondensedWorkspace.Suitability
  alias SalixStore.CondensedWorkspaces, as: Store

  @tool "condensed_workspace.update"
  @provider "condensed_workspace"

  def tool_name, do: @tool

  @description "Change this Group's Condensed Workspace: the short list of current facts that every Router and Worker Session of the Group keeps in context. " <>
                 "Add a statement when you learn a fact other Agents must know to do their work (a decision, an owner, a status, a constraint, where something lives). " <>
                 "Replace a statement when its fact changes and remove it when it is no longer true or useful. " <>
                 "Write each statement as one short, self-contained sentence. Keep the whole list under 4 KB; at 16 KB the runtime removes the statements at the end. " <>
                 "Operations apply in order and all together. replace and remove name a statement id such as s3 from the current list; if an id no longer exists, nothing changes and the result returns the current list. " <>
                 "A decision model checks new statements first and can reject the update as unsuitable; nothing changes then. If you judge the rejection wrong, repeat the same operations with force_override set to its rejection_id. " <>
                 "Other Sessions receive the new content at their next round; you do not need to tell them."

  def defs do
    [
      {@tool, @description, schema(), &__MODULE__.update/2,
       SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds(),
       [safety: "write", runtimes: [:internal]]}
    ]
  end

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["operations"],
      "properties" => %{
        "force_override" => %{
          "type" => "string",
          "description" =>
            "The rejection_id of an earlier rejection of exactly these operations. Applies them without the suitability check."
        },
        "operations" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => Store.max_operations(),
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["op"],
            "properties" => %{
              "op" => %{"type" => "string", "enum" => ["add", "replace", "remove"]},
              "id" => %{
                "type" => "string",
                "description" => "Statement id for replace and remove, for example s3."
              },
              "text" => %{
                "type" => "string",
                "description" =>
                  "Statement text for add and replace: one sentence, at most #{Store.max_statement_bytes()} bytes."
              }
            }
          }
        }
      }
    }
  end

  # ---- tool ----

  @doc false
  def update(args, ctx) when is_map(args) do
    with {:ok, group_id} <- participant_group(ctx),
         {:ok, operations} <- Store.normalize_operations(args["operations"]),
         :ok <- suitable(operations, args["force_override"], group_id, ctx),
         {:ok, workspace, removed} <-
           Store.apply_operations(group_id, operations, %{
             "kind" => "agent",
             "agent_id" => to_string(ctx[:agent_id]),
             "session_id" => to_string(ctx[:session_id])
           }) do
      Jason.encode!(
        %{
          "ok" => true,
          "revision" => workspace.revision,
          "bytes" => Store.rendered_bytes(workspace.statements),
          "recommended_max_bytes" => Store.recommended_bytes(),
          "content" => Store.render(workspace.statements)
        }
        |> put_removed(removed)
        |> put_size_advice(workspace.statements)
      )
    else
      {:error, {:conflict, missing, workspace}} ->
        Jason.encode!(%{
          "ok" => false,
          "error" => %{
            "code" => "unknown_statement",
            "message" =>
              "No statement has id #{Enum.join(missing, ", ")}. Nothing changed. Use the ids in content.",
            "missing_ids" => missing
          },
          "revision" => workspace.revision,
          "content" => Store.render(workspace.statements)
        })

      {:rejected, rejection_id, rejected} ->
        Jason.encode!(%{
          "ok" => false,
          "error" => %{
            "code" => "rejected",
            "message" =>
              "A decision model judged these statements unsuitable for the Condensed Workspace. Nothing changed. " <>
                "Keep only short, current facts that other Agents of this Group need. If you judge the rejection wrong, " <>
                "repeat the same operations with force_override set to rejection_id.",
            "rejection_id" => rejection_id,
            "rejected" => rejected
          }
        })

      {:error, :invalid_override} ->
        error(
          "invalid_override",
          "force_override does not match a rejection of exactly these operations. Nothing changed."
        )

      {:error, {:invalid, message}} ->
        error("invalid_request", message)

      {:error, :disabled} ->
        error("disabled", "The Condensed Workspace is disabled for this Group.")

      {:error, _reason} ->
        error("unavailable", "The Condensed Workspace is unavailable. Try again later.")
    end
  end

  def update(_args, _ctx), do: error("invalid_request", "arguments must be an object")

  # The Agent has the final decision: an override of the rejected operations
  # skips the check.
  defp suitable(operations, nil, group_id, ctx), do: Suitability.check(operations, group_id, ctx)

  defp suitable(operations, override, group_id, ctx) when is_binary(override) do
    if override == Suitability.rejection_id(operations, group_id, ctx),
      do: :ok,
      else: {:error, :invalid_override}
  end

  defp suitable(_operations, _override, _group_id, _ctx),
    do: {:error, {:invalid, "force_override must be a string"}}

  defp put_removed(result, []), do: result

  defp put_removed(result, removed) do
    result
    |> Map.put("removed_ids", removed)
    |> Map.put(
      "warning",
      "The list exceeded #{Store.hard_limit_bytes()} bytes, so the runtime removed #{Enum.join(removed, ", ")}. Condense the list."
    )
  end

  defp put_size_advice(result, statements) do
    if Map.has_key?(result, "warning") or
         Store.rendered_bytes(statements) <= Store.recommended_bytes(),
       do: result,
       else:
         Map.put(
           result,
           "warning",
           "The list is above the recommended #{Store.recommended_bytes()} bytes. Merge or remove statements."
         )
  end

  defp error(code, message),
    do: Jason.encode!(%{"ok" => false, "error" => %{"code" => code, "message" => message}})

  defp participant_group(ctx) do
    tenant_id = ctx[:tenant_id]
    group_id = ctx[:group_id]

    with true <- text?(tenant_id) and text?(group_id),
         true <- enabled?(group_id, tenant_id) do
      {:ok, group_id}
    else
      _ -> {:error, :disabled}
    end
  end

  @doc "Whether the Group flag is on. A read failure counts as off."
  def enabled?(group_id, tenant_id) do
    match?({:ok, %{"condensed_workspace_enabled" => true}}, GroupContext.get(group_id, tenant_id))
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # ---- context provider ----

  @doc """
  `{messages, state}` for the activation about to run. `known` is the
  provider state map the Session adopted last time. The state is empty while
  the feature is off for this Session.
  """
  def prepare(session, session_config, known) do
    previous = known[@provider] || %{}

    if enabled_config?(session_config) do
      case Store.get(value(session_config, :group_id)) do
        {:ok, workspace} ->
          state = current_state(workspace, session)

          cond do
            previous == state -> {[], state}
            own_latest_write?(previous, state, workspace, session) -> {[], state}
            true -> {[content_payload(workspace)], state}
          end

        # Keep what the Session already has. The next round retries the read.
        {:error, reason} ->
          Logger.warning("condensed workspace read failed: #{inspect(reason)}")
          {[], previous}
      end
    else
      if previous == %{}, do: {[], %{}}, else: {[disabled_payload()], %{}}
    end
  end

  @doc "Whether this round's configuration has the feature on."
  def enabled_config?(session_config) when is_map(session_config),
    do:
      value(session_config, :condensed_workspace_enabled) == true and
        text?(value(session_config, :group_id))

  def enabled_config?(_session_config), do: false

  defp current_state(workspace, session) do
    %{"revision" => workspace.revision}
    |> put_present("compacted_through", compacted_through(session))
  end

  # The writer's tool result holds the content of the revision it made. That
  # is true only while no compaction has removed the result.
  defp own_latest_write?(previous, state, workspace, session) do
    previous != %{} and
      Map.get(previous, "compacted_through") == Map.get(state, "compacted_through") and
      workspace.updated_by["kind"] == "agent" and
      workspace.updated_by["session_id"] == session_id(session)
  end

  @doc false
  def content_payload(workspace) do
    bytes = Store.rendered_bytes(workspace.statements)

    content =
      "Condensed Workspace, revision #{workspace.revision} (#{bytes} bytes, recommended maximum #{Store.recommended_bytes()}). " <>
        "These are the current facts shared by every Agent of this Group. This content replaces any earlier Condensed Workspace content in your context. " <>
        "Keep it current with #{@tool}.\n\n" <> Store.render(workspace.statements)

    payload(
      "Condensed Workspace revision #{workspace.revision}",
      content
    )
  end

  defp disabled_payload do
    payload(
      "Condensed Workspace disabled",
      "The Condensed Workspace is now disabled for this Group. Earlier Condensed Workspace content in your context is no longer maintained; do not treat it as current."
    )
  end

  @doc false
  def payload(summary, content) do
    %{
      "runtime_message_id" => "condensed-workspace:" <> SystemsRuntime.Proc.uuid(),
      "runtime_message_type" => @provider,
      "content_kind" => "model_context",
      "summary" => summary,
      "content" => content,
      "created_at" => SystemsClock.system_time(:second),
      "source_refs" => %{"providers" => [@provider]}
    }
  end

  defp compacted_through(session) when InternalSession.is_session(session),
    do: InternalSession.compacted_through(session)

  defp compacted_through(session) when is_map(session), do: value(session, :compacted_through)
  defp compacted_through(_session), do: nil

  defp session_id(session) when InternalSession.is_session(session),
    do: InternalSession.session_id(session)

  defp session_id(session) when is_map(session), do: value(session, :session_id)
  defp session_id(_session), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))

  defp text?(value), do: is_binary(value) and String.trim(value) != ""
end
