defmodule SalixStore.SessionHandoffs do
  @moduledoc """
  PostgreSQL store for each internal Session's disposable living handoff
  projection (`salix_session_handoffs`).

  One row per `(agent_id, session_id)`, bound by foreign key to
  `salix_sessions (agent_id, session_id) ON DELETE CASCADE`. Each revision
  summarizes exactly `base ∪ (base_compacted_through, covered_message_id]`,
  certified by `prefix_digest`.

  Policy:
    * Soft limit: #{4 * 1024} UTF-8 bytes (updater applies eviction pressure).
    * Hard limit: #{8 * 1024} UTF-8 bytes (overflow rejects the whole batch;
      never silently truncates).
    * Max single statement: #{2 * 1024} UTF-8 bytes.
    * Max operations per batch: 32; `operations: []` is valid when a settled
      delta changed no state.
    * Rejects emptying a non-empty list, or bootstrapping from a non-empty
      summary into an empty list.
    * Refuses writes when the owning `salix_sessions` row is missing,
      non-internal, or soft-deleted (`deleted_at IS NOT NULL`).
    * Redacts credential-shaped patterns before persisting.
  """

  import Ecto.Query
  alias SalixStore.{Repo, StatementList}

  @soft_limit_bytes 4 * 1024
  @hard_limit_bytes 8 * 1024
  @max_statement_bytes 2 * 1024
  @max_operations 32
  @redacted "[redacted]"

  @credential_patterns [
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)/s,
    ~r/\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}/,
    ~r/\bgh[pousr]_[A-Za-z0-9]{20,}/,
    ~r/\bgithub_pat_[A-Za-z0-9_]{20,}/,
    ~r/\bxox[abprs]-[A-Za-z0-9-]{10,}/,
    ~r/\bglpat-[A-Za-z0-9_-]{16,}/,
    ~r/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
    ~r/\b\d{8,10}:[A-Za-z0-9_-]{35}\b/,
    ~r/\bAIza[0-9A-Za-z_-]{35}\b/,
    ~r/\b[a-z]{2,8}_sk_[A-Za-z0-9]{16,}/,
    ~r/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/,
    ~r/(?i)\bbearer\s+[A-Za-z0-9._~+\/-]{16,}=*/
  ]

  @named_credential_quoted_patterns [
    ~r/(?i)\b((?:api[_ -]?(?:key|hash|secret)|secret|token|password|passwd|passphrase|session[_ -]?string|client[_ -]?secret|private[_ -]?key|access[_ -]?key)s?)(["'`]?[ \t*]{0,4}[:=：][ \t]*)(")((?:\\.|[^"\r\n])+)"/u,
    ~r/(?i)\b((?:api[_ -]?(?:key|hash|secret)|secret|token|password|passwd|passphrase|session[_ -]?string|client[_ -]?secret|private[_ -]?key|access[_ -]?key)s?)(["'`]?[ \t*]{0,4}[:=：][ \t]*)(')((?:\\.|[^'\r\n])+)'/u,
    ~r/(?i)\b((?:api[_ -]?(?:key|hash|secret)|secret|token|password|passwd|passphrase|session[_ -]?string|client[_ -]?secret|private[_ -]?key|access[_ -]?key)s?)(["'`]?[ \t*]{0,4}[:=：][ \t]*)(`)((?:\\.|[^`\r\n])+)`/u
  ]

  @named_credential_unquoted ~r/(?i)\b((?:api[_ -]?(?:key|hash|secret)|secret|token|password|passwd|passphrase|session[_ -]?string|client[_ -]?secret|private[_ -]?key|access[_ -]?key)s?)(["'`]?[ \t*]{0,4}[:=：][ \t]*)(?![\/~"'`])([^\s,;)\]}>"'`]{8,})/u

  @env_var_reference ~r/\A\$\{?[A-Z][A-Z0-9_]+\}?\z/

  defmodule Row do
    @moduledoc false
    use Ecto.Schema
    @primary_key false
    schema "salix_session_handoffs" do
      field(:agent_id, :string, primary_key: true)
      field(:session_id, :string, primary_key: true)
      field(:revision, :integer)
      field(:base_summary_sequence, :integer)
      field(:base_compacted_through, :integer)
      field(:covered_message_id, :integer)
      field(:prefix_digest, :string)
      field(:value, :map)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  def soft_limit_bytes, do: @soft_limit_bytes
  def hard_limit_bytes, do: @hard_limit_bytes
  def max_statement_bytes, do: @max_statement_bytes
  def max_operations, do: @max_operations

  @doc "Reads the session's living handoff without a lock. Returns `{:ok, nil}` if absent."
  @spec get(String.t(), String.t()) :: {:ok, map() | nil} | {:error, :session_handoff_unavailable}
  def get(agent_id, session_id) when is_binary(agent_id) and is_binary(session_id) do
    case Repo.one(
           from(row in Row,
             where: row.agent_id == ^agent_id and row.session_id == ^session_id
           )
         ) do
      nil -> {:ok, nil}
      row -> {:ok, view(row)}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :session_handoff_unavailable}
  end

  @doc """
  Applies an atomic CAS update to `(agent_id, session_id)`'s handoff row.

  Required keys in `params`:
    * `:expected_revision` - integer >= 0 (0 inserts a new row)
    * `:base_summary_sequence` - integer >= 0
    * `:base_compacted_through` - integer >= 0
    * `:covered_message_id` - integer >= 0
    * `:prefix_digest` - non-empty binary
    * `:operations` - list of `add`/`replace`/`remove` operations (may be `[]`)

  Optional keys:
    * `:reset` - boolean (default `false`); resets statements to empty before applying
    * `:require_non_empty` - boolean (default `false`); rejects empty resulting list
  """
  @spec apply_update(String.t(), String.t(), map()) ::
          {:ok, map()}
          | {:error, :session_unavailable}
          | {:error, {:revision_conflict, non_neg_integer()}}
          | {:error, {:conflict, [String.t()], map()}}
          | {:error, {:overflow, non_neg_integer(), pos_integer()}}
          | {:error, {:invalid, String.t()}}
          | {:error, :session_handoff_unavailable}
  def apply_update(agent_id, session_id, params)
      when is_binary(agent_id) and is_binary(session_id) and is_map(params) do
    with {:ok, expected_revision} <- non_neg_int(params, :expected_revision),
         {:ok, base_seq} <- non_neg_int(params, :base_summary_sequence),
         {:ok, base_through} <- non_neg_int(params, :base_compacted_through),
         {:ok, covered_id} <- non_neg_int(params, :covered_message_id),
         {:ok, prefix_digest} <- non_empty_string(params, :prefix_digest),
         {:ok, operations} <- normalize_operations(Map.get(params, :operations)) do
      reset? = Map.get(params, :reset, false) == true
      require_non_empty? = Map.get(params, :require_non_empty, false) == true
      expected_basis = Map.get(params, :expected_basis)

      Repo.transaction(fn ->
        ensure_session_alive!(agent_id, session_id)

        row =
          Repo.one(
            from(r in Row,
              where: r.agent_id == ^agent_id and r.session_id == ^session_id,
              lock: "FOR UPDATE"
            )
          )

        case row do
          nil ->
            if expected_revision != 0 or not is_nil(expected_basis) do
              Repo.rollback({:revision_conflict, 0})
            end

            base_value = %{"statements" => [], "next_id" => 1}

            case apply_to_value(base_value, operations,
                   require_non_empty: require_non_empty?,
                   allow_empty_result: not require_non_empty?
                 ) do
              {:ok, value, _removed} ->
                %Row{
                  agent_id: agent_id,
                  session_id: session_id,
                  revision: 1,
                  base_summary_sequence: base_seq,
                  base_compacted_through: base_through,
                  covered_message_id: covered_id,
                  prefix_digest: prefix_digest,
                  value: value,
                  updated_at: SystemsClock.timestamp(:utc_datetime_usec)
                }
                |> Repo.insert!()
                |> view()

              {:conflict, missing} ->
                Repo.rollback({:conflict, missing, empty(agent_id, session_id)})

              {:error, reason} ->
                Repo.rollback(reason)
            end

          %Row{} = existing ->
            if existing.revision != expected_revision or
                 not basis_matches?(existing, expected_basis) do
              Repo.rollback({:revision_conflict, existing.revision})
            end

            base_value =
              if reset?,
                do: %{"statements" => [], "next_id" => 1},
                else: existing.value || %{"statements" => [], "next_id" => 1}

            allow_empty_result? =
              not require_non_empty? and
                (reset? or List.wrap(base_value["statements"]) == [])

            case apply_to_value(base_value, operations,
                   require_non_empty: require_non_empty?,
                   allow_empty_result: allow_empty_result?
                 ) do
              {:ok, value, _removed} ->
                existing
                |> Ecto.Changeset.change(
                  revision: existing.revision + 1,
                  base_summary_sequence: base_seq,
                  base_compacted_through: base_through,
                  covered_message_id: covered_id,
                  prefix_digest: prefix_digest,
                  value: value,
                  updated_at: SystemsClock.timestamp(:utc_datetime_usec)
                )
                |> Repo.update!()
                |> view()

              {:conflict, missing} ->
                Repo.rollback({:conflict, missing, view(existing)})

              {:error, reason} ->
                Repo.rollback(reason)
            end
        end
      end)
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :session_handoff_unavailable}
  end

  @doc """
  Atomically deletes `(agent_id, session_id)`'s handoff row if and only if its
  current `revision` equals `expected_revision` (and optional `expected_basis`
  matches).
  """
  @spec delete_if_revision(String.t(), String.t(), pos_integer(), map() | nil) ::
          :ok
          | {:error, {:revision_conflict, non_neg_integer()}}
          | {:error, :session_handoff_unavailable}
  def delete_if_revision(agent_id, session_id, expected_revision, expected_basis \\ nil)
      when is_binary(agent_id) and is_binary(session_id) and
             is_integer(expected_revision) and expected_revision > 0 do
    case Repo.transaction(fn ->
           Repo.query!(
             """
             SELECT 1
             FROM salix_sessions
             WHERE agent_id = $1 AND session_id = $2
             FOR NO KEY UPDATE
             """,
             [agent_id, session_id]
           )

           case Repo.one(
                  from(r in Row,
                    where: r.agent_id == ^agent_id and r.session_id == ^session_id,
                    lock: "FOR UPDATE"
                  )
                ) do
             nil ->
               :ok

             %Row{revision: ^expected_revision} = row ->
               if basis_matches?(row, expected_basis) do
                 Repo.delete!(row)
                 :ok
               else
                 Repo.rollback({:revision_conflict, row.revision})
               end

             %Row{revision: other} ->
               Repo.rollback({:revision_conflict, other})
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :session_handoff_unavailable}
  end

  @doc "Validates and dry-runs `operations` against a statement value without hitting Postgres."
  @spec validate_batch(map(), term(), keyword()) ::
          {:ok, [map()], map()}
          | {:error, {:invalid, String.t()}}
          | {:error, {:conflict, [String.t()]}}
          | {:error, {:overflow, non_neg_integer(), pos_integer()}}
  def validate_batch(value, operations, opts \\ []) when is_map(value) do
    require_non_empty? = Keyword.get(opts, :require_non_empty, false)
    allow_empty_result? = Keyword.get(opts, :allow_empty_result, not require_non_empty?)

    with {:ok, normalized} <- normalize_operations(operations) do
      case apply_to_value(value, normalized,
             require_non_empty: require_non_empty?,
             allow_empty_result: allow_empty_result?
           ) do
        {:ok, next_value, _removed} -> {:ok, normalized, next_value}
        {:conflict, missing} -> {:error, {:conflict, missing}}
        {:error, _} = error -> error
      end
    end
  end

  @doc "Renders statements with `[sN]` ids for the background updater prompt."
  @spec render_for_prompt([map()]) :: String.t()
  def render_for_prompt(statements), do: StatementList.render(statements)

  @doc "Rendered size in bytes (matching `StatementList.rendered_bytes/1`)."
  @spec rendered_bytes([map()]) :: non_neg_integer()
  def rendered_bytes(statements), do: StatementList.rendered_bytes(statements)

  @doc """
  Renders plain `- <text>` bullets without `[sN]` statement ids for cutover,
  escaping `<compacted-context>`, `</compacted-context>`, and
  `System recovery summary:` so handoff text cannot spoof compaction markers or
  suppress `Episodes` summary facts.
  """
  @spec render_for_cutover([map()]) :: String.t()
  def render_for_cutover([]), do: ""

  def render_for_cutover(statements) when is_list(statements) do
    Enum.map_join(statements, "\n", fn %{"text" => text} ->
      "- " <> escape_cutover_text(text)
    end)
  end

  @doc "The exact `<compacted-context>` wrapped summary produced at cutover."
  @spec wrap_for_cutover([map()]) :: String.t()
  def wrap_for_cutover(statements) when is_list(statements) do
    case render_for_cutover(statements) do
      "" -> ""
      body -> "<compacted-context>\n" <> body <> "\n</compacted-context>"
    end
  end

  @doc "Scrubs credential-shaped patterns before persisting handoff statements."
  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    text =
      Enum.reduce(@named_credential_quoted_patterns, text, fn pattern, acc ->
        Regex.replace(pattern, acc, fn all, name, sep, quote, value ->
          if String.starts_with?(value, ["/", "~"]) or Regex.match?(@env_var_reference, value) do
            all
          else
            name <> sep <> quote <> @redacted <> quote
          end
        end)
      end)

    text =
      Regex.replace(@named_credential_unquoted, text, fn all, name, sep, value ->
        if Regex.match?(@env_var_reference, value) do
          all
        else
          name <> sep <> @redacted
        end
      end)

    Enum.reduce(@credential_patterns, text, fn pattern, acc ->
      Regex.replace(pattern, acc, @redacted)
    end)
  end

  defp basis_matches?(_existing, nil), do: true

  defp basis_matches?(%Row{} = existing, %{} = basis) do
    coords_match? =
      existing.base_summary_sequence == Map.get(basis, :base_summary_sequence) and
        existing.base_compacted_through == Map.get(basis, :base_compacted_through) and
        existing.covered_message_id == Map.get(basis, :covered_message_id) and
        existing.prefix_digest == Map.get(basis, :prefix_digest)

    value_match? =
      case Map.fetch(basis, :value) do
        {:ok, expected_value} -> existing.value == expected_value
        :error -> true
      end

    coords_match? and value_match?
  end

  defp basis_matches?(_existing, _invalid), do: false

  defp escape_cutover_text(text) when is_binary(text) do
    text
    |> String.replace(~r/<\/compacted-context>/i, "[/compacted-context]")
    |> String.replace(~r/<compacted-context>/i, "[compacted-context]")
    |> String.replace(~r/System recovery summary:/i, "System recovery note:")
  end

  defp normalize_operations(operations) do
    StatementList.normalize_operations(operations,
      max_statement_bytes: @max_statement_bytes,
      max_operations: @max_operations,
      allow_empty_operations: true,
      transform_text: &redact/1
    )
  end

  defp apply_to_value(value, operations, opts) do
    StatementList.apply_to_value(
      value,
      operations,
      Keyword.merge(
        [
          hard_limit_bytes: @hard_limit_bytes,
          overflow_policy: :reject
        ],
        opts
      )
    )
  end

  defp ensure_session_alive!(agent_id, session_id) do
    case Repo.query!(
           """
           SELECT 1
           FROM salix_sessions
           WHERE agent_id = $1
             AND session_id = $2
             AND birth_kind = 'internal'
             AND deleted_at IS NULL
           FOR NO KEY UPDATE
           """,
           [agent_id, session_id]
         ).rows do
      [[1]] -> :ok
      _ -> Repo.rollback(:session_unavailable)
    end
  end

  defp non_neg_int(map, key) do
    case Map.get(map, key) do
      n when is_integer(n) and n >= 0 -> {:ok, n}
      _ -> {:error, {:invalid, "#{key} must be a non-negative integer"}}
    end
  end

  defp non_empty_string(map, key) do
    case Map.get(map, key) do
      s when is_binary(s) and byte_size(s) > 0 -> {:ok, s}
      _ -> {:error, {:invalid, "#{key} must be a non-empty string"}}
    end
  end

  defp view(%Row{} = row) do
    value = row.value || %{"statements" => [], "next_id" => 1}

    %{
      agent_id: row.agent_id,
      session_id: row.session_id,
      revision: row.revision,
      base_summary_sequence: row.base_summary_sequence,
      base_compacted_through: row.base_compacted_through,
      covered_message_id: row.covered_message_id,
      prefix_digest: row.prefix_digest,
      statements: List.wrap(value["statements"]),
      next_id: value["next_id"] || 1,
      value: value,
      updated_at: row.updated_at
    }
  end

  defp empty(agent_id, session_id) do
    %{
      agent_id: agent_id,
      session_id: session_id,
      revision: 0,
      base_summary_sequence: 0,
      base_compacted_through: 0,
      covered_message_id: 0,
      prefix_digest: "",
      statements: [],
      next_id: 1,
      value: %{"statements" => [], "next_id" => 1},
      updated_at: nil
    }
  end
end
