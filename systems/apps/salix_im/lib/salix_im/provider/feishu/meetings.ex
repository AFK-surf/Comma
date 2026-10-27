defmodule SalixIM.Provider.Feishu.Meetings do
  @moduledoc """
  Feishu meetings, AI meeting notes and recordings, and the documents and wiki
  pages there are, found and read as the app or as a person who signed in
  (`im_api.feishu.*`, `SalixIM.Ports.FeishuUserAccounts`), so the bot needs no
  link.

  Without `account`, a search (`feishu.search_docs`, `feishu.list_drive_files`,
  `feishu.search_meetings`) runs as the app and then as every active account,
  and a read (`feishu.get_meeting`, `feishu.get_note`) tries the app and then each
  account until one may see the meeting; `account=app` is the app alone. A
  person sees what they took part in or may open, the app what was shared
  with it. A unified note's transcript is given only to a person. What the
  search finds is read with the document, wiki and Minutes operations and the
  same `account`.

  Request shapes follow the official
  [larksuite/cli](https://github.com/larksuite/cli) `vc`, `note`,
  `docs +search` and `drive` shortcuts. A result is labelled with the people Feishu names for it: the
  meeting's participants, or else the account that read it.
  """

  import SalixIM.Provider.Util, only: [str: 1, int_or: 2, maybe_put: 3]

  alias SalixIM.IFC.ReadLabels
  alias SalixIM.Ports.{AgentWorkspace, FeishuUserAccounts}
  alias SalixIM.Provider.Feishu.{API, Minutes}

  @max_page_size 30
  # The app's own identity, as an account of a read.
  @app_alias "app"
  @app %{"alias" => @app_alias, "open_id" => nil, "name" => "the app", "status" => "active"}
  @max_doc_page_size 20
  @identity_batch 10
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

  defp do_call(_agent_id, connect, "feishu.list_accounts", _params) do
    with {:ok, accounts} <- accounts(connect) do
      {:ok, %{"accounts" => Enum.map(accounts, &Map.put(&1, "account", account_ref(&1)))}}
    end
  end

  defp do_call(agent_id, connect, "feishu.search_meetings", params) do
    with {:ok, body} <- search_body(params) do
      query = search_query(params)

      search_as_accounts(agent_id, connect, params, "meetings", fn as_user ->
        with {:ok, data} <-
               API.post_read(
                 as_user,
                 "/vc/v1/meetings/search?" <> URI.encode_query(query),
                 body
               ) do
          {:ok, List.wrap(data["items"]), data["has_more"] == true, data["page_token"]}
        end
      end)
    end
  end

  # Documents and wiki pages the person may open, by keyword: Feishu's own
  # search (`docs +search` of the official CLI, user identity only).
  defp do_call(agent_id, connect, "feishu.search_docs", params) do
    with {:ok, query} <- required(params, "query") do
      size = (params["page_size"] || 15) |> int_or(15) |> min(@max_doc_page_size) |> max(1)

      body =
        %{
          "query" => query,
          "page_size" => size,
          "doc_filter" => %{},
          "wiki_filter" => %{}
        }
        |> maybe_put("page_token", blank_nil(params["page_token"]))

      search_as_accounts(agent_id, connect, params, "documents", fn as_user ->
        with {:ok, data} <- API.post_read(as_user, "/search/v2/doc_wiki/search", body) do
          {:ok, Enum.map(List.wrap(data["res_units"]), &search_hit/1), data["has_more"] == true,
           data["page_token"]}
        end
      end)
    end
  end

  # The files and folders of the person's own cloud space, one folder at a
  # time; without `folder` the root of their space.
  defp do_call(agent_id, connect, "feishu.list_drive_files", params) do
    query =
      %{"page_size" => "50"}
      |> maybe_put("folder_token", blank_nil(params["folder"]))
      |> maybe_put("page_token", blank_nil(params["page_token"]))

    search_as_accounts(agent_id, connect, params, "files", fn as_user ->
      with {:ok, data} <- API.get(as_user, "/drive/v1/files", query) do
        {:ok, List.wrap(data["files"]), data["has_more"] == true,
         data["next_page_token"] || data["page_token"]}
      end
    end)
  end

  defp do_call(agent_id, connect, "feishu.get_meeting", params) do
    with {:ok, meeting_id} <- required(params, "meeting_id"),
         {:ok, accounts} <- chosen_accounts(connect, params) do
      first_readable(accounts, params, fn account ->
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
              "account" => account_ref(account),
              "meeting_id" => meeting_id,
              "meeting" => meeting,
              "note_id" => blank_nil(meeting["note_id"])
            }
            |> put_recording(as_user, meeting_id)

          {:ok,
           labelled(
             result,
             connect,
             Enum.reject(
               [account["open_id"] | Enum.map(participants, &(&1["id"] || &1["user_id"]))],
               &is_nil/1
             )
           )}
        end
      end)
    end
  end

  defp do_call(agent_id, connect, "feishu.get_note", params) do
    with {:ok, note_id} <- required(params, "note_id"),
         {:ok, accounts} <- chosen_accounts(connect, params) do
      first_readable(accounts, params, fn account ->
        with {:ok, as_user} <- as_user(agent_id, connect, account),
             {:ok, data} <- API.get(as_user, "/vc/v1/notes/#{segment(note_id)}") do
          note = data["note"] || %{}
          artifacts = List.wrap(note["artifacts"])
          type = display_type(note["note_display_type"] || note["display_type"])

          result = %{
            "account" => account_ref(account),
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
    do: {:error, "unsupported Feishu meeting api"}

  # ---------------------------------------------------------------------------
  # accounts
  # ---------------------------------------------------------------------------

  @doc """
  The connect acting as the signed-in account `alias_name` of its Group.
  Other Feishu operations use it when the request names an `account`.
  """
  @spec as_account(String.t(), map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def as_account(_agent_id, connect, @app_alias), do: {:ok, connect}

  def as_account(agent_id, connect, alias_name) do
    with {:ok, accounts} <- accounts(connect),
         {:ok, account} <- find_account(accounts, alias_name),
         do: as_user(agent_id, connect, account)
  end

  defp accounts(connect) do
    case FeishuUserAccounts.list(connect["group_id"]) do
      {:ok, accounts} ->
        {:ok, accounts}

      {:error, reason} ->
        {:error, "could not read the signed-in Feishu accounts: #{inspect(reason)}"}
    end
  end

  # Who a read runs as: the app itself and then every active signed-in
  # account, or the one `account` names (`app` for the app alone).
  defp chosen_accounts(connect, params) do
    with {:ok, accounts} <- accounts(connect) do
      case str(params["account"]) do
        "" ->
          {:ok, [@app | Enum.filter(accounts, &(&1["status"] == "active"))]}

        @app_alias ->
          {:ok, [@app]}

        alias_name ->
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

  # One read per chosen account, as that person; the items name the account
  # that found them, and a page token belongs to the account whose read made
  # it. Only when the single account fails is the read an error.
  defp search_as_accounts(agent_id, connect, params, key, read) do
    with {:ok, identities} <- chosen_accounts(connect, params),
         {accounts, next_from} = identity_batch(identities, params),
         :ok <- one_account_per_page(accounts, params) do
      results =
        Enum.map(accounts, fn account ->
          with {:ok, as_user} <- as_user(agent_id, connect, account),
               {:ok, items, more?, token} <- read.(as_user) do
            {:ok, account, items, more?, token}
          else
            {:error, reason} -> {:error, account, reason}
          end
        end)

      found =
        for {:ok, account, items, _more?, _token} <- results,
            %{} = item <- items,
            do: Map.put(item, "account", account_ref(account))

      guidance =
        if identities == [@app],
          do:
            "Searched as the app only: no Feishu account is signed in. A person sees more than the app; to search as them, call oauth.request_authorization with provider feishu, an alias such as feishu-<their name> and a reason, and send its authorization_url in the chat the request came from."

      case {found, results} do
        {[], [{:error, _account, reason}]} ->
          {:error, reason}

        _ ->
          {:ok,
           labelled(
             %{
               key => found,
               "has_more" => Enum.any?(results, &match?({:ok, _, _, true, _}, &1)),
               "next_pages" =>
                 for(
                   {:ok, account, _items, true, token} <- results,
                   token = blank_nil(token),
                   do: %{"account" => account_ref(account), "page_token" => token}
                 ),
               "failed_accounts" =>
                 for({:error, account, reason} <- results, do: failure(account, reason))
             }
             |> maybe_put("guidance", guidance)
             |> maybe_put(
               "more_accounts",
               if(next_from,
                 do: %{
                   "accounts_from" => next_from,
                   "guidance" =>
                     "More signed-in accounts remain: call again with accounts_from to search as them."
                 }
               )
             ),
             connect,
             # Labelled by the identities whose items it returns: the app's
             # unknown audience only when the app found something.
             for({:ok, account, [_ | _], _more?, _token} <- results, do: account["open_id"])
           )}
      end
    end
  end

  # A search hit, with its title without Feishu's highlight tags and the link
  # and token the read operations take.
  defp search_hit(%{} = unit) do
    meta = unit["result_meta"] || %{}

    %{
      "title" =>
        (unit["title_highlighted"] || unit["title"] || "")
        |> str()
        |> String.replace(~r{</?h>}, ""),
      "type" => List.first(List.wrap(meta["doc_types"])) || unit["entity_type"],
      "url" => meta["url"],
      "token" => meta["token"],
      "owner" => meta["owner_name"],
      "update_time" => meta["update_time"],
      "summary" => unit["summary_highlighted"] |> str() |> String.replace(~r{</?h>}, "")
    }
    |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp search_hit(_unit), do: nil

  defp find_account(accounts, wanted) do
    case Enum.find(accounts, &(wanted in [&1["alias"], &1["open_id"]])) do
      %{"status" => "active"} = account ->
        {:ok, account}

      %{} = account ->
        {:error,
         "the Feishu account #{account["name"] || wanted} is #{account["status"]}; ask that person to sign in again: call oauth.request_authorization with provider feishu and alias #{account["alias"]}, and send its authorization_url in the chat the request came from"}

      nil ->
        {:error, "no signed-in Feishu account #{wanted}; feishu.list_accounts names them"}
    end
  end

  defp as_user(_agent_id, connect, @app), do: {:ok, connect}

  defp as_user(agent_id, connect, account) do
    case FeishuUserAccounts.access_token(agent_id, account["alias"]) do
      {:ok, token} ->
        {:ok, API.as_user(connect, token)}

      {:error, reason} ->
        {:error,
         "the Feishu account #{account["name"] || account["alias"]} cannot be used: #{reason_text(reason)}"}
    end
  end

  # The first account whose read succeeds; else the last refusal, with every
  # account's reason when there were several.
  defp first_readable(identities, params, read) do
    {accounts, next_from} = identity_batch(identities, params)

    Enum.reduce_while(accounts, [], fn account, failures ->
      case read.(account) do
        {:ok, _} = ok -> {:halt, ok}
        {:error, reason} -> {:cont, [failure(account, reason) | failures]}
      end
    end)
    |> case do
      {:ok, _} = ok ->
        ok

      [only] when is_nil(next_from) ->
        {:error, only["error"]}

      failures ->
        {:error,
         "no signed-in Feishu account can read it: " <>
           Enum.map_join(Enum.reverse(failures), "; ", &"#{&1["account"]}: #{&1["error"]}") <>
           if(next_from,
             do: "; more accounts remain: call again with accounts_from #{next_from}",
             else: ""
           )}
    end
  end

  defp failure(account, reason),
    do: %{"account" => account_ref(account), "error" => reason_text(reason)}

  # How a result names the identity that read it, for the `account` of the
  # next read: `app` is only ever the app, so an account a person labelled
  # `app` is named by its open_id.
  defp account_ref(@app), do: @app_alias
  defp account_ref(%{"alias" => @app_alias} = account), do: account["open_id"]
  defp account_ref(account), do: account["alias"]

  # At most @identity_batch identities per call. The rest are read by the
  # next call with `accounts_from`, so a Group may hold any number of
  # accounts without one call fanning out to all of them.
  defp identity_batch([_one] = identities, _params), do: {identities, nil}

  defp identity_batch(identities, params) do
    from = params["accounts_from"] |> int_or(0) |> max(0)
    batch = Enum.slice(identities, from, @identity_batch)
    next = from + @identity_batch
    {batch, if(next < length(identities), do: next)}
  end

  # ---------------------------------------------------------------------------
  # transcript of a unified note
  # ---------------------------------------------------------------------------

  # A unified note keeps its transcript in the note itself, not in a
  # verbatim document; Feishu pages it by cursor. A partial transcript would
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
       "This note keeps its transcript in the document verbatim_doc_token; read it with feishu.fetch_doc and the same account."
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
          {:error, "Feishu's transcript pages stopped advancing; the transcript was not read"}

        true ->
          unified_transcript(as_user, note_id, locale, next, chunks, page + 1)
      end
    end
  end

  defp put_transcript(_agent_id, _note_id, transcript, result)
       when byte_size(transcript) <= @inline_transcript_bytes,
       do: {:ok, Map.put(result, "transcript", transcript)}

  defp put_transcript(agent_id, note_id, transcript, result) do
    path = "/feishu/notes/#{note_id}-transcript.md"

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

  # Read as people, the result is labelled with them. What the app itself
  # found has no audience this module can name, so it gets the fail-closed
  # label.
  defp labelled(result, connect, open_ids) do
    audience = fn ->
      if nil in open_ids,
        do: {:error, :read_as_app},
        else: {:ok, %{"user_ids" => open_ids |> Enum.map(&str/1) |> Enum.uniq()}}
    end

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
