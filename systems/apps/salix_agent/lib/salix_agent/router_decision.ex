defmodule SalixAgent.RouterDecision do
  @moduledoc """
  Typed `decide` questions over the newest messages of a Group's canonical
  Router session (docs/messaging-voice.md#voice-profile).

  The evidence is at most 12 user and assistant messages with text, newest
  last, each cut to 1,500 bytes, and only as many as fit the 12 KiB `decide`
  argument limit. Tool calls, tool results, summaries and runtime content are
  never sent. By owner decision, message IFC labels and the Group IFC policy
  do not filter the evidence.
  """

  require Logger

  alias SalixAgent.{Decide, InternalSession, InternalSessionStore}
  alias SalixStore.{CasRecord, Ids, Keys, RuntimeIds}

  @max_messages 12
  @max_message_bytes 1_500
  @max_args 12 * 1024

  @doc """
  Ask `questions` (the `decide` question map) about the Group's recent Router
  conversation. `purpose` names what the questions are for; it is sent with
  the evidence. `opts` requires `:entrypoint` and takes `:admission_deadline`.

  Returns `{:ok, answer}` with the `decide` answer, or `{:error, code}`. Codes
  beyond those of `SalixAgent.Decide` are `no_evidence` and
  `router_unavailable`. Without evidence no provider request is made.
  """
  @spec decide(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def decide(group_id, purpose, questions, opts) do
    with {:ok, _config} <- config(),
         {:ok, group} <- read(Keys.ctl_group(group_id)),
         {:ok, agent_id, session_id, session} <- router_session(group, group_id),
         {:ok, args} <- args(session, purpose, questions) do
      ctx = %{
        agent_id: agent_id,
        session_id: session_id,
        tenant_id: Ids.tenant_id_from_group!(group_id),
        group_id: group_id,
        billing_context: InternalSession.get(session, :billing_context) || %{}
      }

      Decide.system_call(args, ctx,
        entrypoint: Keyword.fetch!(opts, :entrypoint),
        admission_deadline: opts[:admission_deadline]
      )
    end
  rescue
    exception ->
      Logger.warning(
        "router decision failed group=#{group_id} error=#{inspect(exception.__struct__)}"
      )

      {:error, "router_unavailable"}
  catch
    :exit, _ -> {:error, "router_unavailable"}
  end

  defp config do
    case Decide.config() do
      {:ok, config} -> {:ok, config}
      {:error, _} -> {:error, "not_configured"}
    end
  end

  defp read(key) do
    case CasRecord.get(key) do
      {:ok, record} when is_map(record) -> {:ok, record}
      _ -> {:error, "router_unavailable"}
    end
  end

  defp router_session(group, group_id) do
    with agent_id when is_binary(agent_id) and agent_id != "" <- group["router_agent_id"],
         {:ok, %{"role" => "router", "group_id" => ^group_id} = agent} <-
           read(Keys.ctl_agent(agent_id)),
         {:ok, session_id} <- RuntimeIds.persisted_router_session_id(agent),
         {:ok, session} <- InternalSessionStore.read(agent_id, session_id) do
      {:ok, agent_id, session_id, session}
    else
      _ -> {:error, "router_unavailable"}
    end
  end

  # -- Evidence ----------------------------------------------------------------

  defp args(session, purpose, questions) do
    candidates =
      session
      |> InternalSession.get(:messages)
      |> List.wrap()
      |> Enum.reverse()
      |> Stream.flat_map(&entry/1)
      |> Enum.take(@max_messages)

    case fit(candidates, [], purpose, questions) do
      [] -> {:error, "no_evidence"}
      messages -> {:ok, request(messages, purpose, questions)}
    end
  end

  # `candidates` is newest first; the result is oldest first and fits the
  # `decide` argument limit.
  defp fit([], kept, _purpose, _questions), do: kept

  defp fit([message | older], kept, purpose, questions) do
    next = [message | kept]

    if byte_size(Jason.encode!(request(next, purpose, questions))) <= @max_args,
      do: fit(older, next, purpose, questions),
      else: kept
  end

  defp request(messages, purpose, questions),
    do: %{"state" => %{"purpose" => purpose, "messages" => messages}, "questions" => questions}

  defp entry(message) do
    role = field(message, :role)

    with true <- role in ["user", "assistant"],
         text when text != "" <- message |> field(:content) |> text() |> String.trim() do
      [%{"role" => role, "text" => cut(text)}]
    else
      _ -> []
    end
  end

  defp text(content) when is_binary(content), do: content

  defp text(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      %{type: "text", text: text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp text(_content), do: ""

  defp cut(text) when byte_size(text) <= @max_message_bytes, do: text

  defp cut(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn grapheme, {acc, size} ->
      size = size + byte_size(grapheme)

      if size > @max_message_bytes - 3,
        do: {:halt, {acc, size}},
        else: {:cont, {acc <> grapheme, size}}
    end)
    |> elem(0)
    |> Kernel.<>("…")
  end

  defp field(message, key) when is_map(message),
    do: Map.get(message, key, Map.get(message, Atom.to_string(key)))

  defp field(_message, _key), do: nil
end
