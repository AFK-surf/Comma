defmodule CommaWeb.RecommendationNotionMemberSource do
  @moduledoc false

  alias CommaWeb.RecommendationMemberRead

  @api "https://api.notion.com/v1"
  @headers [{"notion-version", "2025-09-03"}, {"user-agent", "Comma"}]
  @recent_seconds 7 * 24 * 3600
  @databases 5
  @items_per_database 20
  @tasks 40
  @documents 5
  # The outline and text tail fit the 1,200-byte record context with its labels.
  @outline_bytes 180
  @tail_bytes 850

  # Direct member relationships, found without configuration: comments that
  # mention the member, open items that name the member in a task database,
  # and pages the member last edited or started within seven days. Notion
  # throttles bursts, so each read that fails leaves the others readable.
  def read(identity, request, now \\ DateTime.utc_now()) do
    with {:ok, self} <- request.("notion_self", :get, @api <> "/users/me", headers: @headers),
         {:ok, user} <- member(self, identity) do
      [sources, pages] =
        RecommendationMemberRead.map(~w(data_source page), &search(request, &1), 2)

      {tasks, task_failures} = tasks(sources, user, request)
      {documents, document_failures} = documents(pages, user, request, now)
      {mentions, mention_failures} = comment_mentions(pages, user, request, now)

      if match?({:error, _}, sources) and match?({:error, _}, pages) do
        sources
      else
        {:ok,
         RecommendationMemberRead.warn(
           %{
             "values" => Enum.uniq_by(mentions ++ tasks ++ documents, & &1["id"]),
             "memberRelation" => "involves_or_edited_by_you"
           },
           for({:error, reason} <- [sources, pages], do: reason) ++
             task_failures ++ document_failures ++ mention_failures
         )}
      end
    end
  end

  # One bounded page of the most recently edited data sources or pages.
  defp search(request, object) do
    case request.("notion", :post, @api <> "/search",
           headers: @headers,
           json: %{
             "filter" => %{"property" => "object", "value" => object},
             "sort" => %{"timestamp" => "last_edited_time", "direction" => "descending"},
             "page_size" => 100
           }
         ) do
      {:ok, %{"values" => values}} when is_list(values) -> {:ok, values}
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_response}
    end
  end

  defp member(
         %{"bot" => %{"owner" => %{"type" => "user", "user" => %{"id" => user}}}},
         %{"provider_user_id" => user}
       ),
       do: {:ok, user}

  defp member(_self, _identity), do: {:error, :member_source_identity_mismatch}

  # A task database has a people property and a Notion status property. An open
  # item names the member in a people property and has a status outside the
  # Complete group. Property names are not interpreted: the name that lists the
  # member reaches the Router as the member's role.
  defp tasks({:ok, sources}, user, request) do
    results =
      sources
      |> Enum.flat_map(&task_database/1)
      |> Enum.take(@databases)
      # Notion documents an average of three requests per second.
      |> RecommendationMemberRead.map(
        fn database ->
          {database,
           request.("notion", :post, @api <> "/data_sources/#{database.id}/query",
             headers: @headers,
             json: open_items_query(database, user)
           )}
        end,
        3
      )

    tasks =
      for {database, {:ok, %{"values" => pages}}} when is_list(pages) <- results,
          page <- pages,
          task <- open_item(page, database, user),
          do: task

    {tasks |> Enum.uniq_by(& &1["id"]) |> Enum.take(@tasks), failures(results)}
  end

  defp tasks(_sources, _user, _request), do: {[], []}

  # A read that returned no usable list is reported; the others are kept.
  defp failures(results) do
    for {_item, response} <- results,
        not match?({:ok, %{"values" => values}} when is_list(values), response) do
      case response do
        {:error, reason} -> reason
        _ -> :invalid_provider_response
      end
    end
  end

  defp task_database(%{"id" => id, "properties" => properties} = source)
       when is_binary(id) and is_map(properties) do
    people =
      for {name, %{"type" => "people", "id" => property}} <- properties,
          is_binary(property),
          do: {property, name}

    open =
      for {_name, %{"type" => "status", "id" => property} = value} <- properties,
          is_binary(property),
          option <- open_options(value["status"]),
          do: {property, option}

    if source["archived"] != true and source["in_trash"] != true and people != [] and
         open != [],
       do: [%{id: id, people: Enum.take(people, 10), open: Enum.take(open, 40)}],
       else: []
  end

  defp task_database(_source), do: []

  # Notion keeps the To-do, In progress and Complete groups in that order.
  defp open_options(%{"options" => options} = status) when is_list(options) do
    done =
      case List.last(status["groups"] || []) do
        %{"option_ids" => ids} when is_list(ids) -> MapSet.new(ids)
        _ -> MapSet.new()
      end

    for %{"id" => id, "name" => name} <- options,
        is_binary(name),
        not MapSet.member?(done, id),
        do: name
  end

  defp open_options(_status), do: []

  defp open_items_query(database, user) do
    %{
      "page_size" => @items_per_database,
      "sorts" => [%{"timestamp" => "last_edited_time", "direction" => "descending"}],
      "filter" => %{
        "and" => [
          %{
            "or" =>
              for(
                {property, _name} <- database.people,
                do: %{"property" => property, "people" => %{"contains" => user}}
              )
          },
          %{
            "or" =>
              for(
                {property, option} <- database.open,
                do: %{"property" => property, "status" => %{"equals" => option}}
              )
          }
        ]
      }
    }
  end

  defp open_item(%{"properties" => properties} = page, database, user)
       when is_map(properties) do
    values = Map.values(properties)

    roles =
      for {property, name} <- database.people,
          value = Enum.find(values, &(&1["id"] == property)),
          is_map(value) and is_list(value["people"]),
          Enum.any?(value["people"], &(is_map(&1) and &1["id"] == user)),
          do: name

    status =
      Enum.find_value(database.open, fn {property, option} ->
        value = Enum.find(values, &(&1["id"] == property))
        if get_in(value || %{}, ["status", "name"]) == option, do: option
      end)

    if page["archived"] != true and page["in_trash"] != true and is_binary(page["id"]) and
         is_binary(page["url"]) and get_in(page, ["parent", "data_source_id"]) == database.id and
         roles != [] and is_binary(status) do
      [
        page
        |> Map.put("role", Enum.join(roles, ", "))
        |> Map.put("status", status)
        |> CommaWeb.RecommendationSourceContext.attach(~w(role status last_edited_time))
        |> Map.take(~w(id url context))
        |> Map.put("title", title(page))
        |> Map.put("memberRelation", "involves_you")
      ]
    else
      []
    end
  end

  defp open_item(_page, _database, _user), do: []

  # Search sorts by edit time but cannot filter by editor or commenter, so one
  # bounded page of recent edits serves both documents and comment mentions.
  # Each document keeps its outline and the end of its top-level text: where
  # the member stopped writing.
  defp documents({:ok, pages}, user, request, now) do
    results =
      pages
      |> Enum.filter(&recent_document?(&1, user, now))
      |> Enum.take(@documents)
      |> RecommendationMemberRead.map(
        fn page ->
          {page,
           request.("notion", :get, @api <> "/blocks/#{page["id"]}/children",
             headers: @headers,
             params: [page_size: 100]
           )}
        end,
        3
      )

    documents =
      for {page, {:ok, %{"values" => blocks}}} when is_list(blocks) <- results,
          do: document(page, blocks)

    {documents, failures(results)}
  end

  defp documents(_pages, _user, _request, _now), do: {[], []}

  # Open comments that mention the member on the five most recently edited
  # pages. A page without comment access contributes none. Other failures are
  # reported, because they leave mentions unread.
  defp comment_mentions({:ok, pages}, user, request, now) do
    results =
      pages
      |> Enum.filter(fn page ->
        page["archived"] != true and page["in_trash"] != true and is_binary(page["id"]) and
          is_binary(page["url"]) and recent?(page["last_edited_time"], now)
      end)
      |> Enum.take(5)
      |> RecommendationMemberRead.map(
        fn page ->
          {page,
           request.("notion", :get, @api <> "/comments",
             headers: @headers,
             params: [block_id: page["id"], page_size: 100]
           )}
        end,
        3
      )

    mentions =
      results
      |> Enum.flat_map(fn
        {page, {:ok, %{"values" => comments}}} when is_list(comments) ->
          comments
          |> Enum.filter(&mentions_member?(&1, user, now))
          |> Enum.group_by(& &1["discussion_id"])
          |> Enum.map(fn {_discussion, found} -> Enum.max_by(found, & &1["created_time"]) end)
          |> Enum.map(&comment_mention(page, &1))

        _unreadable ->
          []
      end)
      |> Enum.take(10)

    {mentions,
     Enum.reject(
       failures(results),
       &match?({:oauth_provider_http, status} when status in [403, 404], &1)
     )}
  end

  defp comment_mentions(_pages, _user, _request, _now), do: {[], []}

  defp mentions_member?(comment, user, now) do
    is_map(comment) and is_binary(comment["id"]) and is_binary(comment["discussion_id"]) and
      get_in(comment, ["created_by", "id"]) != user and recent?(comment["created_time"], now) and
      Enum.any?(List.wrap(comment["rich_text"]), &(get_in(&1, ["mention", "user", "id"]) == user))
  end

  defp comment_mention(page, comment) do
    %{
      "id" => comment["id"],
      "url" => page["url"] <> "?d=" <> String.replace(comment["discussion_id"], "-", ""),
      "title" => title(page),
      "mention" => comment["rich_text"] |> Enum.map_join(&(&1["plain_text"] || "")),
      "memberRelation" => "mentioned_you"
    }
    |> CommaWeb.RecommendationSourceContext.attach(~w(mention))
    |> Map.delete("mention")
  end

  defp recent_document?(page, user, now) do
    page["archived"] != true and page["in_trash"] != true and is_binary(page["id"]) and
      is_binary(page["url"]) and
      ((get_in(page, ["last_edited_by", "id"]) == user and recent?(page["last_edited_time"], now)) or
         (get_in(page, ["created_by", "id"]) == user and recent?(page["created_time"], now)))
  end

  defp recent?(timestamp, now) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, time, _} -> DateTime.diff(now, time) <= @recent_seconds
      _ -> false
    end
  end

  defp recent?(_timestamp, _now), do: false

  defp document(page, blocks) do
    texts = Enum.map(blocks, &{&1["type"], block_text(&1)})

    outline =
      for {type, text} <- texts, type in ~w(heading_1 heading_2 heading_3), text != "", do: text

    body = for {_type, text} <- texts, text != "", do: text

    page
    |> Map.put("outline", outline |> Enum.join(" / ") |> head(@outline_bytes))
    |> Map.put("content", body |> Enum.join("\n") |> tail(@tail_bytes))
    |> CommaWeb.RecommendationSourceContext.attach(~w(last_edited_time outline content))
    |> Map.take(~w(id url context))
    |> Map.put("title", title(page))
    |> Map.put("memberRelation", "edited_by_you")
  end

  defp block_text(%{"type" => "to_do", "to_do" => %{"checked" => checked} = data}),
    do: if(checked == true, do: "[x] ", else: "[ ] ") <> rich_text(data)

  defp block_text(%{"type" => type} = block) when is_binary(type), do: rich_text(block[type])
  defp block_text(_block), do: ""

  defp rich_text(%{"rich_text" => parts}) when is_list(parts),
    do: parts |> Enum.map_join(&(&1["plain_text"] || "")) |> String.trim()

  defp rich_text(_data), do: ""

  defp title(page) do
    (page["properties"] || %{})
    |> Map.values()
    |> Enum.find(%{}, &(&1["type"] == "title"))
    |> Map.get("title", [])
  end

  defp head(text, bytes) when byte_size(text) <= bytes, do: text
  defp head(text, bytes), do: valid_head(binary_part(text, 0, bytes)) <> "…"

  defp tail(text, bytes) when byte_size(text) <= bytes, do: text

  defp tail(text, bytes),
    do: "…" <> valid_tail(binary_part(text, byte_size(text) - bytes, bytes))

  defp valid_head(value),
    do:
      if(String.valid?(value),
        do: value,
        else: valid_head(binary_part(value, 0, byte_size(value) - 1))
      )

  defp valid_tail(value),
    do:
      if(String.valid?(value),
        do: value,
        else: valid_tail(binary_part(value, 1, byte_size(value) - 1))
      )
end
