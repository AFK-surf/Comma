defmodule SalixWeb.SiteAPI do
  @moduledoc """
  `/_api/` endpoints for agent-hosted sites — the Salix port of willow's
  `internal/api/site_api.go` + `site_config.go`.

  Routing (from `SalixWeb.Endpoint`, on a site subdomain):

    * `POST /_api/llm/chat` — LLM proxy (`SalixWeb.SiteLLM`)
    * `GET /_api/documents` — list documents (storage rule op `list`,
      matched against the `prefix` query param)
    * `GET|PUT|DELETE /_api/documents/{key}` — document CRUD
      (`SalixWeb.SiteDocuments`)

  Site APIs are disabled by default: the agent enables them by writing
  `/.salix/websites/{site}/_api.json` to its AgentWorkspace. The parsed config is
  cached for 5 seconds per `{agent}:{site}` (willow's `siteConfigCache`).
  Bearer tokens use constant-time comparison; storage rules are evaluated
  in order — first `key_prefix` match wins, no match falls back to
  `default_policy` (`"deny"` unless set). Errors are willow's HTML site
  error pages; successes are JSON.
  """

  import Plug.Conn

  alias SalixAgent.AgentWorkspace
  alias SalixWeb.Site

  @config_cache_ttl_ms 5_000

  @doc "Dispatch a site-API request (CORS + auth + routing — willow `serveSiteAPI`)."
  @spec call(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def call(conn, agent_id, site_name) do
    conn = conn |> fetch_query_params() |> put_cors()

    if conn.method == "OPTIONS" do
      send_resp(conn, 204, "")
    else
      dispatch(conn, agent_id, site_name)
    end
  end

  defp put_cors(conn) do
    case get_req_header(conn, "origin") do
      [origin | _] when origin != "" ->
        conn
        |> put_resp_header("access-control-allow-origin", origin)
        |> put_resp_header("access-control-allow-methods", "GET, PUT, POST, DELETE, OPTIONS")
        |> put_resp_header("access-control-allow-headers", "Authorization, Content-Type")
        |> put_resp_header("access-control-max-age", "86400")

      _ ->
        conn
    end
  end

  defp dispatch(conn, agent_id, site_name) do
    with {:agent, {:ok, canonical_id, agent}} <- {:agent, Site.lookup_agent(agent_id)},
         {:config, {:ok, cfg}} <- {:config, cached_config(canonical_id, site_name)} do
      cond do
        is_nil(cfg) ->
          Site.site_error(conn, 404, "Site API not configured")

        true ->
          route(conn, api_path(conn), agent, canonical_id, site_name, cfg)
      end
    else
      {:agent, {:error, :not_found}} -> Site.site_error(conn, 404, "Site not found")
      {:agent, {:error, _}} -> Site.site_error(conn, 500, "Internal server error")
      {:config, {:error, _}} -> Site.site_error(conn, 500, "Internal server error")
    end
  end

  defp api_path(conn) do
    case conn.request_path do
      "/_api" <> rest -> rest
      other -> other
    end
  end

  defp route(conn, "/llm/chat", agent, agent_id, site_name, cfg) when conn.method == "POST" do
    cond do
      not cfg.llm.enabled ->
        Site.site_error(conn, 404, "LLM API not enabled")

      cfg.llm.require_auth and not site_auth?(conn, cfg) ->
        Site.site_error(conn, 401, "Unauthorized")

      true ->
        SalixWeb.SiteLLM.serve(conn, agent, agent_id, site_name, cfg)
    end
  end

  defp route(conn, "/documents", _agent, agent_id, site_name, cfg) when conn.method == "GET" do
    # The `prefix` query param drives rule matching so prefix-scoped rules
    # apply to list operations.
    list_prefix = conn.query_params["prefix"] || ""

    case check_storage_access(conn, cfg, list_prefix, "list") do
      :ok -> SalixWeb.SiteDocuments.list(conn, agent_id, site_name)
      {:denied, conn} -> conn
    end
  end

  defp route(conn, "/documents/" <> doc_key, _agent, agent_id, site_name, cfg) do
    cond do
      doc_key == "" ->
        Site.site_error(conn, 400, "Document key required")

      conn.method == "GET" ->
        with_storage_access(conn, cfg, doc_key, "read", fn conn ->
          SalixWeb.SiteDocuments.get(conn, agent_id, site_name, doc_key)
        end)

      conn.method == "PUT" ->
        with_storage_access(conn, cfg, doc_key, "write", fn conn ->
          SalixWeb.SiteDocuments.put(conn, agent_id, site_name, doc_key, cfg)
        end)

      conn.method == "DELETE" ->
        with_storage_access(conn, cfg, doc_key, "delete", fn conn ->
          SalixWeb.SiteDocuments.delete(conn, agent_id, site_name, doc_key)
        end)

      true ->
        Site.site_error(conn, 405, "Method not allowed")
    end
  end

  defp route(conn, _path, _agent, _agent_id, _site_name, _cfg),
    do: Site.site_error(conn, 404, "Not found")

  defp with_storage_access(conn, cfg, key, op, fun) do
    case check_storage_access(conn, cfg, key, op) do
      :ok -> fun.(conn)
      {:denied, conn} -> conn
    end
  end

  # Willow checkStorageAccess: first matching rule wins; no rule → default
  # policy; rule must list the op; rule.require_auth → bearer check.
  defp check_storage_access(conn, cfg, key, op) do
    case match_storage_rule(cfg, key) do
      nil ->
        if (cfg.storage.default_policy || "deny") == "deny" do
          {:denied, Site.site_error(conn, 403, "Access denied")}
        else
          :ok
        end

      rule ->
        cond do
          op not in rule.operations ->
            {:denied, Site.site_error(conn, 403, "Operation not allowed")}

          rule.require_auth and not site_auth?(conn, cfg) ->
            {:denied, Site.site_error(conn, 401, "Unauthorized")}

          true ->
            :ok
        end
    end
  end

  @doc "First storage rule whose `key_prefix` matches `key`, or nil."
  def match_storage_rule(cfg, key) do
    Enum.find(cfg.storage.rules, fn rule -> String.starts_with?(key, rule.key_prefix) end)
  end

  @doc "Per-rule value-size cap, or the global 1MB default (willow)."
  def effective_max_value_size(nil), do: 1_048_576
  def effective_max_value_size(%{max_value_size: n}) when is_integer(n) and n > 0, do: n
  def effective_max_value_size(_), do: 1_048_576

  # ---- bearer auth (constant-time, willow validateBearerToken) ----

  defp site_auth?(conn, cfg) do
    token = bearer_token(conn)

    token != "" and
      Enum.any?(cfg.auth.bearer_tokens, fn t ->
        is_binary(t) and Plug.Crypto.secure_compare(token, t)
      end)
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> t | _] -> t
      _ -> ""
    end
  end

  # ---- _api.json loading + cache ----

  @doc """
  Load (and cache for 5s) the parsed `_api.json` for `{agent, site}`.
  Returns `{:ok, nil}` when the site has no config (willow: 404 from caller).
  """
  @spec cached_config(String.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def cached_config(agent_id, site_name) do
    key = agent_id <> ":" <> site_name
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(__MODULE__.Cache, key) do
      [{^key, cfg, fetched_at}] when now - fetched_at < @config_cache_ttl_ms ->
        {:ok, cfg}

      _ ->
        case load_config(agent_id, site_name) do
          {:ok, cfg} ->
            :ets.insert(__MODULE__.Cache, {key, cfg, now})
            {:ok, cfg}

          err ->
            err
        end
    end
  end

  defp load_config(agent_id, site_name) do
    config_path = "/.salix/websites/" <> site_name <> "/_api.json"

    case AgentWorkspace.read(agent_id, config_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, raw} when is_map(raw) -> {:ok, parse_config(raw)}
          _ -> {:error, :invalid_config}
        end

      {:error, :not_found} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def parse_config(raw) do
    auth = raw["auth"] || %{}
    storage = raw["storage"] || %{}
    llm = raw["llm"] || %{}

    %{
      auth: %{bearer_tokens: List.wrap(auth["bearer_tokens"])},
      storage: %{
        default_policy: storage["default_policy"] || "",
        rules:
          for rule <- List.wrap(storage["rules"]), is_map(rule) do
            %{
              key_prefix: rule["key_prefix"] || "",
              operations: List.wrap(rule["operations"]),
              require_auth: rule["require_auth"] == true,
              max_value_size: rule["max_value_size"] || 0
            }
          end
      },
      llm: %{
        enabled: llm["enabled"] == true,
        require_auth: llm["require_auth"] == true,
        rate_limit_rpm: llm["rate_limit_rpm"] || 0,
        max_tokens: llm["max_tokens"] || 0
      }
    }
  end

  defmodule RateLimit do
    @moduledoc """
    Redis sliding-window limiter for SiteLLM requests.

    The limiter is global across Salix pods. Redis unavailability denies the
    request and emits bounded telemetry; no local fallback is permitted.
    """

    use Hammer,
      backend: Hammer.Redis,
      algorithm: :sliding_window,
      prefix: "salix:site-llm:v1",
      timeout: 2_000

    @window_ms 60_000

    def allow?(agent_id, max_rpm) when is_binary(agent_id) do
      limit = if is_integer(max_rpm) and max_rpm > 0, do: max_rpm, else: 60

      case hit(digest(agent_id), @window_ms, limit) do
        {:allow, _count} ->
          emit(:allow)
          true

        {:deny, _retry_after} ->
          emit(:deny)
          false
      end
    rescue
      _error ->
        emit(:unavailable)
        false
    catch
      :exit, _reason ->
        emit(:unavailable)
        false
    end

    defp digest(agent_id),
      do: :crypto.hash(:sha256, agent_id) |> Base.encode16(case: :lower)

    defp emit(outcome) do
      :telemetry.execute(
        [:salix, :site_llm, :rate_limit, :decision],
        %{count: 1},
        %{outcome: outcome}
      )
    end
  end

  defmodule State do
    @moduledoc """
    Owner of the node-local `_api.json` config cache.

    SiteLLM rate limiting is delegated to the supervised Redis limiter and is
    deliberately not stored in this ETS owner.
    """

    use GenServer

    @prune_every_ms 5 * 60_000
    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

    @doc "Global Redis sliding-window rate limit for SiteLLM."
    @spec allow?(String.t(), integer()) :: boolean()
    def allow?(agent_id, max_rpm), do: SalixWeb.SiteAPI.RateLimit.allow?(agent_id, max_rpm)

    @impl true
    def init(nil) do
      :ets.new(SalixWeb.SiteAPI.Cache, [:named_table, :set, :public, read_concurrency: true])
      Process.send_after(self(), :prune, @prune_every_ms)
      {:ok, %{}}
    end

    @impl true
    def handle_info(:prune, state) do
      now = System.monotonic_time(:millisecond)

      :ets.select_delete(SalixWeb.SiteAPI.Cache, [
        {{:_, :_, :"$1"}, [{:<, :"$1", now - 2 * 60_000}], [true]}
      ])

      Process.send_after(self(), :prune, @prune_every_ms)
      {:noreply, state}
    end
  end
end
