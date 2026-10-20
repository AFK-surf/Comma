defmodule SalixAgent.SessionBirth do
  @moduledoc """
  The create-once birth marker of a Session id.

  Every new Session claims a per-(agent, session) marker object before its
  store create (single-object create-once CAS), so a Session id is born at
  most once. The marker lives under the agent prefix, so agent-lifecycle
  cleanup covers it.

  Markers written for Sessions of the retired External Runtime record
  `"external"`. They read as `:retired`: such an id belongs to the read-only
  history in `SalixAgent.RetiredSessions` and is never born again.
  """

  alias SalixStore.{Keys, S3}

  @type side :: :internal | :retired

  @doc """
  Claim the birth of `session_id`. Answers `:internal` when this claim wins
  or an earlier internal claim exists, and `:retired` when the id belongs to
  a retired Session.
  """
  @spec claim(String.t(), String.t()) :: {:ok, side()} | {:error, term()}
  def claim(agent_id, session_id) do
    key = Keys.agent_session_birth(agent_id, session_id)

    case S3.put(key, Jason.encode!(%{"runtime" => "internal"}), if_none_match: "*") do
      {:ok, _} ->
        {:ok, :internal}

      {:error, :precondition_failed} ->
        side(agent_id, session_id)

      # A retried conditional PUT may itself have landed: settle by
      # read-back. An absent record means the write did not land; the
      # caller's same-id retry resolves the ambiguity.
      {:error, {:ambiguous, _} = ambiguous} ->
        case side(agent_id, session_id) do
          {:ok, _} = recorded -> recorded
          {:error, :not_found} -> {:error, ambiguous}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Read the recorded birth side, `{:error, :not_found}` when no birth has
  been claimed.
  """
  @spec side(String.t(), String.t()) :: {:ok, side()} | {:error, term()}
  def side(agent_id, session_id) do
    case S3.get(Keys.agent_session_birth(agent_id, session_id)) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"runtime" => "internal"}} -> {:ok, :internal}
          {:ok, %{"runtime" => "external"}} -> {:ok, :retired}
          _ -> {:error, {:invalid_birth_marker, agent_id, session_id}}
        end

      {:error, _} = error ->
        error
    end
  end
end
