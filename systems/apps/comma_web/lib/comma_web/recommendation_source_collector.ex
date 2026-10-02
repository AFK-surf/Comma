defmodule CommaWeb.RecommendationSourceCollector do
  @moduledoc false

  alias SalixAgent.DependencyJob
  alias Comma.RecommendationBudgets
  alias CommaWeb.{RecommendationMemberRead, RecommendationSourceCatalog}

  @max_data_bytes 12_000

  def collect(workspace, sources, opts \\ []) when is_map(workspace) and is_list(sources) do
    started = System.monotonic_time(:millisecond)

    selected =
      sources
      |> Enum.filter(&(&1["enabled"] == true))
      |> Enum.take(RecommendationBudgets.max_sources())

    now = Keyword.get(opts, :now, DateTime.utc_now())

    settings =
      if is_nil(opts[:member_user_id]) and Enum.any?(selected, &(&1["kind"] == "composio")),
        do: settings_store().settings(workspace["salix_tenant_id"]),
        else: {:ok, %{}}

    with {:ok, collection} <- collect_selected(selected, workspace, settings, now, opts) do
      {:ok, Map.put(collection, :duration_ms, System.monotonic_time(:millisecond) - started)}
    end
  end

  defp collect_selected([], _workspace, _settings, _now, _opts),
    do: {:ok, %{facts: [], failures: []}}

  defp collect_selected(sources, workspace, settings, now, opts) do
    max_concurrency =
      opts
      |> Keyword.get(:max_concurrency, RecommendationBudgets.max_source_concurrency())
      |> positive_integer(RecommendationBudgets.max_source_concurrency())
      |> min(RecommendationBudgets.max_source_concurrency())

    source_timeout_ms =
      opts
      |> Keyword.get(:source_timeout_ms, RecommendationBudgets.source_read_timeout_ms())
      |> positive_integer(RecommendationBudgets.source_read_timeout_ms())

    collection_timeout_ms =
      opts
      |> Keyword.get(
        :collection_timeout_ms,
        RecommendationBudgets.source_collection_timeout_ms()
      )
      |> positive_integer(RecommendationBudgets.source_collection_timeout_ms())

    waves = ceil_div(length(sources), max_concurrency)
    wave_timeout_ms = max(div(collection_timeout_ms, waves), 1)
    effective_timeout_ms = min(source_timeout_ms, wave_timeout_ms)
    collection_limited? = effective_timeout_ms < source_timeout_ms

    # Bounded fan-out: the product limits the number of selected sources and
    # concurrent reads. Dividing the collection deadline across the required
    # waves keeps the complete fan-out finite even when every provider stalls.
    # Linked wrappers own tool DependencyJobs. A provider crash returns a result;
    # wrapper cancellation makes admission stop the provider and release its slot.
    results =
      sources
      |> Task.async_stream(
        fn source ->
          # Member reads return what they read before the job is stopped.
          deadline = RecommendationMemberRead.deadline(effective_timeout_ms)

          with {:ok, job} <-
                 DependencyJob.start(
                   :tool,
                   workspace["salix_tenant_id"],
                   fn ->
                     collect_selected_source(
                       source,
                       workspace,
                       settings,
                       now,
                       opts[:member_user_id],
                       deadline
                     )
                   end,
                   timeout_ms: effective_timeout_ms
                 ) do
            case DependencyJob.yield(job, :infinity) do
              {:ok, result} ->
                result

              {:exit, {:dependency_timeout, :tool}} when collection_limited? ->
                {:error, :collection_deadline_exceeded}

              {:exit, reason} ->
                {:error, {:collector_exit, reason}}
            end
          end
        end,
        max_concurrency: max_concurrency,
        ordered: true,
        on_timeout: :kill_task,
        timeout: effective_timeout_ms
      )
      |> Enum.to_list()

    {facts, failures} =
      sources
      |> Enum.zip(results)
      |> Enum.reduce({[], []}, fn
        {source, {:ok, {:ok, fact, warnings}}}, {facts, failures} ->
          {[fact | facts], Enum.map(warnings, &failure(source, &1)) ++ failures}

        {_source, {:ok, {:ok, fact}}}, {facts, failures} ->
          {[fact | facts], failures}

        {source, {:ok, {:error, reason}}}, {facts, failures} ->
          {facts, [failure(source, reason) | failures]}

        {source, {:exit, :timeout}}, {facts, failures} when collection_limited? ->
          {facts, [failure(source, :collection_deadline_exceeded) | failures]}

        {source, {:exit, reason}}, {facts, failures} ->
          {facts, [failure(source, {:collector_exit, reason}) | failures]}
      end)

    {:ok,
     %{
       facts: Enum.sort_by(facts, & &1["sourceId"]),
       failures: Enum.sort_by(failures, & &1["sourceId"])
     }}
  end

  defp collect_selected_source(source, workspace, settings, now, nil, _deadline),
    do: collect_source(source, workspace, settings, now)

  defp collect_selected_source(source, workspace, _settings, now, user_id, deadline) do
    with {:ok, data, subject} <-
           read_member(workspace, user_id, source, now, deadline) do
      {warnings, data} = Map.pop(data, :source_warnings, [])
      {data, contexts} = CommaWeb.RecommendationSourceContext.separate(data)
      {bounded, bound} = bound_data_with_counts(data)

      {:ok,
       %{
         "appId" => source["appId"],
         "appName" => source["appName"],
         "collectedAt" => DateTime.to_unix(now, :millisecond),
         "data" => bounded,
         "bound" => bound,
         "sourceId" => source["connectionId"],
         "toolkit" => source["appId"],
         "toolSlug" => "member." <> source["appId"],
         "contexts" => CommaWeb.RecommendationSourceContext.retain(contexts, bounded),
         "memberSubject" => subject
       }, warnings}
    end
  end

  defp read_member(workspace, user_id, %{"kind" => "composio"} = source, now, deadline),
    do:
      CommaWeb.RecommendationComposioMemberSource.read(workspace, user_id, source, now, deadline)

  defp read_member(workspace, user_id, source, _now, deadline),
    do: CommaWeb.RecommendationOAuthSource.read_member(workspace, user_id, source, deadline)

  defp collect_source(%{"kind" => "composio"} = source, workspace, {:ok, settings}, now) do
    toolkit = clean(source["toolkit"] || source["appId"])

    with {:ok, {tool_slug, arguments}} <- RecommendationSourceCatalog.recipe(toolkit, now),
         {:ok, envelope} <-
           composio_client().execute_tool(
             settings,
             tool_slug,
             workspace["default_group_id"],
             arguments,
             connected_account_id: source["connectionId"],
             error_mode: :structured
           ),
         {:ok, data} <- successful_data(envelope) do
      {bounded, bound} = data |> linked_data(toolkit) |> bound_data_with_counts()

      {:ok,
       %{
         "appId" => source["appId"],
         "appName" => source["appName"],
         "bound" => bound,
         "collectedAt" => DateTime.to_unix(now, :millisecond),
         "data" => bounded,
         "sourceId" => source["connectionId"],
         "toolkit" => toolkit,
         "toolSlug" => tool_slug
       }}
    end
  end

  defp collect_source(%{"kind" => "composio"}, _workspace, {:error, reason}, _now),
    do: {:error, reason}

  defp collect_source(%{"kind" => "managed_oauth"} = source, workspace, _settings, now) do
    with {:ok, data} <- CommaWeb.RecommendationOAuthSource.read(workspace, source) do
      {bounded, bound} = data |> linked_data(source["appId"]) |> bound_data_with_counts()

      {:ok,
       %{
         "appId" => source["appId"],
         "appName" => source["appName"],
         "bound" => bound,
         "collectedAt" => DateTime.to_unix(now, :millisecond),
         "data" => bounded,
         "sourceId" => source["connectionId"],
         "toolkit" => source["appId"],
         "toolSlug" => "oauth." <> source["appId"]
       }}
    end
  end

  defp collect_source(source, _workspace, _settings, _now),
    do: {:error, {:unsupported_source_kind, source["kind"]}}

  # Publication evidence only admits URLs that literally appear inside the
  # fact data. Gmail and Notion reads return no self-referencing URL, and
  # GitHub notifications only carry api.github.com subject URLs, so those
  # records could never be cited as inline-links. Derive each record's stable
  # web link here to make it citable — and slim the platforms whose records
  # arrive with unbounded payloads so every record's link survives the fact
  # byte budget.
  defp linked_data(%{"messages" => messages} = data, "gmail") when is_list(messages),
    do: Map.put(data, "messages", Enum.map(messages, &gmail_message/1))

  defp linked_data(%{"values" => pages} = data, "notion") when is_list(pages),
    do: Map.put(data, "values", Enum.map(pages, &notion_page/1))

  defp linked_data(%{"files" => files} = data, "googledrive") when is_list(files),
    do: Map.put(data, "files", Enum.map(files, &drive_file/1))

  defp linked_data(data, "github") do
    Enum.reduce(["notifications", "details"], data, fn key, acc ->
      case acc do
        %{^key => notifications} when is_list(notifications) ->
          Map.put(acc, key, Enum.map(notifications, &github_notification/1))

        _ ->
          acc
      end
    end)
  end

  # Slack search matches carry their own citable `permalink`, but each match
  # also drags rich blocks, attachments, surrounding-context messages, and a
  # dozen channel flags — routinely more than the whole fact budget. Keep only
  # the fields the renderer contract names (channel, sender, timestamp, text,
  # permalink) so every message stays citable.
  defp linked_data(data, "slack") do
    case data do
      %{"messages" => %{"matches" => matches} = messages} when is_list(matches) ->
        Map.put(
          data,
          "messages",
          Map.put(messages, "matches", Enum.map(matches, &slack_match/1))
        )

      _ ->
        data
    end
  end

  # Calendar events carry their citable `htmlLink` themselves; bound their
  # one unbounded prose field so a verbose agenda cannot starve later events
  # out of the fact budget.
  defp linked_data(%{"items" => events} = data, "googlecalendar") when is_list(events),
    do: Map.put(data, "items", Enum.map(events, &excerpt_field(&1, "description")))

  defp linked_data(data, _toolkit), do: data

  # Full message bodies routinely blow the fact byte budget; a bounded excerpt
  # keeps every record inside the bound with room for its link.
  @body_excerpt_chars 300

  defp gmail_message(%{} = message) do
    id = message["messageId"] || message["id"] || message["threadId"]

    message
    |> put_web_url(id, "https://mail.google.com/mail/#all/")
    |> Map.delete("payload")
    |> excerpt_field("messageText")
  end

  defp gmail_message(message), do: message

  @slack_match_keys ~w(iid team type user username ts text permalink)

  defp slack_match(%{} = match) do
    slimmed = Map.take(match, @slack_match_keys)

    slimmed =
      case match["channel"] do
        %{} = channel -> Map.put(slimmed, "channel", Map.take(channel, ~w(id name)))
        _ -> slimmed
      end

    excerpt_field(slimmed, "text")
  end

  defp slack_match(match), do: match

  defp excerpt_field(message, key) do
    case message do
      %{^key => text} when is_binary(text) ->
        if String.length(text) > @body_excerpt_chars do
          Map.put(message, key, String.slice(text, 0, @body_excerpt_chars) <> "…")
        else
          message
        end

      _ ->
        message
    end
  end

  defp notion_page(%{"id" => id} = page) when is_binary(id) do
    hex = id |> String.replace("-", "") |> String.downcase()

    if hex =~ ~r/^[0-9a-f]{32}$/ do
      Map.put_new(page, "webUrl", "https://www.notion.so/#{hex}")
    else
      page
    end
  end

  defp notion_page(page), do: page

  defp github_notification(%{"subject" => %{"url" => api_url}} = notification)
       when is_binary(api_url) do
    case Regex.run(
           ~r{^https://api\.github\.com/repos/([\w.-]+)/([\w.-]+)/(pulls|issues)/(\d+)$},
           api_url
         ) do
      [_, owner, repo, "pulls", number] ->
        Map.put_new(notification, "webUrl", "https://github.com/#{owner}/#{repo}/pull/#{number}")

      [_, owner, repo, "issues", number] ->
        Map.put_new(
          notification,
          "webUrl",
          "https://github.com/#{owner}/#{repo}/issues/#{number}"
        )

      nil ->
        notification
    end
  end

  defp github_notification(notification), do: notification

  defp drive_file(%{"webViewLink" => link} = file) when is_binary(link), do: file

  defp drive_file(%{"id" => id} = file) when is_binary(id),
    do: put_web_url(file, id, "https://drive.google.com/open?id=")

  defp drive_file(file), do: file

  defp put_web_url(record, id, prefix) do
    if is_binary(id) and id =~ ~r/^[A-Za-z0-9_-]+$/ do
      Map.put_new(record, "webUrl", prefix <> id)
    else
      record
    end
  end

  defp successful_data(%{"successful" => true, "data" => data}) when is_map(data), do: {:ok, data}

  defp successful_data(%{"successful" => false} = envelope),
    do: {:error, {:provider_failed, envelope["error"] || "provider returned unsuccessful"}}

  defp successful_data(_envelope), do: {:error, :invalid_provider_response}

  # The byte bound keeps list order and cuts from the tail. The counts tell how
  # many provider records the model reads whole: a record cut down to its link
  # or to an empty object counts as dropped.
  defp bound_data_with_counts(data) do
    encoded = Jason.encode!(data)
    normalized = Jason.decode!(encoded)
    original_bytes = byte_size(encoded)

    if original_bytes <= @max_data_bytes do
      kept = record_count(normalized)
      {normalized, bound_counts(original_bytes, false, kept, kept)}
    else
      metadata = %{"originalBytes" => original_bytes, "truncated" => true}
      wrapper_with_nil = %{"_comma" => metadata, "value" => nil}
      wrapper_overhead = byte_size(Jason.encode!(wrapper_with_nil)) - byte_size("null")
      value_budget = @max_data_bytes - wrapper_overhead
      {bounded, _encoded_bytes, _truncated?} = bound_json(normalized, value_budget)

      {%{"_comma" => metadata, "value" => bounded},
       bound_counts(
         original_bytes,
         true,
         record_count(normalized),
         intact_record_count(normalized, bounded)
       )}
    end
  end

  defp bound_counts(original_bytes, truncated?, records, kept) do
    %{
      "originalBytes" => original_bytes,
      "truncated" => truncated?,
      "kept" => kept,
      "dropped" => records - kept
    }
  end

  # A record is a map in a provider list. A list inside a record is one of its
  # fields, not more records.
  defp record_count(value) when is_map(value),
    do: value |> Map.values() |> Enum.map(&record_count/1) |> Enum.sum()

  defp record_count(value) when is_list(value), do: Enum.count(value, &is_map/1)
  defp record_count(_value), do: 0

  defp intact_record_count(original, bounded) when is_map(original) and is_map(bounded) do
    original
    |> Enum.map(fn {key, value} -> intact_record_count(value, Map.get(bounded, key)) end)
    |> Enum.sum()
  end

  defp intact_record_count(original, bounded) when is_list(original) and is_list(bounded) do
    original
    |> Enum.zip(bounded)
    |> Enum.count(fn {record, bounded_record} -> is_map(record) and record == bounded_record end)
  end

  defp intact_record_count(_original, _bounded), do: 0

  # When an object exceeds its budget, later-sorted keys are dropped first.
  # Admit the known record-link keys ahead of everything else so truncation
  # eats prose and metadata before it can eat a record's citable URL — an
  # inline-link is only publishable while its URL literally appears in the
  # fact data.
  @link_keys ~w(htmlLink html_url permalink url webUrl webViewLink)

  defp bound_json(value, budget) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} ->
      key = to_string(key)
      {if(key in @link_keys, do: 0, else: 1), key}
    end)
    |> Enum.reduce_while({%{}, 2, false, 0}, fn {key, child}, {result, used, truncated, count} ->
      encoded_key = Jason.encode!(to_string(key))
      separator_bytes = if count == 0, do: 1, else: 2
      child_budget = budget - used - byte_size(encoded_key) - separator_bytes

      if child_budget < 2 do
        {:halt, {result, used, true, count}}
      else
        case bound_json(child, child_budget) do
          :omit ->
            {:halt, {result, used, true, count}}

          {bounded_child, child_bytes, child_truncated?} ->
            {:cont,
             {
               Map.put(result, to_string(key), bounded_child),
               used + byte_size(encoded_key) + separator_bytes + child_bytes,
               truncated or child_truncated?,
               count + 1
             }}
        end
      end
    end)
    |> then(fn {bounded, used, truncated, count} ->
      {bounded, used, truncated or count < map_size(value)}
    end)
  end

  defp bound_json(value, budget) when is_list(value) do
    value
    |> Enum.reduce_while({[], 2, false, 0}, fn child, {result, used, truncated, count} ->
      separator_bytes = if count == 0, do: 0, else: 1
      child_budget = budget - used - separator_bytes

      if child_budget < 2 do
        {:halt, {result, used, true, count}}
      else
        case bound_json(child, child_budget) do
          :omit ->
            {:halt, {result, used, true, count}}

          {bounded_child, child_bytes, child_truncated?} ->
            {:cont,
             {
               [bounded_child | result],
               used + separator_bytes + child_bytes,
               truncated or child_truncated?,
               count + 1
             }}
        end
      end
    end)
    |> then(fn {bounded, used, truncated, count} ->
      {Enum.reverse(bounded), used, truncated or count < length(value)}
    end)
  end

  defp bound_json(value, budget) when is_binary(value) do
    encoded_bytes = byte_size(Jason.encode!(value))

    cond do
      encoded_bytes <= budget -> {value, encoded_bytes, false}
      byte_size(Jason.encode!("[truncated]")) <= budget -> {"[truncated]", 13, true}
      budget >= 2 -> {"", 2, true}
      true -> :omit
    end
  end

  defp bound_json(value, budget) when is_number(value) or is_boolean(value) or is_nil(value) do
    encoded_bytes = byte_size(Jason.encode!(value))
    if encoded_bytes <= budget, do: {value, encoded_bytes, false}, else: :omit
  end

  @reconnect_codes ~w(missing_scope invalid_auth not_authed token_revoked token_expired account_inactive)
  # `Salix.Bindings.MCPCredentials` reports an unusable grant as text.
  @reconnect_credential_errors [
    "requires reauthorization",
    "is revoked",
    "is missing required scopes"
  ]

  defp failure(source, reason) do
    %{
      "appId" => source["appId"],
      "class" => failure_class(reason),
      "message" => reason |> inspect() |> String.slice(0, 240),
      "sourceId" => source["connectionId"]
    }
  end

  defp failure_class(reason)
       when reason in [
              :member_identity_unavailable,
              :member_identity_or_source_unavailable,
              :member_source_identity_mismatch,
              :member_source_changed
            ],
       do: "identity"

  # Only the member can fix these, by reconnecting the source in Plugins: the
  # grant lacks a scope, or the provider rejects or revoked the token.
  defp failure_class({:member_provider_error, code}) when code in @reconnect_codes,
    do: "reconnect"

  defp failure_class({kind, 401}) when kind in [:member_provider_http, :oauth_provider_http],
    do: "reconnect"

  defp failure_class(reason) when is_binary(reason) do
    if String.contains?(reason, @reconnect_credential_errors), do: "reconnect", else: "read"
  end

  defp failure_class(_), do: "read"

  defp settings_store,
    do:
      Application.get_env(
        :comma_web,
        :recommendation_composio_settings_mod,
        SalixAgent.ComposioStore
      )

  defp composio_client,
    do:
      Application.get_env(
        :comma_web,
        :recommendation_composio_client_mod,
        Application.get_env(:salix_agent, :composio_client_mod, SalixStore.Composio)
      )

  defp clean(nil), do: ""
  defp clean(value), do: value |> to_string() |> String.trim() |> String.downcase()
  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)
end
