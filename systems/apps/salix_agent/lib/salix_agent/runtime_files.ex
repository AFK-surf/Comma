defmodule SalixAgent.RuntimeFiles do
  @moduledoc """
  Session-scoped runtime virtual files.

  `/.runtime/` is not the agent workspace. Paths under this prefix resolve from
  the current tool context's `{agent_id, session_id}`, so the same path in two
  sessions returns two different session-local documents.
  """

  alias SalixAgent.{InternalSession, InternalSessionStore}

  @prefix "/.runtime"
  @compaction_recovery_path @prefix <> "/compaction-recovery.md"

  @typedoc "Tool dispatcher context."
  @type ctx :: %{optional(:agent_id) => String.t(), optional(:session_id) => String.t()}

  @doc "The virtual runtime mount prefix."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "True when a virtual path is under `/.runtime`."
  @spec matches?(term()) :: boolean()
  def matches?(path) when is_binary(path) do
    clean(path) == @prefix or String.starts_with?(clean(path), @prefix <> "/")
  end

  def matches?(_path), do: false

  @doc "Runtime virtual file paths visible for a prefix."
  @spec file_paths(String.t()) :: [String.t()]
  def file_paths(prefix \\ "") do
    if overlap?(prefix), do: [@compaction_recovery_path], else: []
  end

  @doc "Runtime virtual file paths visible for the current session context."
  @spec file_paths(ctx(), String.t()) :: [String.t()]
  def file_paths(ctx, prefix) when is_map(ctx) do
    with {:ok, _agent_id} <- required_ctx(ctx, :agent_id),
         {:ok, _session_id} <- required_ctx(ctx, :session_id) do
      file_paths(prefix)
    else
      _ -> []
    end
  end

  @doc "Read a runtime virtual file body."
  @spec read(ctx(), String.t()) :: {:ok, binary()} | {:error, :not_found} | {:error, String.t()}
  def read(ctx, path) when is_map(ctx) and is_binary(path) do
    case clean(path) do
      @compaction_recovery_path -> read_compaction_recovery(ctx)
      _ -> {:error, :not_found}
    end
  end

  @doc "Stat a runtime virtual file."
  @spec stat(ctx(), String.t()) :: {:ok, map()} | {:error, :not_found} | {:error, String.t()}
  def stat(ctx, path) do
    with {:ok, body} <- read(ctx, path) do
      {:ok, %{kind: "file", size: byte_size(body)}}
    end
  end

  defp read_compaction_recovery(ctx) do
    with {:ok, agent_id} <- required_ctx(ctx, :agent_id),
         {:ok, session_id} <- required_ctx(ctx, :session_id) do
      case InternalSessionStore.read(agent_id, session_id) do
        {:ok, session} -> {:ok, render_compaction_recovery(session)}
        {:error, :not_found} -> {:error, :not_found}
        {:error, reason} -> {:error, "read runtime file: #{inspect(reason)}"}
      end
    end
  end

  defp required_ctx(ctx, key) do
    case Map.get(ctx, key) || Map.get(ctx, to_string(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "runtime files require #{key} in the current tool context"}
    end
  end

  defp render_compaction_recovery(session) do
    case latest_recovery(session) do
      nil -> render_empty_recovery(session)
      recovery -> render_available_recovery(session, recovery)
    end
  end

  defp render_empty_recovery(session) do
    """
    # Compaction Recovery

    Session: #{InternalSession.session_id(session)}

    No compaction recovery context is recorded for this runtime session.
    """
    |> String.trim()
  end

  defp render_available_recovery(session, recovery) do
    compacted_through =
      int_value(recovery["compacted_through"], InternalSession.compacted_through(session) || 0)

    messages = covered_messages(session, compacted_through)

    [
      "# Compaction Recovery",
      "",
      "Session: #{InternalSession.session_id(session)}",
      "Generated at: #{value_or_unknown(recovery["created_at"])}",
      "Failure category: #{value_or_unknown(recovery["category"])}",
      "Failure detail: #{value_or_unknown(recovery["reason"])}",
      "Compacted through message id: #{compacted_through}",
      "Summary sequence: #{value_or_unknown(recovery["summary_sequence"])}",
      "",
      "This file is scoped to the current runtime session. The same path in another session resolves to that session's own recovery context.",
      "",
      "## Messages",
      "",
      render_messages(messages)
    ]
    |> Enum.join("\n")
    |> String.trim()
  end

  # The recovery body needs the covered messages. Under format 2 a later
  # successful compaction archives them out of the hot window, so the window
  # is completed from the archive; the redaction overlay masks both tiers.
  defp covered_messages(session, compacted_through) do
    window =
      session
      |> InternalSession.masked_messages()
      |> Enum.filter(&(message_id(&1) <= compacted_through))

    window_ids = MapSet.new(window, &message_id/1)

    archived =
      case InternalSessionStore.archived_records(InternalSession.agent_id(session), session) do
        {:ok, records} ->
          for %{kind: "message", data: data} <- records,
              is_integer(data["id"]) and data["id"] <= compacted_through,
              not MapSet.member?(window_ids, data["id"]),
              do: data

        {:error, _reason} ->
          # The file is a best-effort recovery aid; an unreadable archive
          # must not turn it into an error page. The window alone renders.
          []
      end

    Enum.sort_by(archived ++ window, &message_id/1)
  end

  # Control state lives in an explicit field under format 2 (events archive
  # out of the hot object); the trailing scan remains as the format-1
  # fallback until the cutover.
  defp latest_recovery(session),
    do: InternalSession.query(session, :latest_compaction_recovery)

  defp render_messages([]), do: "No compacted messages are available."

  defp render_messages(messages) do
    messages
    |> Enum.map(fn message ->
      [
        "### Message #{message_id(message)}",
        "",
        "- role: #{value_or_unknown(value(message, "role"))}",
        "- created_at: #{value_or_unknown(value(message, "created_at"))}",
        "",
        "```",
        content_text(value(message, "content")),
        "```"
      ]
      |> Enum.join("\n")
    end)
    |> Enum.join("\n\n")
  end

  defp content_text(content) when is_binary(content), do: content
  defp content_text(content), do: Jason.encode!(content, pretty: true)

  defp message_id(message), do: int_value(value(message, "id"), 0)

  defp value(map, key) when is_map(map) do
    value = Map.get(map, key)
    if is_nil(value), do: Map.get(map, String.to_atom(key)), else: value
  end

  defp value(_map, _key), do: nil

  defp value_or_unknown(nil), do: "unknown"
  defp value_or_unknown(""), do: "unknown"
  defp value_or_unknown(value), do: to_string(value)

  defp int_value(value, _default) when is_integer(value), do: value

  defp int_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp int_value(_value, default), do: default

  defp overlap?(prefix) do
    case to_string(prefix || "") do
      "" ->
        true

      prefix ->
        normalized = clean(prefix)
        normalized == "/" or String.starts_with?(@compaction_recovery_path, normalized)
    end
  end

  defp clean(path), do: Path.expand(path, "/")
end
