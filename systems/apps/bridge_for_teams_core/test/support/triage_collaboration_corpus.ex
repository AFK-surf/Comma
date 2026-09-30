defmodule BridgeForTeams.TriageCollaborationCorpus do
  @moduledoc """
  Eight frozen, de-identified real collaboration threads for local replay.

  Expected behavior and held-out timestamps are observer data, never model
  context. The capture contains only the messages available at each cutoff.
  Binary source images and the public article remain in an explicitly selected
  private local cache; no downloader or live service runs from this fixture.
  The article was captured later, so identical historical page content is not
  claimed. Missing Calendar/OS snapshots stay missing, not invented responses.

  Source text is the user connector's rendered capture, not raw Slack API bytes.
  Its labelled mentions are converted to Slack's canonical ID-only syntax at
  this transport adapter; display names stay in the captured member metadata.
  """

  @path Path.expand("../fixtures/triage/collaboration_cases_20260908.json", __DIR__)
  @external_resource @path
  @corpus @path |> File.read!() |> Jason.decode!()
  @direct_controls_path Path.expand(
                          "../fixtures/triage/direct_answer_controls_20260911.json",
                          __DIR__
                        )
  @external_resource @direct_controls_path
  @direct_controls @direct_controls_path |> File.read!() |> Jason.decode!()

  def cases, do: @corpus["cases"]
  def fetch!(id), do: Enum.find(cases(), &(&1["id"] == id)) || raise("unknown collaboration case")

  def direct_correction_cases do
    calendar =
      fetch!("calendar_source_conflict")
      |> Map.put("id", "calendar_source_conflict_http")
      |> Map.put("source_case_id", "calendar_source_conflict")
      |> Map.put("sample_kind", "captured_source_with_conditional_http_pages")
      |> Map.update!("capture_boundary", fn boundary ->
        boundary <>
          " This variant serves the same finite captured messages through the production HTTP fallback; it is not historical Slack API coverage or a mirror watermark."
      end)

    [calendar | @direct_controls]
  end

  def login_screenshot_original do
    root = "1788856645.705209"

    %{
      "id" => "login_screenshot_original",
      "title" => "原始登录截图问题",
      "group" => "missing_or_conflicting",
      "source_channel" => "C_COLLAB_APP",
      "root_ts" => root,
      "cutoff_ts" => root,
      "input_message_ts" => root,
      "source_messages" => [
        %{
          "type" => "message",
          "channel" => "C_COLLAB_APP",
          "ts" => root,
          "thread_ts" => root,
          "user" => "UCOLLAB09",
          "display_name" => "提问者",
          "actor_kind" => "human",
          "text" => "这个是啥东西 每次重新登录的时候都需要",
          "files" => [%{"id" => "FLOGIN001", "name" => "image.png", "mimetype" => "image/png"}]
        }
      ],
      "retrievable_messages" => [],
      "held_out_message_ts" => ["1788857006.337679", "1788857046.523899"],
      "expected" => %{"route" => "investigate"},
      "sample_kind" => "captured_original_login_screenshot",
      "capture_boundary" =>
        "Original Slack message and unedited F0C0CE7A0CC image. Later BFT and Zork replies are held out. Local identities and transports are substituted."
    }
  end

  def subscription_screenshot_original do
    root = "1789106517.177349"

    %{
      "id" => "subscription_screenshot_original",
      "title" => "读取已有截图再回答风险问题",
      "group" => "missing_or_conflicting",
      "source_channel" => "C_COLLAB_APP",
      "root_ts" => root,
      "cutoff_ts" => root,
      "input_message_ts" => root,
      "source_messages" => [
        %{
          "type" => "message",
          "channel" => "C_COLLAB_APP",
          "ts" => root,
          "thread_ts" => root,
          "user" => "UCOLLAB01",
          "display_name" => "提问者",
          "actor_kind" => "human",
          "text" => "这个会封号吗 :doge:",
          "files" => [
            %{"id" => "FSUBSCRIPTION001", "name" => "image.png", "mimetype" => "image/png"}
          ]
        }
      ],
      "retrievable_messages" => [],
      "held_out_message_ts" => ["1789106624.692999"],
      "expected" => %{"route" => "investigate"},
      "sample_kind" => "captured_original_subscription_screenshot",
      "capture_boundary" =>
        "Original Slack request and unedited source image; the later bot reply is held out. Local identities and transports are substituted. Reading image pixels does not verify service terms or an account enforcement outcome."
    }
  end

  @doc "The captured original casual turn, not the later request to investigate it."
  def participation_cases do
    original = fetch!("historical_message_sources")
    [pdf, erlang, reply] = original["retrievable_messages"]

    [
      Map.merge(original, %{
        "id" => "casual_erlang_original",
        "title" => "原始频道闲聊：二郎了",
        "root_ts" => reply["ts"],
        "cutoff_ts" => reply["ts"],
        "input_message_ts" => reply["ts"],
        "source_messages" => [reply],
        "retrievable_messages" => [pdf, erlang],
        "held_out_message_ts" => [],
        "expected" => %{"route" => "participate"},
        "sample_kind" => "captured_original_channel_turn",
        "capture_boundary" =>
          "The captured original channel turn and two preceding roots; no invented thread relation or research request. The later September investigation conversation is not model input."
      })
    ]
  end

  @doc "Supplemental local request over captured context; never one of the eight historical requests."
  def attachment_request do
    original = fetch!("meeting_action_detail")

    messages =
      Enum.map(original["source_messages"], fn message ->
        if message["ts"] == original["input_message_ts"] do
          Map.put(message, "text", """
          <@U_BFT> 请直接阅读原始转录，核对会议纪要里关于 Agent 日历/iCal 的讨论，说明原文实际决定了什么、哪些仍只是评估任务。把原始转录文件作为附件一并发回，不要改写原文件。
          """)
        else
          message
        end
      end)

    Map.merge(original, %{
      "id" => "meeting_transcript_attachment_request",
      "title" => "补充本地请求：核对原文并回传原始转录附件",
      "group" => "supplemental_attachment",
      "sample_kind" => "captured_context_with_synthetic_attachment_request",
      "source_case_id" => original["id"],
      "source_messages" => messages,
      "expected" => %{"route" => "investigate"},
      "capture_boundary" =>
        "Only the triggering request is synthetic. Earlier messages and the de-identified transcript are unchanged captured context. This is not a ninth historical request or a replacement for the eight-case quality matrix."
    })
  end

  def entrypoint(case_data) do
    trigger =
      Enum.find(case_data["source_messages"], &(&1["ts"] == case_data["input_message_ts"]))

    if Regex.match?(~r/<@U_BFT(?:\|[^>]*)?>/u, trigger["text"]),
      do: :direct_command,
      else: :triage
  end

  def build(case_data, authority, base_url, cache_dir \\ nil) do
    source_channel = case_data["source_channel"]
    local_channel = authority["approved_channel_id"]

    replace = fn text ->
      text
      |> String.replace(source_channel, local_channel)
      |> String.replace("collaboration-fixture.slack.com", "atlas.slack.com")
      |> String.replace(~r/\bUCOLLAB([0-9]{2})\b/, "U10COLLAB\\1")
      |> then(&Regex.replace(~r/<@([A-Z0-9_]+)\|[^>]*>/u, &1, "<@\\1>"))
    end

    rewrite = fn message ->
      message
      |> Map.put(
        "channel",
        if(message["channel"] == source_channel, do: local_channel, else: message["channel"])
      )
      |> Map.update!("text", replace)
      |> Map.update!("user", replace)
      |> Map.put("workspace_url", "https://atlas.slack.com/")
    end

    source = Enum.map(case_data["source_messages"], rewrite)
    supplemental = Enum.map(case_data["retrievable_messages"], rewrite)
    messages = with_reply_counts(source ++ supplemental)
    files = files(messages, base_url, cache_dir)

    users =
      messages
      |> Enum.uniq_by(& &1["user"])
      |> Enum.map(fn message ->
        %{
          "id" => message["user"],
          "name" => message["display_name"],
          "real_name" => message["display_name"],
          "is_bot" => message["actor_kind"] == "bot"
        }
      end)

    %{
      source_kind: :captured_collaboration,
      case_id: case_data["id"],
      scope:
        Map.take(authority, ~w(tenant_id group_id connect_id connect_generation workspace_id)),
      messages: messages,
      source_messages: Enum.filter(messages, &(&1["thread_ts"] == case_data["root_ts"])),
      files: files,
      users: users,
      web_documents: web_documents(case_data, cache_dir),
      root_ts: case_data["root_ts"],
      cutoff_ts: case_data["cutoff_ts"]
    }
  end

  def file_response(context, file_id) do
    case context.files[file_id] do
      %{body: body, metadata: metadata} when is_binary(body) ->
        {:ok, metadata, body}

      _ ->
        {:error, :local_fixture_file_not_captured}
    end
  end

  defp with_reply_counts(messages) do
    Enum.map(messages, fn message ->
      if message["ts"] == message["thread_ts"] do
        count =
          Enum.count(
            messages,
            &(&1["channel"] == message["channel"] and &1["thread_ts"] == message["ts"] and
                &1["ts"] != message["ts"])
          )

        Map.put(message, "reply_count", count)
      else
        message
      end
    end)
  end

  defp files(messages, base_url, cache_dir) do
    messages
    |> Enum.flat_map(&Map.get(&1, "files", []))
    |> Enum.uniq_by(& &1["id"])
    |> Map.new(fn file ->
      captured = @corpus["text_files"][file["id"]] || @corpus["binary_files"][file["id"]]

      body =
        cond do
          is_nil(captured) -> nil
          is_binary(captured["text"]) -> captured["text"]
          true -> read_cache!(cache_dir, captured["cache_name"])
        end

      metadata =
        file
        |> Map.take(~w(id name mimetype))
        |> Map.put("size", if(is_binary(body), do: byte_size(body), else: nil))
        |> Map.put(
          "url_private_download",
          String.trim_trailing(base_url, "/api") <> "/files/" <> file["id"]
        )

      {file["id"], %{metadata: metadata, body: body}}
    end)
  end

  defp web_documents(%{"id" => "article_bug_blindness"}, cache_dir) do
    [document] = @corpus["web_documents"]
    html = read_cache!(cache_dir, document["cache_name"])

    # Decode the captured document; never execute its scripts or embedded text.
    text = html |> LazyHTML.from_document() |> LazyHTML.query("body") |> LazyHTML.text()

    [
      %{
        "url" => document["url"],
        "title" => document["title"],
        "text" => text,
        "captured_at" => document["captured_at"],
        "historical_version_verified" => false
      }
    ]
  end

  defp web_documents(_case_data, _cache_dir), do: []

  defp read_cache!(nil, _name),
    do: raise("COMMA_TRIAGE_COLLABORATION_CACHE must select the captured private local cache")

  defp read_cache!(cache_dir, name) do
    if Path.basename(name) != name, do: raise("invalid fixture cache filename")
    File.read!(Path.join(cache_dir, name))
  end
end
