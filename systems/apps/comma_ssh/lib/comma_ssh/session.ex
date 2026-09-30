defmodule CommaSSH.Session do
  @moduledoc "Connection-owned enrollment and Comma commands. Credentials never enter the view model."
  use GenServer
  alias Comma.Accounts.SSHIdentities

  def start_link(context), do: GenServer.start_link(__MODULE__, context)

  def init(context) do
    Process.flag(:trap_exit, true)
    Process.flag(:sensitive, true)
    send(self(), :start)
    Process.send_after(self(), :enrollment_deadline, 900_000)

    {:ok,
     Map.merge(context, %{
       token: nil,
       stage: :email,
       challenge: nil,
       binding: Base.url_encode64(:crypto.strong_rand_bytes(32)),
       workspaces: [],
       stream: nil
     })}
  end

  def format_status(status),
    do: status |> Map.put(:state, :redacted) |> Map.put(:message, :redacted)

  def handle_info(:start, state) do
    next =
      case SSHIdentities.login(state.key) do
        {:ok, token} ->
          workspaces(%{state | token: token})

        {:error, :unknown_key} ->
          emit(
            state,
            {:screen, :email,
             [
               "Sign in to enroll this SSH key.",
               SSHIdentities.fingerprint(state.key),
               "This key will grant future account access. Revoke it with /keys or the account API.",
               "Email:"
             ]}
          )

          state

        _ ->
          send(state.ui, :close)
          state
      end

    send(state.ui, :done)
    {:noreply, next}
  end

  def handle_info(:enrollment_deadline, %{token: nil} = state), do: {:stop, :normal, state}
  def handle_info(:enrollment_deadline, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _}, %{ui: pid} = state), do: {:stop, :normal, state}

  def handle_info({:EXIT, pid, _}, %{stream: pid} = state) do
    emit(state, {:task_count, nil})
    emit(state, {:notice, "Chat connection ended. Use /workspace to reconnect."})
    {:noreply, %{state | stream: nil}}
  end

  def handle_info({:chat_ui, pid, event}, %{stream: pid} = state) do
    emit(state, event)
    {:noreply, state}
  end

  def handle_info({:chat_close, pid}, %{stream: pid} = state) do
    send(state.ui, :close)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  def handle_cast(:check, state) do
    valid =
      if state.token do
        with {:ok, user, session} <- Comma.Accounts.resolve_session(state.token) do
          case state[:current_workspace] do
            nil -> :ok
            id -> Comma.Workspaces.authorize(user, session, id)
          end
        end
      else
        :ok
      end

    if match?({:error, _}, valid), do: send(state.ui, :close)
    send(state.ui, :done)
    {:noreply, state}
  end

  def handle_cast({:submit, _screen, text}, state) do
    started = System.monotonic_time()

    {next, outcome} =
      try do
        {command(text, state), :ok}
      rescue
        _ ->
          emit(state, {:notice, "Service unavailable. Retry your action."})
          {state, :error}
      catch
        :exit, _ ->
          emit(state, {:notice, "Service unavailable. Retry your action."})
          send(state.ui, :service_unavailable)
          {state, :timeout}
      end

    CommaProduct.Telemetry.emit_operation(
      :ssh_command,
      outcome,
      System.monotonic_time() - started
    )

    send(state.ui, :done)
    {:noreply, next}
  end

  defp command(email, %{token: nil, stage: :email} = state) do
    {ip, _port} = state.peer
    attrs = %{"email" => email, "remote_ip" => ip |> :inet.ntoa() |> to_string()}

    case Comma.AuthChallenges.request_ssh_enrollment(
           attrs,
           state.binding <> SSHIdentities.fingerprint(state.key)
         ) do
      {:ok, response} ->
        emit(
          state,
          {:screen, :code,
           [
             "Enter the six-digit code sent to your email.",
             "Type /resend to request another code."
           ]}
        )

        Map.merge(state, %{stage: :code, challenge: response["challenge_id"], email: email})

      _ ->
        emit(state, {:notice, "Cannot send code. Check the email or wait before retrying."})
        state
    end
  end

  defp command("/resend", %{token: nil, stage: :code} = state),
    do: command(state.email, %{state | stage: :email})

  defp command(code, %{token: nil, stage: :code} = state) do
    with {:ok, user} <-
           Comma.AuthChallenges.verify_ssh_enrollment(
             state.challenge,
             code,
             state.binding <> SSHIdentities.fingerprint(state.key)
           ),
         {:ok, _identity} <- SSHIdentities.enroll(user, state.key),
         {:ok, token} <- SSHIdentities.login(state.key) do
      workspaces(%{state | token: token, challenge: nil})
    else
      _ ->
        emit(state, {:notice, "Enrollment failed. Check the code or use /resend."})
        state
    end
  end

  defp command(text, state) do
    with {:ok, user, _session} <- Comma.Accounts.resolve_session(state.token) do
      cond do
        text == "/workspace" ->
          workspaces(state)

        text == "/keys" ->
          lines =
            SSHIdentities.list(user["id"])
            |> Enum.map(fn key ->
              "#{key.id} #{key.fingerprint}#{if key.revoked_at, do: " (revoked)", else: ""}"
            end)

          emit(state, {:screen, :keys, ["SSH keys. Use /revoke KEY_ID or /workspace." | lines]})
          stop_stream(%{state | stage: :keys})

        String.starts_with?(text, "/revoke ") ->
          result = SSHIdentities.revoke(user["id"], String.trim_leading(text, "/revoke "))
          emit(state, {:notice, if(result == :ok, do: "Key revoked.", else: "Key not found.")})

          if match?({:error, _}, Comma.Accounts.resolve_session(state.token)),
            do: send(state.ui, :close)

          state

        state.stage == :workspace ->
          select_workspace(text, state)

        state.stage == :chat and is_pid(state.stream) ->
          GenServer.call(state.stream, {:command, text}, 15_000)
          state

        true ->
          emit(state, {:notice, "Use /workspace to select a chat."})
          state
      end
    else
      _ ->
        send(state.ui, :close)
        state
    end
  end

  defp workspaces(state) do
    state = state |> stop_stream() |> Map.put(:current_workspace, nil)

    with {:ok, user, session} <- Comma.Accounts.resolve_session(state.token),
         {:ok, workspaces} <- ready_workspaces(user, session) do
      state = %{state | stage: :workspace, workspaces: workspaces}

      case workspaces do
        [] ->
          emit(
            state,
            {:screen, :workspace,
             ["Workspace setup is in progress. Enter /workspace to refresh."]}
          )

          state

        # A sole workspace leaves the reader no choice, so open it instead of asking.
        [only] ->
          case open_workspace(only, state) do
            {:ok, next} ->
              next

            :error ->
              emit(
                state,
                {:screen, :workspace, ["Cannot open your workspace. Enter /workspace to retry."]}
              )

              state
          end

        _ ->
          emit(state, {:workspaces, workspaces})
          state
      end
    else
      _ ->
        emit(state, {:notice, "Cannot load workspaces. Enter /workspace to retry."})
        state
    end
  end

  defp ready_workspaces(user, session) do
    case Comma.Workspaces.list_for_user(user["id"], session) do
      {:ok, []} ->
        with {:ok, _bootstrap} <- Comma.WorkspaceBootstrap.ensure_default(user["id"]) do
          Comma.Workspaces.list_for_user(user["id"], session)
        end

      result ->
        result
    end
  end

  defp select_workspace(text, state) do
    with {n, ""} when n > 0 <- Integer.parse(text),
         workspace when is_map(workspace) <- Enum.at(state.workspaces, n - 1),
         {:ok, next} <- open_workspace(workspace, state) do
      next
    else
      _ ->
        emit(
          state,
          {:notice, "Cannot open that workspace. Check the number or retry /workspace."}
        )

        state
    end
  end

  defp open_workspace(workspace, state) do
    case CommaSSH.Chat.start_link(%{ui: self(), token: state.token, workspace: workspace}) do
      {:ok, stream} ->
        {:ok,
         Map.merge(state, %{stage: :chat, stream: stream, current_workspace: workspace["id"]})}

      _ ->
        :error
    end
  end

  defp stop_stream(%{stream: pid} = state) when is_pid(pid) do
    GenServer.stop(pid, :normal, 2_000)
    Map.merge(state, %{stream: nil, current_workspace: nil})
  end

  defp stop_stream(state), do: state
  defp emit(state, event), do: send(state.ui, {:ui, event})

  def terminate(_, state) do
    if state.stream, do: Process.exit(state.stream, :shutdown)
    if state.token, do: Comma.Accounts.revoke_session_token(state.token)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
