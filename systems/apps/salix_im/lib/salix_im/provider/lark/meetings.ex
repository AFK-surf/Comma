defmodule SalixIM.Provider.Lark.Meetings do
  @moduledoc """
  Lark meetings read as a person who signed in (`im_api.lark.*`).

  Lark shows a finished meeting, its notes (the AI meeting notes document and
  the transcript document) and its recording only to people: the bot finds
  and opens them as one of the Group's signed-in Lark accounts
  (`SalixIM.Ports.LarkUserAccounts`). Without `account`, a search runs as
  every account and a read tries each account until one may see the meeting.

  Request shapes follow the official
  [larksuite/cli](https://github.com/larksuite/cli) `vc` and `note`
  shortcuts. A result is labelled with the people Lark names for it: the
  meeting's participants, or else the account that read it.
  """

  import SalixIM.Provider.Util, only: [str: 1, int_or: 2, maybe_put: 3]

  alias SalixIM.IFC.ReadLabels
  alias SalixIM.Ports.{AgentWorkspace, LarkUserAccounts}
  alias SalixIM.Provider.Lark.{API, Minutes}

  @max_page_size 30
  @max_query_chars 50
  @main_doc 1
  @verbatim_doc 2
  @recording_missing 121_004
  @recording_generating 124_002
  @max_transcript_pages 500
  @inline_transcript_bytes 60_000
  @transcript_head_chars 12_000

  @spec call(String.t(), map(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def call(agent_id, connect, api, params), do: do_call(agent_id, connect, api, params)

  defp do_call(_agent_id, connect, "lark.list_accounts", _params) do
    with {:ok, accounts} <- accounts(connect) do
      {:ok, %{"accounts" => accounts}}
    end
  end

  defp do_call(agent_id, connect, "lark.search_meetings", params) do
    with {:ok, body} <- search_body(params),
         {:ok, accounts} <- chosen_accounts(connect, params),
         :ok <- one_account_per_page(accounts, params) do
      query = search_query(params)

      results =
        Enum.map(accounts, fn account ->
          with {:ok, as_user} <- as_user(agent_id, connect, account),
               {:ok, data} <-
                 API.post_read(
                   as_user,
                   "/vc/v1/meetings/search?" <> URI.encode_query(query),
                   body
                 ) do
            {:ok, account, data}
          else
            {:error, reason} -> {:error, account, reason}
          end
        end)

      found =
        for {:ok, account, data} <- results,
            %{} = item <- List.wrap(data["items"]),
            do: Map.put(item, "account", account["alias"])

      case {found, results} do
        {[], [{:error, _account, reason}]} ->
          {:error, reason}

        _ ->
          {:ok,
           labelled(
             %{
               "meetings" => found,
               "has_more" => Enum.any?(results, &match?({:ok, _, %{"has_more" => true}}, &1)),
               # A page token belongs to the account whose search made it.
               "next_pages" =>
                 for(
                   {:ok, account, %{"has_more" => true} = data} <- results,
                   token = blank_nil(data["page_token"]),
                   do: %{"account" => account["alias"], "page_token" => token}
                 ),
               "failed_accounts" =>
                 for({:error, account, reason} <- results, do: failure(account, reason))
             },
             connect,
             Enum.map(accounts, & &1["open_id"])
           )}
      end
    end
  end

  defp do_call(agent_id, connect, "lark.get_meeting", params) do
    with {:ok, meeting_id} <- required(params, "meeting_id"),
         {:ok, accounts} <- chosen_accounts(connect, params) do
      first_readable(accounts, fn account ->
        with {:ok, as_user} <- as_user(agent_id, connect, account),
             {:ok, data} <-
               API.get(as_user, "/vc/v1/meetings/#{segment(meeting_id)}", %{
                 "with_participants" => "true",
                 "user_id_type" => "open_id"
               }) do
          meeting = data["meeting"] || %{}
          participants = List.wrap(meeting["participants"])

          result =
            %{
              "account" => account["alias"],
              "meeting_id" => meeting_id,
              "meeting" => meeting,
              "note_id" => blank_nil(meeting["note_id"])
            }
            |> put_recording(as_user, meeting_id)

          {:ok,
           labelled(
             result,
             connect,
             [account["open_id"] | Enum.map(participants, &(&1["id"] || &1["user_id"]))]
           )}
        end
      end)
    end
  end

  defp do_call(agent_id, connect, "lark.get_note", params) do
    with {:ok, note_id} <- required(params, "note_id"),
         {:ok, accounts} <- chosen_accounts(connect, params) do
      first_readable(accounts, fn account ->
        with {:ok, as_user} <- as_user(agent_id, connect, account),
             {:ok, data} <- API.get(as_user, "/vc/v1/notes/#{segment(note_id)}") do
          note = data["note"] || %{}
          artifacts = List.wrap(note["artifacts"])
          type = display_type(note["note_display_type"] || note["display_type"])

          result = %{
            "account" => account["alias"],
            "note_id" => note_id,
            "note_doc_token" => artifact_doc(artifacts, @main_doc),
            "verbatim_doc_token" => artifact_doc(artifacts, @verbatim_doc),
            "shared_doc_tokens" =>
              for(%{"doc_token" => token} <- List.wrap(note["references"]), do: token),
            "display_type" => type,
            "creator_id" => note["creator_id"],
            "create_time" => note["create_time"]
          }

          with {:ok, result} <- with_transcript(agent_id, as_user, note_id, type, params, result) do
            {:ok, labelled(result, connect, [account["open_id"]])}
          end
        end
      end)
    end
  end

  defp do_call(_agent_id, _connect, _api, _params),
    do: {:error, "unsupported Lark meeting api"}

  # ---------------------------------------------------------------------------
  # accounts
  # ---------------------------------------------------------------------------

  @doc """
  The connect acting as the signed-in account `alias_name` of its Group.
  Other Lark operations use it when the request names an `account`.
  """
  @spec as_account(String.t(), map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def as_account(agent_id, connect, alias_name) do
    with {:ok, accounts} <- accounts(connect),
         {:ok, account} <- find_account(accounts, alias_name),
         do: as_user(agent_id, connect, account)
  end

  defp accounts(connect) do
    case LarkUserAccounts.list(connect["group_id"]) do
      {:ok, accounts} ->
        {:ok, accounts}

      {:error, reason} ->
        {:error, "could not read the signed-in Lark accounts: #{inspect(reason)}"}
    end
  end

  defp chosen_accounts(connect, params) do
    with {:ok, accounts} <- accounts(connect) do
      case {str(params["account"]), Enum.filter(accounts, &(&1["status"] == "active"))} do
        {"", []} ->
          {:error,
           "no Lark account is signed in for this Agent Swarm. Ask the person to sign in: call oauth.request_authorization with provider lark, an alias such as lark-<their name> and a reason, and send its authorization_url in the chat the request came from."}

        {"", active} ->
          {:ok, active}

        {alias_name, _active} ->
          with {:ok, account} <- find_account(accounts, alias_name), do: {:ok, [account]}
      end
    end
  end

  defp one_account_per_page([_one], _params), do: :ok

  defp one_account_per_page(_accounts, params) do
    if blank_nil(params["page_token"]),
      do:
        {:error, "a page_token belongs to one account: pass the account of its next_pages entry"},
      else: :ok
  end

  defp find_account(accounts, wanted) do
    case Enum.find(accounts, &(wanted in [&1["alias"], &1["open_id"]])) do
      %{"status" => "active"} = account ->
        {:ok, account}

      %{} = account ->
        {:error,
         "the Lark account #{account["name"] || wanted} is #{account["status"]}; ask that person to sign in again: call oauth.request_authorization with provider lark and alias #{account["alias"]}, and send its authorization_url in the chat the request came from"}

      nil ->
        {:error, "no signed-in Lark account #{wanted}; lark.list_accounts names them"}
    end
  end

  defp as_user(agent_id, connect, account) do
    case LarkUserAccounts.access_token(agent_id, account["alias"]) do
      {:ok, token} ->
        {:ok, API.as_user(connect, token)}

      {:error, reason} ->
        {:error,
         "the Lark account #{account["name"] || account["alias"]} cannot be used: #{reason_text(reason)}"}
    end
  end

  # The first account whose read succeeds; else the last refusal, with every
  # account's reason when there were several.
  defp first_readable(accounts, read) do
    Enum.reduce_while(accounts, [], fn account, failures ->
      case read.(account) do
        {:ok, _} = ok -> {:halt, ok}
        {:error, reason} -> {:cont, [failure(account, reason) | failures]}
      end
    end)
    |> case do
      {:ok, _} = ok ->
        ok

      [only] ->
        {:error, only["error"]}

      failures ->
        {:error,
         "no signed-in Lark account can read it: " <>
           Enum.map_join(Enum.reverse(failures), "; ", &"#{&1["account"]}: #{&1["error"]}")}
    end
  end

  defp failure(account, reason),
    do: %{"account" => account["alias"], "error" => reason_text(reason)}

  # ---------------------------------------------------------------------------
  # transcript of a unified note
  # ---------------------------------------------------------------------------

  # A unified note keeps its transcript in the note itself, not in a
  # verbatim document; Lark pages it by cursor. A partial transcript would
  # mislead, so any failed or stuck page fails the read.
  defp with_transcript(
         _agent_id,
         _as_user,
         _note_id,
         _type,
         %{"include_transcript" => flag},
         result
       )
       when flag not in [true, "true"],
       do: {:ok, result}

  defp with_transcript(_agent_id, _as_user, _note_id, _type, params, result)
       when not is_map_key(params, "include_transcript"),
       do: {:ok, result}

  defp with_transcript(_agent_id, _as_user, _note_id, type, _params, result)
       when type != "unified" do
    {:ok,
     Map.put(
       result,
       "transcript_guidance",
       "This note keeps its transcript in the document verbatim_doc_token; read it with lark.fetch_doc and the same account."
     )}
  end

  defp with_transcript(agent_id, as_user, note_id, _type, params, result) do
    locale = blank_nil(params["locale"]) || "zh_cn"

    with {:ok, transcript} <- unified_transcript(as_user, note_id, locale, nil, [], 1) do
      put_transcript(agent_id, note_id, transcript, result)
    end
  end

  defp unified_transcript(_as_user, _note_id, _locale, _cursor, _chunks, page)
       when page > @max_transcript_pages,
       do: {:error, "the transcript has more than #{@max_transcript_pages} pages"}

  defp unified_transcript(as_user, note_id, locale, cursor, chunks, page) do
    query =
      %{"format" => "markdown", "locale" => locale, "page_size" => "200"}
      |> maybe_put("cursor_id", cursor)

    with {:ok, data} <-
           API.get(as_user, "/vc/v1/notes/#{segment(note_id)}/unified_note_transcript", query) do
      chunks = [get_in(data, ["transcript", "markdown"]) || "" | chunks]
      next = blank_nil(data["next_cursor_id"])

      cond do
        data["has_more"] != true ->
          {:ok, chunks |> Enum.reverse() |> Enum.join()}

        is_nil(next) or next == cursor ->
          {:error, "Lark's transcript pages stopped advancing; the transcript was not read"}

        true ->
          unified_transcript(as_user, note_id, locale, next, chunks, page + 1)
      end
    end
  end

  defp put_transcript(_agent_id, _note_id, transcript, result)
       when byte_size(transcript) <= @inline_transcript_bytes,
       do: {:ok, Map.put(result, "transcript", transcript)}

  defp put_transcript(agent_id, note_id, transcript, result) do
    path = "/lark/notes/#{note_id}-transcript.md"

    case AgentWorkspace.write(agent_id, path, transcript) do
      {:ok, _} ->
        {:ok,
         Map.merge(result, %{
           "transcript" => String.slice(transcript, 0, @transcript_head_chars),
           "transcript_truncated" => true,
           "vfs_path" => path,
           "guidance" =>
             "The transcript is larger than one tool result. The full transcript is at vfs_path; read it with fs.read_file."
         })}

      {:error, reason} ->
        {:error, "could not stage the transcript in the agent workspace: #{inspect(reason)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # recording
  # ---------------------------------------------------------------------------

  defp put_recording(result, as_user, meeting_id) do
    case API.get(as_user, "/vc/v1/meetings/#{segment(meeting_id)}/recording") do
      {:ok, %{"recording" => %{"url" => url}}} ->
        case Minutes.minute_token(url) do
          {:ok, token} -> Map.merge(result, %{"minute_token" => token, "minute_url" => url})
          {:error, _} -> Map.put(result, "minute_url", url)
        end

      {:error, reason} ->
        Map.put(result, "recording", recording_state(reason))

      _none ->
        Map.put(result, "recording", "none")
    end
  end

  defp recording_state(reason) do
    cond do
      String.contains?(reason, "error #{@recording_missing} ") -> "none"
      String.contains?(reason, "error #{@recording_generating} ") -> "generating"
      true -> "unavailable: " <> reason
    end
  end

  # ---------------------------------------------------------------------------
  # params and results
  # ---------------------------------------------------------------------------

  defp search_body(params) do
    query = str(params["query"])

    with :ok <- query_length(query),
         {:ok, start_time} <- Minutes.time_param(params["start"], :start),
         {:ok, end_time} <- Minutes.time_param(params["end"], :end) do
      participants = Minutes.ids(params["participant_ids"])
      organizers = Minutes.ids(params["organizer_ids"])

      filter =
        %{}
        |> maybe_put("participant_ids", if(participants != [], do: participants))
        |> maybe_put("organizer_ids", if(organizers != [], do: organizers))
        |> maybe_put(
          "start_time",
          if(start_time || end_time,
            do: %{} |> maybe_put("start_time", start_time) |> maybe_put("end_time", end_time)
          )
        )

      if query == "" and filter == %{} do
        {:error, "pass at least one of query, organizer_ids, participant_ids, start, or end"}
      else
        {:ok,
         %{}
         |> maybe_put("query", if(query != "", do: query))
         |> maybe_put("meeting_filter", if(filter != %{}, do: filter))}
      end
    end
  end

  defp query_length(query) do
    if String.length(query) > @max_query_chars,
      do: {:error, "query is limited to #{@max_query_chars} characters"},
      else: :ok
  end

  defp search_query(params) do
    size = (params["page_size"] || 15) |> int_or(15) |> min(@max_page_size) |> max(1)

    %{"page_size" => Integer.to_string(size)}
    |> maybe_put("page_token", blank_nil(params["page_token"]))
  end

  defp required(params, key) do
    case str(params[key]) do
      "" -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp artifact_doc(artifacts, type) do
    Enum.find_value(artifacts, fn artifact ->
      if int_or(artifact["artifact_type"], 0) == type, do: blank_nil(artifact["doc_token"])
    end)
  end

  defp display_type(value) do
    case int_or(value, 0) do
      1 -> "normal"
      2 -> "unified"
      _ -> "unknown"
    end
  end

  defp labelled(result, connect, open_ids) do
    audience = fn -> {:ok, %{"user_ids" => open_ids |> Enum.map(&str/1) |> Enum.uniq()}} end

    case ReadLabels.for_document(connect, audience) do
      nil -> result
      ifc -> Map.put(result, "__ifc__", ifc)
    end
  end

  defp blank_nil(value) do
    case str(value) do
      "" -> nil
      text -> text
    end
  end

  defp segment(value), do: value |> str() |> URI.encode_www_form()

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)
end
