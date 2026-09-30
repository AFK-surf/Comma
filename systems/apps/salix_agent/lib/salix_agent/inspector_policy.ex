defmodule SalixAgent.InspectorPolicy do
  @moduledoc """
  Operator-owned capability restriction for internal inspection Workers.

  See docs/product-features.md for the authority boundary and
  operational-write exceptions. Unknown capabilities fail closed.
  """

  @local_reads ~w(help tool_call.get_result fs.read_file fs.list_files fs.grep fs.glob fs.stat_file)
  @discovery ~w(im.connects_list composio.list_connections composio.list_tools composio.get_tool)
  @unconstrained_reads @local_reads ++ @discovery
  @slack_reads ~w(im_api.slack.search im_api.slack.get_channel_history im_api.slack.get_thread_replies im_api.slack.get_user_info im_api.slack.get_channel_info)
  @artifact_writes ~w(fs.write_file fs.edit_file)
  @internal_read "im_api.internal.read_conversation"
  @internal_write "im_api.internal.send_message"
  @providers ~w(linear notion github)

  # Reuse the hosted adapter with exact bounded Project/Cycle documents;
  # model values remain GraphQL variables.
  # Schema source: https://github.com/linear/linear/blob/master/packages/sdk/src/schema.graphql
  @linear_queries %{
    "project" =>
      ~S|query InspectorProject($id: String!) { project(id: $id) { id name url description content startDate targetDate updatedAt status { id name } lead { id name } lastUpdate { id body updatedAt url } } }|,
    "project_updates" =>
      ~S|query InspectorProjectUpdates($id: String!, $after: String) { project(id: $id) { id projectUpdates(first: 5, after: $after, orderBy: updatedAt) { nodes { id body updatedAt url } pageInfo { hasNextPage endCursor } } } }|,
    "cycle" =>
      ~S|query InspectorCycle($id: String!) { cycle(id: $id) { id name number description startsAt endsAt completedAt updatedAt team { id name } } }|,
    "team_cycles" =>
      ~S|query InspectorTeamCycles($id: String!, $after: String) { team(id: $id) { id name cycles(first: 10, after: $after, orderBy: updatedAt) { nodes { id name number description startsAt endsAt completedAt updatedAt } pageInfo { hasNextPage endCursor } } } }|
  }

  # Reviewed hosted operations, not a name-prefix or provider safety heuristic.
  # Avoid unpaged workspace lists; the mixed Linear tool requires a fixed query.
  @provider_reads %{
    "LINEAR_GET_CURRENT_USER" => "linear",
    "LINEAR_GET_LINEAR_ISSUE" => "linear",
    "LINEAR_LIST_LINEAR_ISSUES" => "linear",
    "LINEAR_RUN_QUERY_OR_MUTATION" => "linear",
    "NOTION_GET_ABOUT_ME" => "notion",
    "NOTION_FETCH_BLOCK_CONTENTS" => "notion",
    "NOTION_FETCH_BLOCK_METADATA" => "notion",
    "NOTION_SEARCH_NOTION_PAGE" => "notion",
    "NOTION_QUERY_DATABASE" => "notion",
    "GITHUB_GET_THE_AUTHENTICATED_USER" => "github",
    "GITHUB_GET_A_REPOSITORY" => "github",
    "GITHUB_LIST_PULL_REQUESTS" => "github",
    "GITHUB_GET_A_PULL_REQUEST" => "github",
    "GITHUB_LIST_COMMITS" => "github"
  }

  def validate(nil, _record), do: :ok

  def validate(policy, record) when is_map(policy) do
    accounts = policy["composio_accounts"]
    connects = policy["slack_connect_ids"]

    if record["role"] == "worker" and
         get_in(record, ["runtime_config", "kind"]) in [nil, "internal"] and
         Enum.sort(Map.keys(policy)) ==
           ~w(artifact_root composio_accounts slack_connect_ids) and
         is_map(accounts) and Enum.sort(Map.keys(accounts)) == Enum.sort(@providers) and
         Enum.all?(Map.values(accounts), &present?/1) and
         is_list(connects) and length(connects) in 1..20 and Enum.all?(connects, &present?/1) and
         canonical_path?(policy["artifact_root"]) do
      :ok
    else
      invalid_policy()
    end
  end

  def validate(_policy, _record), do: invalid_policy()

  defp invalid_policy do
    {:error,
     {:bad_request,
      "inspector_policy requires an internal worker, one canonical artifact_root, " <>
        "1-20 slack_connect_ids and exact linear/notion/github composio_accounts"}}
  end

  def allowed_disclosure?(ctx, candidate) do
    case policy(ctx) do
      nil -> true
      p when is_map(p) -> disclosed?(candidate["name"])
      _ -> false
    end
  end

  def restricted?(ctx), do: policy(ctx) != nil

  @doc false
  def linear_queries, do: @linear_queries

  def describe(candidate, ctx) do
    case policy(ctx) do
      p when is_map(p) ->
        instruction = instructions(candidate["name"], p)

        candidate
        |> Map.update("summary", instruction, &(&1 <> "\n\n" <> instruction))
        |> Map.update("manual", instruction, &(&1 <> "\n\n" <> instruction))

      _ ->
        candidate
    end
  end

  def allowed_tool?(ctx, name, args) do
    case policy(ctx) do
      nil -> true
      p when is_map(p) and is_map(args) -> allowed?(name, args, p, ctx)
      _ -> false
    end
  end

  def refusal do
    "Inspector policy forbids this operation or target. Use the disclosed read operations, " <>
      "the pinned account, the private artifact root, and the current Task with " <>
      "delivery_filter.participant_ids=[] and no mentions. Record unsupported reads as " <>
      "coverage gaps; do not use execution, delegation or another connector as a bypass."
  end

  defp disclosed?(name) do
    name in (@local_reads ++
               @discovery ++
               @slack_reads ++
               @artifact_writes ++
               ["composio.execute", @internal_read, @internal_write])
  end

  defp allowed?(name, _args, _policy, _ctx) when name in @unconstrained_reads, do: true

  defp allowed?("composio.execute", args, policy, _ctx) do
    slug = args["tool_slug"]
    provider = @provider_reads[slug]
    account = get_in(policy, ["composio_accounts", provider])

    provider != nil and present?(account) and args["connected_account_id"] == account and
      is_map(args["arguments"]) and bounded_provider_read?(slug, args["arguments"])
  end

  defp allowed?(name, args, policy, _ctx) when name in @slack_reads do
    args["connect_id"] in policy["slack_connect_ids"]
  end

  defp allowed?(name, args, policy, _ctx) when name in @artifact_writes do
    path = args["path"]
    root = policy["artifact_root"]

    canonical_path?(path) and canonical_path?(root) and
      String.starts_with?(path, root <> "/")
  end

  defp allowed?(@internal_read, args, _policy, ctx), do: current_task?(args, ctx)

  defp allowed?(@internal_write, args, _policy, ctx) do
    current_task?(args, ctx) and args["delivery_filter"] == %{"participant_ids" => []} and
      args["mentions"] in [nil, []]
  end

  defp allowed?(_name, _args, _policy, _ctx), do: false

  defp current_task?(args, ctx) do
    case value(ctx, :trusted_origin) do
      %{"provider" => "internal", "conversation_kind" => "agent_task", "conversation_id" => id}
      when is_binary(id) and id != "" ->
        args["connect_id"] == "internal" and args["conversation_id"] == id

      _ ->
        false
    end
  end

  defp bounded_provider_read?("LINEAR_LIST_LINEAR_ISSUES", args) do
    present?(args["project_id"]) and bounded_page?(args, "first", 10, 100)
  end

  defp bounded_provider_read?("LINEAR_RUN_QUERY_OR_MUTATION", args) do
    query = args["query_or_mutation"]
    variables = args["variables"]

    Enum.sort(Map.keys(args)) == ~w(query_or_mutation variables) and
      query in Map.values(@linear_queries) and is_map(variables) and
      Map.keys(variables) -- ~w(id after) == [] and present?(variables["id"]) and
      (variables["after"] == nil or is_binary(variables["after"]))
  end

  defp bounded_provider_read?(slug, args)
       when slug in ~w(NOTION_FETCH_BLOCK_CONTENTS NOTION_SEARCH_NOTION_PAGE NOTION_QUERY_DATABASE),
       do: bounded_page?(args, "page_size", 100, 100)

  defp bounded_provider_read?(slug, args)
       when slug in ~w(GITHUB_LIST_PULL_REQUESTS GITHUB_LIST_COMMITS),
       do: bounded_page?(args, "per_page", 30, 100)

  defp bounded_provider_read?(_slug, _args), do: true

  defp bounded_page?(args, key, default, maximum) do
    size = args[key] || default
    is_integer(size) and size in 1..maximum
  end

  # VFS writes route reserved mounts before the ordinary Agent workspace.
  # Reject noncanonical paths instead of interpreting alternate path spellings.
  defp canonical_path?(path) when is_binary(path) do
    String.starts_with?(path, "/") and
      not String.starts_with?(path, ["/.runtime", "/.skills", "/.plugins"]) and
      not String.contains?(path, ["\\", <<0>>]) and
      Enum.all?(tl(String.split(path, "/")), &(&1 not in ["", ".", ".."])) and path != "/"
  end

  defp canonical_path?(_path), do: false

  defp instructions("composio.execute", policy) do
    "Inspector read operations: " <>
      Enum.map_join(Enum.sort(@provider_reads), ", ", fn {slug, _} -> slug end) <>
      ". Required connected_account_id by toolkit: " <>
      Jason.encode!(policy["composio_accounts"]) <>
      ". Linear issue lists require project_id; page sizes are at most 100. " <>
      "LINEAR_RUN_QUERY_OR_MUTATION accepts only these exact query_or_mutation documents " <>
      "with variables={id: <object ID>, after: <optional cursor>}: " <>
      Jason.encode!(@linear_queries) <>
      ". Do not edit the documents. Mutations, other queries and whole-workspace lists are unavailable."
  end

  defp instructions(name, policy) when name in @artifact_writes,
    do:
      "Inspector writes are limited to canonical descendants of " <>
        policy["artifact_root"] <> "/."

  defp instructions(@internal_write, _policy),
    do:
      "Inspector results require the current internal Task, delivery_filter={participant_ids: []}, and no mentions."

  defp instructions(_name, _policy), do: "Inspector read-only policy applies."

  defp policy(ctx) do
    case raw_policy(ctx) do
      nil ->
        nil

      p when is_map(p) ->
        if validate(p, %{"role" => "worker"}) == :ok, do: p, else: :invalid

      _ ->
        :invalid
    end
  end

  defp raw_policy(ctx) do
    case Map.fetch(ctx, :inspector_policy) do
      {:ok, policy} ->
        policy

      :error ->
        case value(ctx, :tool_disclosure) do
          disclosure when is_map(disclosure) -> disclosure["inspector_policy"]
          _ -> nil
        end
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
