defmodule SalixIM.Provider.Slack.SemanticSearch do
  @moduledoc """
  Optional im_api.slack.semantic_search. Never called by ordinary Slack reads
  or ingestion. Current bot membership and pending source updates remain Salix
  authorities; a vector candidate is only a hint. The current-state observation
  boundary is modeled in tla/salix/SlackSemanticIndex.tla.
  """
  alias SalixIM.Provider.Slack.API
  alias SalixIM.SlackMessageMirror.Row
  alias SalixStore.SlackMirrorOutbox

  @window_us 14 * 86_400 * 1_000_000
  @unavailable "Semantic search is unavailable; use im_api.slack.search or channel/thread history."

  def search(connect, params) do
    with {:ok, args} <- arguments(params),
         reader when is_atom(reader) and not is_nil(reader) <-
           Application.get_env(:salix_im, :slack_semantic_reader),
         :ok <- authorize(connect, args.channel),
         scope =
           Map.take(connect, ~w(tenant_id workspace_id)) |> Map.put("channel_id", args.channel),
         {:ok, hits} <- reader.search(scope, args.query, args.oldest, args.latest, args.count * 2),
         {:ok, pending} <- SlackMirrorOutbox.pending_message_ts(scope, Enum.map(hits, & &1["ts"])),
         messages = hits |> Enum.reject(&(&1["ts"] in pending)) |> Enum.take(args.count),
         messages = filter_files(connect, messages),
         :ok <- authorize(connect, args.channel) do
      {:ok,
       %{
         # Semantic search is bounded to one channel, so the whole result
         # carries that channel's audience (§3.3). The reserved key is popped
         # by `SalixAgent.Tools.IMRouter` before encoding.
         "__ifc__" => SalixIM.IFC.ReadLabels.for_scope(connect, args.channel),
         "messages" => messages,
         "coverage" => %{
           "kind" => "messages_and_attachments",
           "best_effort" => true,
           "oldest" => timestamp(args.oldest),
           "latest" => timestamp(args.latest),
           "max_source_characters" => 8000,
           "description" =>
             "Partial background index; no matches does not prove absence. " <>
               "Includes processed images, video segments, OCR, ASR and document text. " <>
               "File content is a background snapshot; independent edits may lag. " <>
               "Some files may be pending, unsupported or over limits. Use file IDs, pages and timestamps to read original context."
         }
       }}
    else
      {:error, :read_over_budget} ->
        {:error, "Semantic search exceeded its read budget; narrow oldest/latest."}

      {:error, message} when is_binary(message) ->
        {:error, message}

      _ ->
        {:error, @unavailable}
    end
  rescue
    _ -> {:error, @unavailable}
  catch
    _, _ -> {:error, @unavailable}
  end

  defp filter_files(connect, hits) do
    # File removal can be independent of a message edit. Do not disclose an
    # extracted excerpt after the selected installation loses the file.
    file_ids = hits |> Enum.map(& &1["file_id"]) |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()
    allowed = Enum.filter(file_ids, &file_visible?(connect, &1))
    Enum.filter(hits, &(&1["file_id"] in [nil, ""] or &1["file_id"] in allowed))
  end

  defp file_visible?(connect, file_id) do
    case API.request_form(API.installation(connect), "files.info", %{"file" => file_id},
           timeout_ms: 1500
         ) do
      %{"ok" => true, "file" => %{"id" => ^file_id} = file} -> file["mode"] != "tombstone"
      _ -> false
    end
  rescue
    _ in API.Error -> false
  end

  defp authorize(connect, channel) do
    case API.request_form(
           API.installation(connect),
           "conversations.info",
           %{"channel" => channel},
           timeout_ms: 1500
         ) do
      %{"ok" => true, "channel" => %{"id" => ^channel, "is_member" => true}} -> :ok
      _ -> {:error, "Semantic search requires current bot membership in this channel."}
    end
  rescue
    _ in API.Error ->
      {:error, "Cannot verify current Slack channel access; semantic search denied."}
  end

  defp arguments(params) when is_map(params) do
    now = System.os_time(:microsecond)
    count = params["count"] || 10
    query = params["query"]
    channel = params["channel"]

    with true <- Map.keys(params) -- ~w(channel query count oldest latest) == [],
         true <- is_binary(channel) and Regex.match?(~r/\A[CGD][A-Za-z0-9]{1,64}\z/, channel),
         true <- is_binary(query) and byte_size(query) <= 4096 and String.trim(query) != "",
         true <- is_integer(count) and count in 1..20,
         {:ok, latest} <- bound(params["latest"], now),
         {:ok, oldest} <- bound(params["oldest"], latest - @window_us),
         true <- oldest >= 0 and oldest < latest and latest - oldest <= @window_us do
      {:ok, %{channel: channel, query: query, count: count, oldest: oldest, latest: latest}}
    else
      _ ->
        {:error,
         "Require channel ID and query (1–4096 bytes); count 1–20; " <>
           "oldest/latest are Slack timestamps spanning at most 14 days. No other parameters."}
    end
  end

  defp arguments(_), do: {:error, "Semantic search parameters must be an object."}
  defp bound(nil, default), do: {:ok, default}
  defp bound(value, _) when is_binary(value), do: Row.slack_ts_micros(value)
  defp bound(_, _), do: :error

  defp timestamp(us),
    do:
      "#{div(us, 1_000_000)}.#{us |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")}"
end
