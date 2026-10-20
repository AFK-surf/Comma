defmodule SalixIM.Provider.Feishu.Minutes do
  @moduledoc """
  Feishu Minutes (妙记) through the connect's own tenant app.

  The bot reads a recording's details, AI summary, todos, chapters, keywords,
  transcript, and media, and can search recordings it can see. Feishu offers
  Minutes edits only to a user identity, so this app does not edit them. The
  bot sees a recording only when it is shared with a chat that includes the
  bot, with the app, or by link inside the tenant; otherwise it can ask the
  owner for access.

  Request shapes follow the official
  [larksuite/cli](https://github.com/larksuite/cli) `minutes` shortcuts. Each
  read carries the label that `SalixIM.IFC.ReadLabels.for_document/2`
  derives from the recording's collaborators and link setting.
  """

  import SalixIM.Provider.Util, only: [str: 1, int_or: 2, maybe_put: 3]

  alias SalixIM.FeishuFiles
  alias SalixIM.IFC.ReadLabels
  alias SalixIM.Ports.AgentWorkspace
  alias SalixIM.Provider.Feishu.{API, Docs}

  @artifacts ~w(summary todos chapters keywords transcript)
  @inline_transcript_bytes 60_000
  @transcript_head_chars 12_000
  @max_search_page_size 30
  @max_query_chars 50

  @processing_code 2_091_003
  @no_permission_code 2_091_005

  @spec call(String.t(), map(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def call(agent_id, connect, api, params), do: do_call(agent_id, connect, api, params)

  defp do_call(agent_id, connect, "feishu.get_minute", params) do
    with {:ok, token} <- minute_token(params["minute"]),
         {:ok, include} <- include(params["include"]),
         {:ok, data} <- minutes_get(connect, "/minutes/v1/minutes/#{token}") do
      minute = data["minute"] || %{}

      result =
        %{
          "minute_token" => token,
          "title" => str(minute["title"]),
          "minute" => minute
        }

      with {:ok, result} <- with_artifacts(agent_id, connect, token, include, result) do
        {:ok, labelled(result, connect, token)}
      end
    end
  end

  defp do_call(_agent_id, connect, "feishu.list_minutes", params) do
    with {:ok, body} <- search_body(params),
         {:ok, data} <-
           API.post_read(
             connect,
             "/minutes/v1/minutes/search?" <> URI.encode_query(search_query(params)),
             body
           ) do
      {:ok,
       %{
         "minutes" =>
           Enum.map(List.wrap(data["items"]), fn
             %{} = item -> Map.drop(item, ["avatar"])
             item -> item
           end),
         "has_more" => data["has_more"] == true,
         "next_page_token" => str(data["page_token"])
       }}
    end
  end

  defp do_call(agent_id, connect, "feishu.fetch_minute_media", params) do
    with {:ok, token} <- minute_token(params["minute"]),
         {:ok, data} <- minutes_get(connect, "/minutes/v1/minutes/#{token}/media"),
         {:ok, url} <- download_url(data),
         {:ok, staged} <- FeishuFiles.stage_minute_media(agent_id, token, url) do
      {:ok, labelled(Map.put(staged, "minute_token", token), connect, token)}
    end
  end

  defp do_call(_agent_id, connect, "feishu.request_minute_access", params) do
    with {:ok, token} <- minute_token(params["minute"]),
         perm when perm in ["view", "edit"] <- blank_default(params["perm"], "view"),
         {:ok, _data} <-
           API.post(connect, "/minutes/v1/minutes/#{token}/permissions/apply", %{"perm" => perm}) do
      {:ok, %{"minute_token" => token, "requested" => perm}}
    else
      perm when is_binary(perm) -> {:error, "perm must be view or edit"}
      {:error, _reason} = error -> error
    end
  end

  defp do_call(_agent_id, _connect, _api, _params),
    do: {:error, "unsupported Feishu Minutes api"}

  # ---------------------------------------------------------------------------
  # details and artifacts
  # ---------------------------------------------------------------------------

  defp with_artifacts(_agent_id, _connect, _token, [], result), do: {:ok, result}

  defp with_artifacts(agent_id, connect, token, include, result) do
    with {:ok, data} <- minutes_get(connect, "/minutes/v1/minutes/#{token}/artifacts") do
      artifacts =
        %{}
        |> put_artifact(include, "summary", str(data["summary"]))
        |> put_artifact(include, "todos", List.wrap(data["minute_todos"]))
        |> put_artifact(include, "chapters", List.wrap(data["minute_chapters"]))
        |> put_artifact(include, "keywords", List.wrap(data["keywords"]))

      if "transcript" in include do
        transcript = if is_binary(data["transcript"]), do: data["transcript"], else: ""

        with {:ok, result} <- put_transcript(agent_id, token, transcript, result) do
          {:ok, Map.update(result, "artifacts", artifacts, &Map.merge(artifacts, &1))}
        end
      else
        {:ok, Map.put(result, "artifacts", artifacts)}
      end
    end
  end

  defp put_artifact(artifacts, include, key, value),
    do: if(key in include, do: Map.put(artifacts, key, value), else: artifacts)

  defp put_transcript(_agent_id, _token, transcript, result)
       when byte_size(transcript) <= @inline_transcript_bytes,
       do: {:ok, Map.put(result, "artifacts", %{"transcript" => transcript})}

  defp put_transcript(agent_id, token, transcript, result) do
    path = "/feishu/minutes/#{token}-transcript.txt"

    case AgentWorkspace.write(agent_id, path, transcript) do
      {:ok, _} ->
        {:ok,
         result
         |> Map.put("artifacts", %{
           "transcript" => String.slice(transcript, 0, @transcript_head_chars),
           "transcript_truncated" => true
         })
         |> Map.put("vfs_path", path)
         |> Map.put("file_name", Path.basename(path))
         |> Map.put("mime_type", "text/plain")
         |> Map.put("size", byte_size(transcript))
         |> Map.put(
           "guidance",
           "The transcript is larger than one tool result. The full transcript is at vfs_path; read it with fs.read_file."
         )}

      {:error, reason} ->
        {:error,
         "could not stage the Minutes transcript in the agent workspace: #{inspect(reason)}"}
    end
  end

  # Feishu answers a recording that is still being transcribed, or that this
  # app cannot open, with its own codes; both have a clear next step.
  defp minutes_get(connect, path) do
    case API.get(connect, path) do
      {:ok, data} ->
        {:ok, data}

      {:error, reason} ->
        cond do
          String.contains?(reason, "error #{@processing_code} ") ->
            {:error,
             "Feishu is still generating this recording's content. Try again in a few minutes; do not report it as empty."}

          String.contains?(reason, "error #{@no_permission_code} ") ->
            {:error,
             "This app cannot open the recording. Ask the user to share it with a chat that includes the bot, or, only if the user agrees, call feishu.request_minute_access."}

          true ->
            {:error, reason}
        end
    end
  end

  defp download_url(data) do
    url = str(data["download_url"])

    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> {:ok, url}
      _ -> {:error, "Feishu returned no usable download_url for this recording"}
    end
  end

  defp labelled(result, connect, token) do
    target = %{perm_token: token, perm_type: "minutes"}

    case ReadLabels.for_document(connect, fn -> Docs.permission_audience(connect, target) end) do
      nil -> result
      ifc -> Map.put(result, "__ifc__", ifc)
    end
  end

  # ---------------------------------------------------------------------------
  # params
  # ---------------------------------------------------------------------------

  @doc "Parses a Minutes URL (/minutes/<token>) or a bare minute token."
  @spec minute_token(term()) :: {:ok, String.t()} | {:error, String.t()}
  def minute_token(input) do
    raw = str(input)

    token =
      if String.contains?(raw, "://") do
        uri = URI.parse(raw)
        host = String.downcase(uri.host || "")

        if host in ["feishu.cn", "larkoffice.com"] or String.ends_with?(host, ".feishu.cn") or
             String.ends_with?(host, ".larkoffice.com") do
          case String.split(uri.path || "", "/minutes/", parts: 2) do
            [_before, rest] -> rest |> String.split("/", parts: 2) |> List.first() |> str()
            _ -> ""
          end
        else
          :unsupported_host
        end
      else
        raw
      end

    cond do
      token == :unsupported_host ->
        {:error, "unsupported Minutes host; pass a feishu.cn Minutes link or minute token"}

      token =~ ~r/^[a-z0-9]{8,64}$/ ->
        {:ok, token}

      true ->
        {:error, "minute is required: pass a Feishu Minutes link (/minutes/<token>) or its token"}
    end
  end

  defp include(nil), do: {:ok, []}

  defp include(value) do
    requested =
      value
      |> List.wrap()
      |> Enum.flat_map(&String.split(to_string(&1), ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case requested -- @artifacts do
      [] ->
        {:ok, requested}

      unknown ->
        {:error,
         "unknown include value #{Enum.join(unknown, ", ")}; use #{Enum.join(@artifacts, ", ")}"}
    end
  end

  defp search_body(params) do
    query = str(params["query"])

    with :ok <- query_length(query),
         {:ok, start_time} <- time_param(params["start"], :start),
         {:ok, end_time} <- time_param(params["end"], :end) do
      owners = ids(params["owner_ids"])
      participants = ids(params["participant_ids"])

      filter =
        %{}
        |> maybe_put("owner_ids", if(owners != [], do: owners))
        |> maybe_put("participant_ids", if(participants != [], do: participants))
        |> maybe_put(
          "create_time",
          if(start_time || end_time,
            do: %{} |> maybe_put("start_time", start_time) |> maybe_put("end_time", end_time)
          )
        )

      if query == "" and filter == %{} do
        {:error, "pass at least one of query, owner_ids, participant_ids, start, or end"}
      else
        {:ok,
         %{"sorter" => "create_time_desc"}
         |> maybe_put("query", if(query != "", do: query))
         |> maybe_put("filter", if(filter != %{}, do: filter))}
      end
    end
  end

  defp query_length(query) do
    if String.length(query) > @max_query_chars,
      do: {:error, "query is limited to #{@max_query_chars} characters"},
      else: :ok
  end

  defp search_query(params) do
    size =
      (params["page_size"] || 15)
      |> int_or(15)
      |> min(@max_search_page_size)
      |> max(1)

    %{"page_size" => Integer.to_string(size)}
    |> maybe_put("page_token", if(is_binary(params["page_token"]), do: str(params["page_token"])))
  end

  # RFC 3339 passes through; a bare date is the start or the end of that UTC day.
  @doc false
  def time_param(value, bound) do
    raw = str(value)

    cond do
      raw == "" ->
        {:ok, nil}

      match?({:ok, _, _}, DateTime.from_iso8601(raw)) ->
        {:ok, raw}

      match?({:ok, _}, Date.from_iso8601(raw)) ->
        {:ok, raw <> if(bound == :start, do: "T00:00:00Z", else: "T23:59:59Z")}

      true ->
        {:error, "#{bound} must be an RFC 3339 time or a YYYY-MM-DD date"}
    end
  end

  @doc false
  def ids(value) do
    value
    |> List.wrap()
    |> Enum.flat_map(&String.split(to_string(&1), ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp blank_default(value, default) do
    case str(value) do
      "" -> default
      value -> value
    end
  end
end
