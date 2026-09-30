if Application.compile_env(:salix_web, :local_recommendation_mock_compiled, false) do
  defmodule SalixWeb.LocalOAuthMock do
    @moduledoc """
    Local-development OAuth provider for Comma's built-in integrations.

    The mock is enabled only by explicit runtime configuration. It exercises the
    production auth-state, callback, token persistence, and binding paths; only
    the external provider endpoints and credentials are replaced.
    """

    import Plug.Conn

    @behaviour Plug

    @managed_providers ~w(github google slack)
    @path_prefix "/v1/local-oauth/"
    @baseline_key {__MODULE__, :configuration_baseline}

    def available?, do: true

    def enabled?, do: Application.get_env(:salix_web, :local_oauth_mock, false) == true

    def status, do: %{available: true, enabled: enabled?()}

    def set_enabled(enabled) when is_boolean(enabled) do
      :global.trans({__MODULE__, :runtime_toggle}, fn ->
        if enabled do
          remember_configuration!()
          Application.put_env(:salix_web, :local_oauth_mock, true)
          Application.put_env(:salix_web, :local_recommendation_mock, true)
          :ok = configure!()
        else
          restore_configuration!()
          Application.put_env(:salix_web, :local_oauth_mock, false)
          Application.put_env(:salix_web, :local_recommendation_mock, false)
        end

        {:ok, status()}
      end)
    end

    def public_path?(path) when is_binary(path),
      do: enabled?() and String.starts_with?(path, @path_prefix)

    def public_path?(_path), do: false

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      case {conn.method, conn.path_info} do
        {"GET", ["v1", "local-oauth", provider, "authorize"]} -> authorize(conn, provider)
        {"POST", ["v1", "local-oauth", provider, "token"]} -> token(conn, provider)
        {"GET", ["v1", "local-oauth", provider, "user"]} -> userinfo(conn, provider)
        {"GET", ["v1", "local-oauth", provider, "userinfo"]} -> userinfo(conn, provider)
        {"POST", ["v1", "local-oauth", "mcp", "register"]} -> register(conn)
        {"POST", ["v1", "local-oauth", "mcp", "resource"]} -> mcp_resource(conn)
        {"POST", ["v1", "local-oauth", provider, "revoke"]} -> revoke(conn, provider)
        _ -> json(conn, 404, %{error: "local OAuth endpoint not found"})
      end
    end

    def configure!(base_url \\ nil) do
      if enabled?() do
        base_url = String.trim_trailing(base_url || configured_base_url(), "/")
        current = Application.get_env(:salix_store, :oauth_endpoint_overrides, %{}) || %{}

        overrides = %{
          "github" => %{
            "authorize_url" => endpoint(base_url, "github/authorize"),
            "token_url" => endpoint(base_url, "github/token"),
            "api_url" => endpoint(base_url, "github")
          },
          "google" => %{
            "authorize_url" => endpoint(base_url, "google/authorize"),
            "token_url" => endpoint(base_url, "google/token"),
            "revoke_url" => endpoint(base_url, "google/revoke"),
            "api_url" => endpoint(base_url, "google/userinfo")
          },
          "slack" => %{
            "authorize_url" => endpoint(base_url, "slack/authorize"),
            "token_url" => endpoint(base_url, "slack/token"),
            "revoke_url" => endpoint(base_url, "slack/revoke")
          }
        }

        Application.put_env(
          :salix_store,
          :oauth_endpoint_overrides,
          Map.merge(current, overrides)
        )

        remote_targets = Application.get_env(:salix_mcp, :remote_target_overrides, %{}) || %{}
        mock_mcp_url = endpoint(base_url, "mcp/resource")

        Application.put_env(
          :salix_mcp,
          :remote_target_overrides,
          Map.merge(remote_targets, %{
            "remote:feishu" => mock_mcp_url,
            "remote:github" => mock_mcp_url,
            "remote:google-workspace" => mock_mcp_url,
            "remote:linear" => mock_mcp_url,
            "remote:notion" => mock_mcp_url,
            "remote:slack" => mock_mcp_url
          })
        )

        allowlist = Application.get_env(:salix_mcp, :private_http_target_allowlist, [])

        Application.put_env(
          :salix_mcp,
          :private_http_target_allowlist,
          Enum.uniq([mock_mcp_url | List.wrap(allowlist)])
        )

        # Comma follows BFT/Admin's Composio connection boundary. Only the
        # provider adapter is replaced locally; Comma Web keeps production
        # recommendation discovery and bounded server-side collection. Other
        # surfaces may still exercise the production composio.* tool plumbing,
        # while Comma's hidden recommendation renderer never receives those tools.
        SalixWeb.LocalComposioMock.reset!()
        Application.put_env(:salix_web, :composio_settings_mod, SalixWeb.LocalComposioMock)
        Application.put_env(:salix_web, :composio_client_mod, SalixWeb.LocalComposioMock)
        Application.put_env(:salix_agent, :composio_store_mod, SalixWeb.LocalComposioMock)
        Application.put_env(:salix_agent, :composio_client_mod, SalixWeb.LocalComposioMock)
      end

      :ok
    end

    def mock_credentials(provider) when provider in @managed_providers do
      if enabled?() do
        {:ok,
         %{
           "client_id" => "comma-local-#{provider}",
           "client_secret" => "comma-local-secret-#{provider}"
         }}
      else
        {:error, :not_configured}
      end
    end

    def mock_credentials(_provider), do: {:error, :not_configured}

    def http_target(url) when is_binary(url) do
      target = URI.parse(url)
      base = URI.parse(configured_base_url())

      if enabled?() and target.scheme == "http" and target.host == base.host and
           target.port == base.port and String.starts_with?(target.path || "", @path_prefix) do
        host_header =
          if target.port in [nil, 80], do: target.host, else: "#{target.host}:#{target.port}"

        {:ok,
         %{
           url: url,
           connect_options: [hostname: target.host],
           host_header: host_header,
           inet6: false
         }}
      else
        {:error, :not_local_oauth_mock}
      end
    end

    def http_target(_url), do: {:error, :not_local_oauth_mock}

    def remote_identity(definition, binding, config) do
      if enabled?() do
        base_url = configured_base_url()
        mcp_id = definition["mcp_id"]
        resource = endpoint(base_url, "mcp/resource/#{URI.encode(mcp_id)}")
        issuer = endpoint(base_url, "mcp")

        metadata = %{
          "issuer" => issuer,
          "authorization_endpoint" => endpoint(base_url, "mcp/authorize"),
          "token_endpoint" => endpoint(base_url, "mcp/token"),
          "registration_endpoint" => endpoint(base_url, "mcp/register"),
          "revocation_endpoint" => endpoint(base_url, "mcp/revoke"),
          "token_endpoint_auth_methods_supported" => ["none"]
        }

        {:ok,
         %{
           "provider_kind" => "remote_mcp",
           "provider_key" => "comma-local-" <> mcp_id,
           "resource_server_url" => resource,
           "oauth_resource" => resource,
           "authorization_issuer" => issuer,
           "authorization_server_metadata_url" => endpoint(base_url, "mcp/metadata"),
           "protected_resource_metadata_url" => endpoint(base_url, "mcp/resource-metadata"),
           "mcp_definition_id" => mcp_id,
           "mcp_binding_id" => binding["binding_id"],
           "target_ref" => binding["target_ref"],
           "scope" => "read write openid email",
           "protected_resource_metadata" => %{
             "resource" => resource,
             "authorization_servers" => [issuer]
           },
           "authorization_server_metadata" => metadata,
           "mock_target_url" => config["url"]
         }}
      else
        {:error, :not_enabled}
      end
    end

    def authorize(conn, provider) do
      conn = fetch_query_params(conn)
      redirect_uri = conn.query_params["redirect_uri"]
      state = conn.query_params["state"]

      cond do
        provider not in @managed_providers and provider != "mcp" ->
          json(conn, 404, %{error: "unknown local OAuth provider"})

        not local_callback?(redirect_uri) ->
          json(conn, 400, %{error: "local callback URL required"})

        not present?(state) ->
          json(conn, 400, %{error: "state is required"})

        true ->
          location = append_query(redirect_uri, %{"code" => "comma-local-code", "state" => state})

          conn
          |> put_resp_header("cache-control", "no-store")
          |> put_resp_header("location", location)
          |> send_resp(302, "")
      end
    end

    def token(conn, "github") do
      json(conn, 200, %{
        access_token: "comma-local-github-token",
        token_type: "bearer",
        scope: "repo,read:org,read:user,user:email"
      })
    end

    def token(conn, "google") do
      json(conn, 200, %{
        access_token: "comma-local-google-token",
        refresh_token: "comma-local-google-refresh",
        token_type: "Bearer",
        scope:
          "openid email profile https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/chat.messages.readonly",
        expires_in: 3600
      })
    end

    def token(conn, "slack") do
      json(conn, 200, %{
        ok: true,
        app_id: "A_COMMA_LOCAL",
        authed_user: %{
          id: "UCOMMALOCAL",
          access_token: "xoxp-comma-local-token",
          token_type: "user",
          scope:
            "search:read,search:read.public,search:read.private,search:read.mpim,search:read.im,search:read.files,search:read.users,chat:write,channels:history,groups:history,mpim:history,im:history,canvases:read,canvases:write,users:read,users:read.email,reactions:write,reactions:read,emoji:read,files:read,channels:write,groups:write,im:write,mpim:write,channels:read,groups:read,mpim:read"
        },
        team: %{id: "TCOMMALOCAL", name: "Comma Local Workspace"}
      })
    end

    def token(conn, "mcp") do
      json(conn, 200, %{
        access_token: "comma-local-mcp-token",
        refresh_token: "comma-local-mcp-refresh",
        token_type: "Bearer",
        scope: "read write openid email",
        expires_in: 3600
      })
    end

    def token(conn, _provider), do: json(conn, 404, %{error: "unknown local OAuth provider"})

    def userinfo(conn, "github") do
      json(conn, 200, %{id: 1, login: "comma-local-user", name: "Comma Local User"})
    end

    def userinfo(conn, "google") do
      json(conn, 200, %{
        sub: "comma-local-user",
        email: "local@comma.test",
        email_verified: true,
        name: "Comma Local User"
      })
    end

    def userinfo(conn, _provider),
      do: json(conn, 404, %{error: "unknown local OAuth provider"})

    def register(conn) do
      json(conn, 201, %{
        client_id: "comma-local-mcp-client",
        token_endpoint_auth_method: "none",
        redirect_uris: [callback_url("mcp")]
      })
    end

    def mcp_resource(conn) do
      with {:ok, body, conn} <- read_body(conn),
           {:ok, request} <- Jason.decode(body) do
        mcp_response(conn, request)
      else
        _ -> json(conn, 400, %{error: "invalid MCP request"})
      end
    end

    defp mcp_response(conn, %{"method" => "notifications/initialized"}),
      do: send_resp(conn, 202, "")

    defp mcp_response(conn, %{"id" => id, "method" => method} = request) do
      result =
        case method do
          "initialize" ->
            %{
              protocolVersion: "2025-06-18",
              capabilities: %{tools: %{}, resources: %{}, prompts: %{}},
              serverInfo: %{name: "Comma Local MCP", version: "1.0.0"}
            }

          "tools/list" ->
            %{
              tools: [
                %{
                  name: "comma_local_search",
                  description:
                    "Returns deterministic local data for Comma recommendation testing.",
                  annotations: %{
                    readOnlyHint: true,
                    destructiveHint: false,
                    idempotentHint: true
                  },
                  inputSchema: %{
                    type: "object",
                    properties: %{
                      query: %{type: "string"},
                      source: %{
                        type: "string",
                        description: "Connected source alias used by the local mock."
                      }
                    },
                    additionalProperties: true
                  }
                }
              ]
            }

          "tools/call" ->
            query = get_in(request, ["params", "arguments", "query"]) || "recent activity"
            source = get_in(request, ["params", "arguments", "source"]) || "generic"

            data = %{
              query: query,
              items: recommendation_items(source)
            }

            %{
              content: [
                %{
                  type: "text",
                  text: Jason.encode!(data)
                }
              ],
              isError: false
            }

          "resources/list" ->
            %{resources: []}

          "resources/templates/list" ->
            %{resourceTemplates: []}

          "prompts/list" ->
            %{prompts: []}

          _ ->
            %{}
        end

      json(conn, 200, %{jsonrpc: "2.0", id: id, result: result})
    end

    defp mcp_response(conn, _request), do: send_resp(conn, 202, "")

    # The `comma_local_search` items project the same demo entities as the
    # Composio mock (SalixWeb.LocalProviderFixtures), so both transports cite
    # identical, now-relative record links.
    defp recommendation_items(source),
      do: SalixWeb.LocalProviderFixtures.mcp_recommendation_items(source)

    def revoke(conn, provider) when provider in ["google", "mcp"],
      do: json(conn, 200, %{ok: true})

    def revoke(conn, "slack"), do: json(conn, 200, %{ok: true})
    def revoke(conn, _provider), do: json(conn, 404, %{error: "unknown local OAuth provider"})

    defp configured_base_url do
      case Application.get_env(:salix_web, :public_base_url) do
        value when is_binary(value) and value != "" -> String.trim_trailing(value, "/")
        _ -> "http://127.0.0.1:#{SalixWeb.Application.port()}"
      end
    end

    defp endpoint(base_url, suffix), do: base_url <> @path_prefix <> suffix

    defp callback_url(provider),
      do: String.trim_trailing(configured_base_url(), "/") <> "/v1/oauth/#{provider}/callback"

    defp local_callback?(value) when is_binary(value) do
      case URI.parse(value) do
        %URI{scheme: "http", host: host} when host in ["127.0.0.1", "localhost"] -> true
        _ -> false
      end
    end

    defp local_callback?(_value), do: false

    defp append_query(uri, params) do
      parsed = URI.parse(uri)

      query =
        (parsed.query || "")
        |> URI.decode_query()
        |> Map.merge(params)
        |> URI.encode_query()

      %{parsed | query: query} |> URI.to_string()
    end

    defp present?(value), do: is_binary(value) and String.trim(value) != ""

    defp remember_configuration! do
      case :persistent_term.get(@baseline_key, :missing) do
        :missing ->
          :persistent_term.put(@baseline_key, %{
            composio_client_mod: capture_env(:salix_web, :composio_client_mod),
            composio_settings_mod: capture_env(:salix_web, :composio_settings_mod),
            agent_composio_client_mod: capture_env(:salix_agent, :composio_client_mod),
            agent_composio_store_mod: capture_env(:salix_agent, :composio_store_mod),
            oauth_endpoint_overrides:
              Application.get_env(:salix_store, :oauth_endpoint_overrides, %{}) || %{},
            private_http_target_allowlist:
              Application.get_env(:salix_mcp, :private_http_target_allowlist, []),
            remote_target_overrides:
              Application.get_env(:salix_mcp, :remote_target_overrides, %{}) || %{}
          })

        _baseline ->
          :ok
      end
    end

    defp restore_configuration! do
      case :persistent_term.get(@baseline_key, :missing) do
        :missing ->
          :ok

        baseline ->
          restore_env(:salix_web, :composio_client_mod, baseline.composio_client_mod)
          restore_env(:salix_web, :composio_settings_mod, baseline.composio_settings_mod)
          restore_env(:salix_agent, :composio_client_mod, baseline.agent_composio_client_mod)
          restore_env(:salix_agent, :composio_store_mod, baseline.agent_composio_store_mod)

          Application.put_env(
            :salix_store,
            :oauth_endpoint_overrides,
            baseline.oauth_endpoint_overrides
          )

          Application.put_env(
            :salix_mcp,
            :remote_target_overrides,
            baseline.remote_target_overrides
          )

          Application.put_env(
            :salix_mcp,
            :private_http_target_allowlist,
            baseline.private_http_target_allowlist
          )

          :persistent_term.erase(@baseline_key)
      end
    end

    defp capture_env(app, key) do
      case Application.fetch_env(app, key) do
        {:ok, value} -> {:present, value}
        :error -> :missing
      end
    end

    defp restore_env(app, key, {:present, value}), do: Application.put_env(app, key, value)
    defp restore_env(app, key, :missing), do: Application.delete_env(app, key)

    defp json(conn, status, body) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end
else
  defmodule SalixWeb.LocalOAuthMock do
    @moduledoc false

    def available?, do: false
    def enabled?, do: false
    def status, do: %{available: false, enabled: false}
    def set_enabled(_enabled), do: {:error, :not_available}
    def configure!(_base_url \\ nil), do: :ok
    def public_path?(_path), do: false
    def init(opts), do: opts
    def call(conn, _opts), do: conn
    def mock_credentials(_provider), do: {:error, :not_configured}
    def http_target(_url), do: {:error, :not_local_oauth_mock}
    def remote_identity(_definition, _binding, _config), do: {:error, :not_enabled}
  end
end
