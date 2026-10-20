defmodule SalixAgent.TestSupport.RetiredSessionFixture do
  @moduledoc """
  Stores a Session of the retired External Runtime as an earlier release wrote
  it: one `state.json` object and one JSONL segment of records under
  `agents/<agent_id>/external_runtime/sessions/`. Read through
  `SalixAgent.RetiredSessions`.
  """

  alias SalixStore.{Keys, S3, ULID}

  @doc """
  Writes the Session state and its `records` (maps without ids; each gets a
  ULID id and the Session identity). Returns the stored state.
  """
  def put!(agent, session_id, state \\ %{}, records \\ []) do
    agent_id = agent["agent_id"]

    state =
      Map.merge(
        %{
          "tenant_id" => agent["tenant_id"],
          "group_id" => agent["group_id"],
          "agent_id" => agent_id,
          "session_id" => session_id,
          "created_at" => 1,
          "updated_at" => 1,
          "runtime" => %{"binding" => %{"provider" => "codex"}}
        },
        state
      )

    {:ok, _} =
      S3.put(Keys.agent_external_runtime_session(agent_id, session_id), Jason.encode!(state))

    {records, _last_id} =
      Enum.map_reduce(records, nil, fn record, last_id ->
        id = ULID.generate(last_id)
        {Map.merge(record, %{"id" => id, "agent_id" => agent_id, "session_id" => session_id}), id}
      end)

    case records do
      [] ->
        :ok

      [first | _] ->
        body = Enum.map_join(records, "", &(Jason.encode!(&1) <> "\n"))

        {:ok, _} =
          S3.put(
            Keys.agent_external_runtime_session_segment(agent_id, session_id, first["id"]),
            body
          )
    end

    state
  end
end
