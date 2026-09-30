defmodule CommaScripts.WorkspaceBootstrap do
  @moduledoc false

  def ensure_operation_runtime_started! do
    if Process.whereis(Comma.Oban) do
      :ok
    else
      case Supervisor.restart_child(CommaCore.Supervisor, Comma.Oban) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, :running} -> :ok
        {:error, :not_found} -> start_oban!()
        {:error, reason} -> raise "failed to restart Comma Oban: #{inspect(reason)}"
      end
    end
  end

  def ensure_ready!(request, opts) when is_function(request, 0) and is_list(opts) do
    max_attempts = positive_integer!(opts, :max_attempts)
    poll_ms = non_negative_integer!(opts, :poll_ms)

    do_ensure_ready!(request, max_attempts, poll_ms, nil)
  end

  def ensure_assistant_chat_ready!(request, opts)
      when is_function(request, 0) and is_list(opts) do
    max_attempts = positive_integer!(opts, :max_attempts)
    poll_ms = non_negative_integer!(opts, :poll_ms)

    do_ensure_assistant_chat_ready!(request, max_attempts, poll_ms, nil)
  end

  def progress_external_operations! do
    if Mix.env() == :test do
      case Oban.drain_queue(
             Comma.Oban,
             queue: :comma_external,
             with_recursion: true,
             with_safety: false
           ) do
        %{cancelled: 0, discard: 0, failure: 0, snoozed: 0} ->
          :ok

        result ->
          raise "failed to drain Comma external operations: #{inspect(result)}"
      end
    else
      :ok
    end
  end

  defp start_oban! do
    case Supervisor.start_child(
           CommaCore.Supervisor,
           {Comma.ObanBootstrap, Application.fetch_env!(:comma_core, Oban)}
         ) do
      {:ok, _pid} ->
        :ok

      {:ok, _pid, _info} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, :already_present} ->
        case Supervisor.restart_child(CommaCore.Supervisor, Comma.Oban) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, :running} -> :ok
          {:error, reason} -> raise "failed to restart Comma Oban: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise "failed to start Comma Oban: #{inspect(reason)}"
    end
  end

  defp do_ensure_ready!(_request, 0, _poll_ms, last_response) do
    raise "timed out waiting for Comma workspace bootstrap; last response=#{inspect(last_response)}"
  end

  defp do_ensure_ready!(request, attempts_left, poll_ms, _last_response) do
    conn = request.()
    payload = decode_payload!(conn)

    case {conn.status, payload} do
      {200, %{"status" => "ready", "workspace" => %{"id" => id} = workspace}}
      when is_binary(id) and id != "" ->
        workspace

      {202, %{"status" => "provisioning", "workspace" => %{"id" => id}}}
      when is_binary(id) and id != "" ->
        progress_external_operations!()

        if attempts_left == 1 do
          do_ensure_ready!(request, 0, poll_ms, payload)
        else
          Process.sleep(poll_ms)
          do_ensure_ready!(request, attempts_left - 1, poll_ms, payload)
        end

      {status, _payload} ->
        raise "unexpected Comma workspace bootstrap response HTTP #{status}: #{inspect(payload)}"
    end
  end

  defp do_ensure_assistant_chat_ready!(_request, 0, _poll_ms, last_response) do
    raise "timed out waiting for Comma assistant chat; last response=#{inspect(last_response)}"
  end

  defp do_ensure_assistant_chat_ready!(request, attempts_left, poll_ms, _last_response) do
    conn = request.()
    payload = decode_payload!(conn)

    case {conn.status, payload} do
      {200, %{"id" => id, "status" => "active"} = conversation}
      when is_binary(id) and id != "" ->
        conversation

      {200, %{"status" => "pending"}} ->
        progress_external_operations!()

        if attempts_left == 1 do
          do_ensure_assistant_chat_ready!(request, 0, poll_ms, payload)
        else
          Process.sleep(poll_ms)
          do_ensure_assistant_chat_ready!(request, attempts_left - 1, poll_ms, payload)
        end

      {status, _payload} ->
        raise "unexpected Comma assistant-chat response HTTP #{status}: #{inspect(payload)}"
    end
  end

  defp decode_payload!(%Plug.Conn{resp_body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) -> payload
      {:ok, payload} -> raise "unexpected Comma workspace bootstrap payload: #{inspect(payload)}"
      {:error, reason} -> raise "invalid Comma workspace bootstrap JSON: #{inspect(reason)}"
    end
  end

  defp positive_integer!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 -> value
      _ -> raise ArgumentError, "#{key} must be a positive integer"
    end
  end

  defp non_negative_integer!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> value
      _ -> raise ArgumentError, "#{key} must be a non-negative integer"
    end
  end
end
