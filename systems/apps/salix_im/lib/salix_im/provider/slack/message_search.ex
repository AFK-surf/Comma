defmodule SalixIM.Provider.Slack.MessageSearch do
  @moduledoc """
  Group-owned, cross-channel search over retained Slack messages and media.

  The caller scope comes only from GroupDirectory. Connect/channel/workspace
  input narrows that scope; no query authorizes through personal Slack identity
  or per-channel/file provider requests. Current connect owners are checked
  after canonical source and PG publication observations.
  Modeled in tla/salix/MessageSearchGroupScope.tla.
  """
  alias SalixIM.{GroupDirectory, ProviderConnects}
  alias SalixIM.SlackMessageMirror.Row
  alias SalixStore.{SlackSearchCatalog, SlackSearchSources, SlackSearchWindows}

  @kinds ~w(message_text image video_segment ocr_text asr_transcript document_text)
  @unavailable "Message search is unavailable; retry later or read channel/thread history."

  def search(scope, connect_id, params, default_mode \\ "hybrid") do
    # One budget covers ranking, source/publication/owner observations and the
    # page write. OTP owns worker cancellation; no per-channel timeout loop.
    context = SystemsObservability.Context.capture()

    task =
      Task.async(fn ->
        SystemsObservability.Context.run(context, fn ->
          do_search(scope, connect_id, params, default_mode)
        end)
      end)

    case Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, "Message search timed out; narrow the search or retry later."}
    end
  end

  defp do_search(scope, connect_id, params, default_mode) do
    reader = Application.get_env(:salix_im, :slack_message_search_reader)

    with true <- is_atom(reader) and not is_nil(reader) and reader.active?(),
         {:ok, request, candidates, expires_at} <-
           window(scope, connect_id, params, default_mode, reader),
         {:ok, visible} <- visible(scope, candidates, reader),
         {page, remaining} = Enum.split(visible, request["count"]),
         {:ok, excerpts} <- reader.excerpts(scope, page),
         {:ok, cursor} <- SlackSearchWindows.put(scope, request, remaining, expires_at) do
      positions =
        Map.new(page |> Enum.with_index(), fn {row, n} -> {{row["build_id"], row["unit"]}, n} end)

      messages =
        excerpts
        |> Enum.sort_by(&Map.fetch!(positions, {&1["build_id"], &1["unit"]}))
        |> Enum.map(&Map.drop(&1, ["build_id", "unit"]))

      {:ok,
       %{
         "messages" => messages,
         "next_cursor" => cursor,
         "coverage" => %{
           "kind" => "messages_and_attachments",
           "best_effort" => true,
           "oldest" => timestamp(request["oldest"]),
           "latest" => timestamp(request["latest"]),
           "description" =>
             "Partial background index of retained messages in this group's connected data domains. " <>
               "Includes completed text slices, images, video segments, OCR, speech transcripts and documents. " <>
               "Pending, failed, unsupported or oversized content may be missing; no matches does not prove absence. " <>
               "File extraction is a background snapshot. Pagination uses a finite result window and rechecks current access."
         }
       }}
    else
      {:error, :semantic_busy} ->
        failure("search_busy", "Message search is busy; retry shortly.")

      {:error, :read_over_budget} ->
        {:error,
         "Message search exceeded its read budget; narrow the time, workspace, channel or connect."}

      {:error, :search_scope_over_budget} ->
        {:error, "Message search covers at most 64 connects per request; select a connect."}

      {:error, :search_window_expired} ->
        {:error,
         "This search window expired or is unavailable in this group; start a new search."}

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

  defp failure(error_class, summary),
    do:
      {:error, %{"error_class" => error_class, "message" => summary, "public_summary" => summary}}

  defp window(scope, connect_id, %{"cursor" => token} = params, _mode, _reader) do
    with true <- Map.keys(params) == ["cursor"],
         {:ok, request, candidates, expires_at} <- SlackSearchWindows.get(scope, token),
         true <- connect_id in ["", request["connect_id"]] do
      {:ok, request, candidates, expires_at}
    else
      false -> {:error, "Continue with cursor alone and the original optional connect_id."}
      error -> error
    end
  end

  defp window(scope, connect_id, params, default_mode, reader) do
    with {:ok, request} <- arguments(params, connect_id, default_mode),
         {:ok, connects} <-
           SlackSearchCatalog.connects(scope.tenant_id, scope.group_id, connect_id),
         {:ok, candidates} <- reader.candidates(scope, connects, request) do
      {:ok, request, candidates, nil}
    end
  end

  defp visible(_scope, [], _reader), do: {:ok, []}

  defp visible(scope, candidates, reader) do
    with {:ok, current} <- reader.current_sources(scope.tenant_id, candidates),
         source_valid = Enum.filter(candidates, &current_source?(&1, current)),
         {:ok, published} <- SlackSearchSources.visible(source_valid),
         published_valid = Enum.filter(source_valid, &MapSet.member?(published, &1["build_id"])),
         {:ok, current_scope} <- GroupDirectory.scope_for_agent(scope.agent_id),
         true <-
           current_scope.tenant_id == scope.tenant_id and current_scope.group_id == scope.group_id,
         {:ok, allowed} <- ProviderConnects.authorize_message_search(scope, published_valid),
         {:ok, known} <- SlackSearchCatalog.known_candidates(published_valid) do
      {:ok,
       Enum.filter(
         published_valid,
         &(MapSet.member?(allowed, {&1["connect_id"], &1["workspace_id"]}) and
             MapSet.member?(known, &1["build_id"]))
       )}
    else
      false -> {:error, :search_scope_changed}
      error -> error
    end
  end

  defp current_source?(candidate, current) do
    key = {candidate["workspace_id"], candidate["channel_id"], candidate["message_ts_us"]}

    case current[key] do
      %{deleted: false, message_identity: m, payload_identity: p} ->
        m == candidate["message_identity"] and p == candidate["payload_identity"]

      _ ->
        false
    end
  end

  defp arguments(params, connect_id, default_mode) when is_map(params) do
    count = params["count"] || 10
    query = params["query"]
    mode = params["mode"] || default_mode
    channel = params["channel"] || ""
    workspace = params["workspace"] || ""
    sender = params["sender"] || ""
    kind = params["kind"] || ""

    with true <-
           Map.keys(params) -- ~w(query mode count channel workspace sender kind oldest latest) ==
             [],
         true <- is_binary(query) and byte_size(query) in 1..4096 and String.trim(query) != "",
         true <- mode in ~w(keyword semantic hybrid),
         true <- is_integer(count) and count in 1..20,
         true <-
           is_binary(channel) and
             (channel == "" or Regex.match?(~r/\A[CGD][A-Za-z0-9]{1,64}\z/, channel)),
         true <- is_binary(workspace) and byte_size(workspace) <= 128,
         true <- is_binary(sender) and byte_size(sender) <= 128,
         true <- kind == "" or kind in @kinds,
         {:ok, oldest} <- bound(params["oldest"], 0),
         {:ok, latest} <- bound(params["latest"], System.os_time(:microsecond)),
         true <- oldest >= 0 and oldest < latest do
      {:ok,
       %{
         "query" => query,
         "mode" => mode,
         "count" => count,
         "connect_id" => connect_id,
         "channel" => channel,
         "workspace" => workspace,
         "sender" => sender,
         "kind" => kind,
         "oldest" => oldest,
         "latest" => latest
       }}
    else
      _ ->
        {:error,
         "Require query (1–4096 UTF-8 bytes); mode keyword/semantic/hybrid; count 1–20. " <>
           "Channel, workspace, kind and oldest/latest Slack timestamps are optional narrowing filters."}
    end
  end

  defp arguments(_, _, _), do: {:error, "Message search parameters must be an object."}
  defp bound(nil, default), do: {:ok, default}
  defp bound(value, _) when is_binary(value), do: Row.slack_ts_micros(value)
  defp bound(_, _), do: :error

  defp timestamp(us),
    do:
      "#{div(us, 1_000_000)}.#{us |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")}"
end
