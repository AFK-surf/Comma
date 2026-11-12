defmodule SalixIM.ConversationCreateRequests do
  @moduledoc false

  alias SalixStore.{Ids, Repo}

  @columns "conversation_id, request_fingerprint, created_at, task_placement"
  @conflict {:error, {:conflict, "conversation create request was reused with different content"}}

  def read(group_id, request_identity) do
    case query(
           "SELECT " <>
             @columns <>
             " FROM salix_conversation_create_requests WHERE group_id = $1 AND request_identity = $2",
           [group_id, request_identity]
         ) do
      {:ok, %{rows: [row]}} -> binding(group_id, request_identity, row)
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, _} -> {:error, :unavailable}
    end
  end

  def reserve(candidate) do
    params = [
      candidate["group_id"],
      candidate["request_identity"],
      candidate["conversation_id"],
      candidate["request_fingerprint"],
      candidate["created_at"],
      encode(candidate["task_placement"])
    ]

    result =
      query(
        "INSERT INTO salix_conversation_create_requests " <>
          "(group_id, request_identity, conversation_id, request_fingerprint, created_at, task_placement) " <>
          "VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (group_id, request_identity) DO NOTHING RETURNING " <>
          @columns,
        params
      )

    case result do
      {:ok, %{rows: [row]}} ->
        binding(candidate["group_id"], candidate["request_identity"], row)

      {:ok, %{rows: []}} ->
        observe(candidate, false)

      {:error, %Postgrex.Error{postgres: %{code: code}}}
      when code not in [:admin_shutdown, :crash_shutdown, :cannot_connect_now] ->
        {:error, {:rollback, code}}

      {:error, _} ->
        observe(candidate, true)
    end
  end

  defp observe(candidate, unknown?) do
    case read(candidate["group_id"], candidate["request_identity"]) do
      {:ok, existing} ->
        if existing["request_fingerprint"] == candidate["request_fingerprint"],
          do: {:ok, existing},
          else: @conflict

      {:error, :not_found} when unknown? ->
        {:error, :commit_indeterminate}

      {:error, :unavailable} when unknown? ->
        {:error, :commit_indeterminate}

      error ->
        error
    end
  end

  defp binding(group, request, [id, fingerprint, created_at, placement]) do
    with true <- Ids.valid_conversation_id?(id) and is_binary(fingerprint),
         {:ok, placement} <- decode(placement) do
      {:ok,
       %{
         "version" => 1,
         "group_id" => group,
         "request_identity" => request,
         "conversation_id" => id,
         "request_fingerprint" => fingerprint,
         "created_at" => created_at
       }
       |> then(fn binding ->
         if is_nil(placement), do: binding, else: Map.put(binding, "task_placement", placement)
       end)}
    else
      _ -> {:error, :invalid_conversation_create_request}
    end
  end

  defp encode(nil), do: nil
  defp encode(placement), do: :erlang.term_to_binary(placement)
  defp decode(nil), do: {:ok, nil}

  defp decode(payload) do
    case :erlang.binary_to_term(payload, [:safe]) do
      placement when is_map(placement) -> {:ok, placement}
      _ -> {:error, :invalid_conversation_create_request}
    end
  rescue
    ArgumentError -> {:error, :invalid_conversation_create_request}
  end

  defp query(sql, params) do
    Repo.query(sql, params)
  rescue
    _error in DBConnection.ConnectionError -> {:error, :connection_lost}
  catch
    :exit, _ -> {:error, :connection_lost}
  end
end
