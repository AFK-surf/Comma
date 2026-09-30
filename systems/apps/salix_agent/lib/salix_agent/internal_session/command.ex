defmodule SalixAgent.InternalSession.Command do
  @moduledoc false

  alias SalixAgent.{InternalSession, InternalSessionStore}
  alias InternalSessionStore.Revision

  def run(agent_id, session_id, revision, command, args, checkpoint \\ nil)

  def run(agent_id, session_id, %Revision{} = revision, command, args, checkpoint)
      when command in [:input, :stage_conversation, :activate, :log, :recover] do
    io = %{agent_id: agent_id, session_id: session_id, revision: revision}

    revision.cursor
    |> InternalSession.start_command(
      native_command(command, args),
      canonical_args(command, args),
      checkpoint
    )
    |> drive_native(io)
  end

  @doc false
  def prepare(agent_id, session_id, revision, command, args, checkpoint \\ nil)

  def prepare(agent_id, session_id, %Revision{} = revision, command, args, checkpoint)
      when command in [:input, :activate, :log, :recover] do
    io = %{agent_id: agent_id, session_id: session_id, revision: revision, suspend_fence: true}

    revision.cursor
    |> InternalSession.start_command(
      native_command(command, args),
      canonical_args(command, args),
      checkpoint
    )
    |> drive_native(io)
  end

  @doc false
  def resume_fence(agent_id, session_id, confirmed) do
    io = %{
      agent_id: agent_id,
      session_id: session_id,
      revision: InternalSessionStore.command_revision(confirmed)
    }

    confirmed |> InternalSession.command_step(:next, nil) |> drive_native(io)
  end

  # Admission must check the same identities that the store will apply.
  # UTF-8 repair can merge distinct raw identities, so run it before admission.
  defp canonical_args(:input, {entry, born}),
    do: {SalixAgent.Utf8.scrub_session_input(entry), born}

  defp canonical_args(:stage_conversation, {entry, born}),
    do: {SalixAgent.Utf8.scrub_session_input(entry), born}

  defp canonical_args(:activate, {leading, hwm, prompt, active}),
    do: {SalixAgent.Utf8.scrub_term(leading), hwm, SalixAgent.Utf8.scrub_term(prompt), active}

  defp canonical_args(:log, entry), do: SalixAgent.Utf8.scrub_session_input(entry)

  defp canonical_args(_command, args), do: args

  defp native_command(:input, {%{conversation_source: source}, _}) when is_map(source),
    do: :conversation_input

  defp native_command(:input, {%{"conversation_source" => source} = entry, _})
       when is_map(source) and not is_map_key(entry, :conversation_source),
       do: :conversation_input

  defp native_command(command, _args), do: command

  defp drive_native({input, {:fence}}, %{suspend_fence: true}),
    do: {{:awaiting_fence, input}, InternalSessionStore.command_revision(input), nil}

  defp drive_native({input, {:return, result, checkpoint}}, _io),
    do: {result, InternalSessionStore.command_revision(input), checkpoint}

  defp drive_native({input, {:validate_write, events}}, io),
    do: input |> InternalSessionStore.write_command(events) |> drive_native(io)

  defp drive_native({input, {:effect, request}}, io) do
    {result, _io} = execute(request, io)

    result =
      case result do
        {:error, reason} -> {:error, external_error(reason)}
        other -> other
      end

    input |> InternalSession.command_step(:effect_result, result) |> drive_native(io)
  end

  defp drive_native({input, {:fence}}, io) do
    settled =
      case InternalSessionStore.fence_command(io.agent_id, io.session_id, input) do
        {:ok, confirmed} ->
          confirmed

        {:error, reason} ->
          {rejected, {:rejected, _}} =
            InternalSession.command_step(input, :fence_reject, {:error, external_error(reason)})

          rejected
      end

    settled |> InternalSession.command_step(:next, nil) |> drive_native(io)
  end

  # Errors are external observations, not Session state. Preserve data errors
  # and turn host-only exception and process values into bounded diagnostics.
  def external_error(%{__struct__: _} = reason), do: diagnostic(reason)

  def external_error(reason) when is_map(reason),
    do: Map.new(reason, fn {key, value} -> {external_error(key), external_error(value)} end)

  def external_error(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.map(&external_error/1) |> List.to_tuple()

  def external_error(reason) when is_list(reason), do: Enum.map(reason, &external_error/1)

  def external_error(reason)
      when is_pid(reason) or is_reference(reason) or is_function(reason) or is_port(reason),
      do: diagnostic(reason)

  def external_error(reason), do: reason

  defp diagnostic(reason), do: inspect(reason, limit: 20, printable_limit: 2048)

  defp execute({:workspace, operation_id, metadata, events, billing_context}, io) do
    result =
      case SalixAgent.AgentActor.commit_workspace_operation(
             io.agent_id,
             operation_id,
             metadata,
             events,
             billing_context: billing_context,
             entrypoint: "storage_write",
             actor_type: "delivery"
           ) do
        {:ok, _} -> :ok
        error -> error
      end

    {result, io}
  end

  defp execute({:notify, "input_accepted", events}, io) do
    SalixAgent.RouterRequestMonitor.enqueued(io.agent_id, io.session_id, events)
    {:ok, io}
  end

  defp execute({:authorize, scope}, io),
    do: {SalixAgent.VisibleReply.authorize(io.agent_id, scope), io}

  defp execute({:random, bytes}, io),
    do: {Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false), io}

  defp execute({:draft_clear, scope}, io) do
    SalixAgent.VisibleReply.cancel(io.agent_id, io.session_id, scope)
    SalixAgent.ActivityEvent.idle(io.agent_id, io.session_id, scope)
    {:ok, io}
  end
end
