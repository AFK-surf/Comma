defmodule SalixAgent.Tools.Composio do
  @moduledoc """
  Composio integration tools — the direct agent-accessible path to third-party
  providers, running ALONGSIDE the managed OAuth tools (`SalixAgent.Tools.OAuth`).

  Where managed OAuth resolves a stored token into an env var for a sandboxed
  `env.exec` command, these tools call the provider through Composio's hosted
  tool catalog (`POST /api/v3/tools/execute/{slug}`) and return the result
  inline — no VM round-trip. Common reads like "fetch my Gmail inbox" or
  "list today's calendar events" become a single `composio.execute` call.

  Scoping and gating:

    * The Composio `user_id` is the agent's **group id**, so connections are
      shared group-wide exactly like managed OAuth bindings, and a group can
      never see another group's accounts (list filters by user id; get/delete
      verify ownership before acting).
    * Every tool first resolves the tenant's Composio settings through the
      `SalixAgent.ComposioStore` seam; tenants that have not opted in get a
      "not configured" error and the managed OAuth path remains the only one.
    * Connection flows use Composio-hosted Connect Links: the tool returns the
      URL for the agent to post to the user (same contract as
      `oauth.request_authorization` — never surfaced automatically) plus a
      `wait_set` session event (source `"composio_connection"`), so the idle
      session shows as waiting until the user's next message or the wait
      timer wakes the agent to poll `composio.check_connection`. Completion
      happens entirely on Composio's side (no callback into this runtime),
      which is why this is a wait + poll rather than an async tool call.
      Token exchange, storage, and refresh all stay inside Composio; tokens
      never enter this runtime.

  The HTTP client is `SalixStore.Composio`, overridable for tests via the
  `:composio_client_mod` app env (same seam pattern as `:oauth_adapters_fn`).
  """

  alias SalixAgent.{ComposioStore, OAuthStore, Waits}
  alias SalixAgent.Tools.AsyncPolicy

  @normal_auto_wait_seconds AsyncPolicy.normal_tool_auto_wait_seconds()
  @user_interaction_auto_wait_seconds AsyncPolicy.user_interaction_tool_auto_wait_seconds()

  # Keep tool-catalog listings bounded. Execution results remain lossless here;
  # Round applies the shared model-envelope budget and stores oversized results
  # behind a session-owned opaque ref before the next LLM request.
  @default_list_limit 20
  @max_list_limit 50
  @description_max_chars 300
  @connected_accounts_page_limit 100
  @connected_accounts_max_pages 10
  @external_side_effect_opts [safety: "write"]

  alias SalixAgent.IFC.ConnectorLabels

  @doc "Tool defs in canonical registry order."
  @spec defs() ::
          [
            {String.t(), String.t(), (map(), map() -> term()), pos_integer()}
            | {String.t(), String.t(), (map(), map() -> term()), pos_integer(), keyword()}
          ]
  def defs do
    [
      {"composio.list_connections",
       "List this agent group's Composio connected accounts.\n\n" <>
         "Returns one entry per connected account with its toolkit (provider), status, and connected_account_id. " <>
         "Only ACTIVE accounts can serve composio.execute calls. " <>
         "Requires the tenant to have Composio configured; otherwise use the oauth.* tools.",
       &__MODULE__.list_connections/2, @normal_auto_wait_seconds},
      {"composio.request_connection",
       "Connect a third-party toolkit (e.g. gmail, googlecalendar, notion, linear) for this agent group via Composio.\n\n" <>
         "Returns a hosted Connect Link URL and sets a session wait until the user completes it. " <>
         "The URL is NOT surfaced automatically: you must post it to the requester yourself through the current visible reply path. For an internal Comma conversation, use call(tool=\"im_api.internal.send_message\", params={...}) with connect_id=\"internal\" inside params. For an external provider, call the matching im_api.* operation directly when provider/connect/API are known; use IM discovery/help only when those facts are missing. " <>
         "Ask the user to complete the browser flow, then verify with composio.check_connection using the returned connected_account_id. " <>
         "No per-provider OAuth app setup is needed. Unsure of the toolkit slug? Search with composio.list_toolkits first.",
       &__MODULE__.request_connection/2, @user_interaction_auto_wait_seconds,
       @external_side_effect_opts},
      {"composio.check_connection",
       "Check whether a Composio connection started by composio.request_connection is ready.\n\n" <>
         "Returns status=active once the user finishes the browser flow, status=pending while they have not, " <>
         "or status=failed with the provider status otherwise. Idempotent.",
       &__MODULE__.check_connection/2, @normal_auto_wait_seconds},
      {"composio.delete_connection",
       "Delete (disconnect) one of this agent group's Composio connected accounts.\n\n" <>
         "Identify it by connected_account_id (as returned by composio.list_connections). Idempotent: " <>
         "deleting an unknown account returns status=not_found.", &__MODULE__.delete_connection/2,
       @normal_auto_wait_seconds},
      {"composio.list_tools",
       "Search Composio's tool catalog for a connected toolkit.\n\n" <>
         "Filter by toolkit slug (e.g. gmail) and/or a full-text query (e.g. \"fetch emails\"). " <>
         "Returns tool slugs with short descriptions; call composio.get_tool for a tool's full input schema before executing it.",
       &__MODULE__.list_tools/2, @normal_auto_wait_seconds},
      {"composio.get_tool",
       "Fetch one Composio tool's full definition, including its input_parameters JSON schema.\n\n" <>
         "Use the schema to build the arguments for composio.execute.", &__MODULE__.get_tool/2,
       @normal_auto_wait_seconds},
      {"composio.execute",
       "Execute a Composio tool for this agent group and return the provider data inline.\n\n" <>
         "Examples: tool_slug=GMAIL_FETCH_EMAILS to read Gmail, tool_slug=GOOGLECALENDAR_EVENTS_LIST to read Google Calendar. " <>
         "arguments must match the tool's input_parameters (see composio.get_tool). " <>
         "The toolkit must have an ACTIVE connected account (composio.list_connections); " <>
         "successful=false in the result is a provider-level failure such as missing scopes, not a runtime error.",
       &__MODULE__.execute/2, @normal_auto_wait_seconds, @external_side_effect_opts},
      {"composio.list_toolkits",
       "Search Composio's toolkit catalog (~300 connectable services) by name.\n\n" <>
         "Use this to find the toolkit slug for composio.request_connection or composio.list_tools when it is not obvious " <>
         "(common slugs: gmail, googlecalendar, googledrive, notion, linear, slack, github).",
       &__MODULE__.list_toolkits_catalog/2, @normal_auto_wait_seconds}
    ]
  end

  # ---- composio.list_connections ----

  @doc false
  def list_connections(_args, ctx) do
    {settings, group_id} = composio_context!(ctx.agent_id)

    case client().list_connected_accounts_all(settings, group_id,
           page_limit: @connected_accounts_page_limit,
           max_pages: @connected_accounts_max_pages
         ) do
      {:ok, items} ->
        connections =
          items
          |> Enum.map(&connection_entry/1)
          |> Enum.sort_by(fn e -> {e["toolkit"], e["connected_account_id"]} end)

        Jason.encode!(%{"connections" => connections})

      {:error, reason} ->
        raise "list composio connections: #{format_reason(reason)}"
    end
  end

  defp connection_entry(item) do
    %{
      "connected_account_id" => to_string(item["id"] || ""),
      "toolkit" => to_string(get_in(item, ["toolkit", "slug"]) || ""),
      "status" => to_string(item["status"] || "")
    }
    |> put_present("status_reason", item["status_reason"])
    |> put_present("created_at", item["created_at"])
  end

  # ---- composio.request_connection ----

  @doc false
  def request_connection(args, ctx) do
    toolkit = args |> required_arg("toolkit") |> String.downcase()
    {settings, group_id} = composio_context!(ctx.agent_id)

    auth_config_id =
      case client().ensure_auth_config(settings, toolkit) do
        {:ok, id} -> id
        {:error, reason} -> raise "resolve composio auth config: #{format_reason(reason)}"
      end

    case client().create_connect_link(settings, auth_config_id, group_id) do
      {:ok, link} ->
        connected_account_id = to_string(link["connected_account_id"] || "")

        content =
          Jason.encode!(%{
            "status" => "pending",
            "toolkit" => toolkit,
            "connected_account_id" => connected_account_id,
            "redirect_url" => to_string(link["redirect_url"] || ""),
            "expires_at" => link["expires_at"],
            "instructions" =>
              "Post the redirect_url to the requester yourself through the current visible reply path; it is not delivered automatically. " <>
                "For an internal Comma conversation, use call(tool=\"im_api.internal.send_message\", params={...}) with connect_id=\"internal\" inside params. For an external provider, call the matching im_api.* operation directly when provider/connect/API are known; use IM discovery/help only when those facts are missing. " <>
                "Ask the user to complete the browser flow, then call composio.check_connection with this connected_account_id to verify the outcome. " <>
                "A session wait is set; the user's next message or the wait expiry will wake you to check."
          })

        # Composio-side completion has no callback into this runtime, so
        # there is no async tool call to resolve — the session just waits
        # for the user (or the timer) before polling check_connection.
        wait =
          Waits.build(
            "composio connection: " <> toolkit,
            @user_interaction_auto_wait_seconds,
            "composio_connection",
            %{
              "tool_name" => "composio.request_connection",
              "connected_account_id" => connected_account_id
            }
          )

        {content, [Waits.event(session_id(ctx), wait)]}

      {:error, reason} ->
        raise "create composio connect link: #{format_reason(reason)}"
    end
  end

  # ---- composio.check_connection ----

  @doc false
  def check_connection(args, ctx),
    do: ConnectorLabels.group_audience(do_check_connection(args, ctx), ctx)

  defp do_check_connection(args, ctx) do
    connected_account_id = required_arg(args, "connected_account_id")
    {settings, group_id} = composio_context!(ctx.agent_id)

    case owned_account(settings, connected_account_id, group_id) do
      {:ok, account} ->
        status = to_string(account["status"] || "")

        cond do
          status == SalixStore.Composio.active_status() ->
            Jason.encode!(%{
              "status" => "active",
              "connected_account_id" => connected_account_id,
              "toolkit" => to_string(get_in(account, ["toolkit", "slug"]) || ""),
              "message" =>
                "connection is ready; the toolkit's tools can be called via composio.execute"
            })

          status in SalixStore.Composio.pending_statuses() ->
            Jason.encode!(%{
              "status" => "pending",
              "connected_account_id" => connected_account_id,
              "message" =>
                "connection is still pending; ask the user to complete the browser flow, then call composio.check_connection again"
            })

          true ->
            %{
              "status" => "failed",
              "connected_account_id" => connected_account_id,
              "provider_status" => status
            }
            |> put_present("status_reason", account["status_reason"])
            |> Jason.encode!()
        end

      :not_found ->
        Jason.encode!(%{
          "status" => "not_found",
          "connected_account_id" => connected_account_id,
          "message" => "no such composio connection for this agent group"
        })

      {:error, reason} ->
        raise "check composio connection: #{format_reason(reason)}"
    end
  end

  # ---- composio.delete_connection ----

  @doc false
  def delete_connection(args, ctx) do
    connected_account_id = required_arg(args, "connected_account_id")
    {settings, group_id} = composio_context!(ctx.agent_id)

    case owned_account(settings, connected_account_id, group_id) do
      {:ok, _account} ->
        case client().delete_connected_account(settings, connected_account_id) do
          :ok ->
            Jason.encode!(%{
              "status" => "deleted",
              "connected_account_id" => connected_account_id
            })

          {:error, reason} ->
            raise "delete composio connection: #{format_reason(reason)}"
        end

      :not_found ->
        Jason.encode!(%{
          "status" => "not_found",
          "connected_account_id" => connected_account_id,
          "message" => "no matching composio connection to delete"
        })

      {:error, reason} ->
        raise "delete composio connection: #{format_reason(reason)}"
    end
  end

  # ---- composio.list_tools ----

  @doc false
  def list_tools(args, ctx),
    do: ConnectorLabels.group_audience(do_list_tools(args, ctx), ctx)

  defp do_list_tools(args, ctx) do
    toolkit = optional_arg(args, "toolkit")
    query = optional_arg(args, "query")
    limit = list_limit(raw(args, "limit"))

    if toolkit == nil and query == nil do
      raise "at least one of 'toolkit' or 'query' is required"
    end

    {settings, _group_id} = composio_context!(ctx.agent_id)

    opts =
      [limit: limit]
      |> put_opt(:toolkit, toolkit && String.downcase(toolkit))
      |> put_opt(:query, query)

    case client().list_tools(settings, opts) do
      {:ok, items} ->
        tools =
          Enum.map(items, fn tool ->
            %{
              "tool_slug" => to_string(tool["slug"] || ""),
              "name" => to_string(tool["name"] || ""),
              "description" =>
                truncate(to_string(tool["description"] || ""), @description_max_chars)
            }
          end)

        Jason.encode!(%{
          "tools" => tools,
          "usage" =>
            "Call composio.get_tool with a tool_slug for its input schema, then composio.execute to run it."
        })

      {:error, reason} ->
        raise "list composio tools: #{format_reason(reason)}"
    end
  end

  defp list_limit(nil), do: @default_list_limit

  defp list_limit(n) when is_integer(n) do
    if n < 1 or n > @max_list_limit do
      raise "limit must be between 1 and #{@max_list_limit}"
    else
      n
    end
  end

  defp list_limit(_), do: raise("limit must be an integer")

  # ---- composio.get_tool ----

  @doc false
  def get_tool(args, ctx),
    do: ConnectorLabels.group_audience(do_get_tool(args, ctx), ctx)

  defp do_get_tool(args, ctx) do
    tool_slug = args |> required_arg("tool_slug") |> String.upcase()
    {settings, _group_id} = composio_context!(ctx.agent_id)

    case client().list_tools(settings, tool_slugs: tool_slug, limit: 1) do
      {:ok, [tool | _]} ->
        Jason.encode!(%{
          "tool_slug" => to_string(tool["slug"] || ""),
          "name" => to_string(tool["name"] || ""),
          "description" => to_string(tool["description"] || ""),
          "toolkit" => to_string(get_in(tool, ["toolkit", "slug"]) || ""),
          "input_parameters" => tool["input_parameters"] || %{}
        })

      {:ok, []} ->
        Jason.encode!(%{
          "status" => "not_found",
          "tool_slug" => tool_slug,
          "message" => "no such composio tool; search with composio.list_tools"
        })

      {:error, reason} ->
        raise "get composio tool: #{format_reason(reason)}"
    end
  end

  # ---- composio.list_toolkits ----

  @doc false
  def list_toolkits_catalog(args, ctx),
    do: ConnectorLabels.group_audience(do_list_toolkits_catalog(args, ctx), ctx)

  defp do_list_toolkits_catalog(args, ctx) do
    query = optional_arg(args, "query")
    limit = list_limit(raw(args, "limit"))

    {settings, _group_id} = composio_context!(ctx.agent_id)

    opts = [limit: limit] |> put_opt(:search, query)

    case client().list_toolkits(settings, opts) do
      {:ok, items} ->
        toolkits =
          Enum.map(items, fn toolkit ->
            %{
              "toolkit" => to_string(toolkit["slug"] || ""),
              "name" => to_string(toolkit["name"] || ""),
              "description" =>
                truncate(
                  to_string(get_in(toolkit, ["meta", "description"]) || ""),
                  @description_max_chars
                )
            }
            |> put_count("tools_count", get_in(toolkit, ["meta", "tools_count"]))
          end)

        Jason.encode!(%{
          "toolkits" => toolkits,
          "usage" =>
            "Connect one with composio.request_connection, or browse its tools with composio.list_tools."
        })

      {:error, reason} ->
        raise "list composio toolkits: #{format_reason(reason)}"
    end
  end

  defp put_count(map, key, value) when is_integer(value), do: Map.put(map, key, value)
  defp put_count(map, _key, _value), do: map

  # ---- composio.execute ----

  @doc false
  def execute(args, ctx),
    do: ConnectorLabels.group_audience(do_execute(args, ctx), ctx)

  defp do_execute(args, ctx) do
    tool_slug = args |> required_arg("tool_slug") |> String.upcase()
    arguments = arguments!(raw(args, "arguments"))
    connected_account_id = optional_arg(args, "connected_account_id")

    {settings, group_id} = composio_context!(ctx.agent_id)

    if connected_account_id do
      case owned_account(settings, connected_account_id, group_id) do
        {:ok, %{"status" => "ACTIVE"}} -> :ok
        {:ok, _} -> raise "Composio account is not active"
        :not_found -> raise "Composio account not found in this group"
        {:error, _} -> raise "Composio account lookup failed"
      end
    end

    opts = put_opt([], :connected_account_id, connected_account_id)

    case client().execute_tool(settings, tool_slug, group_id, arguments, opts) do
      {:ok, envelope} ->
        %{
          "tool_slug" => tool_slug,
          "successful" => envelope["successful"] == true,
          "data" => envelope["data"] || %{}
        }
        |> put_present("error", envelope["error"])
        |> put_present("log_id", envelope["log_id"])
        |> Jason.encode!()

      {:error, :not_found} ->
        raise "composio tool #{tool_slug} not found; search with composio.list_tools"

      {:error, reason} ->
        raise "execute composio tool: #{format_reason(reason)}"
    end
  end

  defp arguments!(nil), do: %{}
  defp arguments!(map) when is_map(map), do: map
  defp arguments!(_), do: raise("'arguments' must be a JSON object")

  # ---- shared context / ownership helpers ----

  defp composio_context!(agent_id) do
    {tenant, group_id} =
      case OAuthStore.agent_oauth_context(agent_id) do
        {:ok, %{tenant: tenant, group_id: group_id}} ->
          if String.trim(to_string(tenant)) == "", do: raise("agent has no tenant")
          if String.trim(to_string(group_id)) == "", do: raise("agent has no group")
          {tenant, group_id}

        {:error, :oauth_store_not_configured} ->
          raise "composio tools are not configured for this runtime"

        {:error, why} ->
          raise "load agent: #{format_reason(why)}"
      end

    settings =
      case ComposioStore.settings(tenant) do
        {:ok, settings} ->
          settings

        {:error, :not_configured} ->
          raise not_configured_message()

        {:error, :composio_not_configured} ->
          raise not_configured_message()

        {:error, why} ->
          raise "load composio settings: #{format_reason(why)}"
      end

    {settings, group_id}
  end

  defp not_configured_message do
    "composio is not configured for this tenant; an admin needs to add a Composio API key in the settings, or use the oauth.* tools instead"
  end

  # An account is "owned" when Composio's user_id equals this agent's group id
  # — the same tenancy boundary as managed OAuth group bindings. A foreign
  # account is reported as :not_found so cross-group ids cannot be probed.
  defp owned_account(settings, connected_account_id, group_id) do
    case client().get_connected_account(settings, connected_account_id) do
      {:ok, account} ->
        if to_string(account["user_id"] || "") == group_id, do: {:ok, account}, else: :not_found

      {:error, :not_found} ->
        :not_found

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp client do
    Application.get_env(:salix_agent, :composio_client_mod, SalixStore.Composio)
  end

  # ---- arg helpers (same conventions as SalixAgent.Tools.OAuth) ----

  defp session_id(ctx) do
    case Map.get(ctx, :session_id) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: raise("ctx.session_id is required"), else: value

      _ ->
        raise "ctx.session_id is required"
    end
  end

  defp put_present(map, key, value) do
    if is_binary(value) and value != "", do: Map.put(map, key, value), else: map
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp truncate(s, max) do
    if String.length(s) <= max, do: s, else: String.slice(s, 0, max) <> "…"
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp raw(args, key), do: Map.get(args, key, Map.get(args, String.to_atom(key)))

  defp arg(args, key), do: to_string(raw(args, key) || "")

  defp optional_arg(args, key) do
    case args |> arg(key) |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  defp required_arg(args, key) do
    case args |> arg(key) |> String.trim() do
      "" -> raise "'#{key}' is required"
      value -> value
    end
  end
end
