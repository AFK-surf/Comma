defmodule SalixIM.AppAvailabilityTest do
  @moduledoc """
  Whether a connect's Feishu or Lark app is available to one person, and who
  they are (`SalixIM.Provider.Feishu.AppAvailability` and its Lark twin). A
  local Plug stands in for each open platform.
  """

  use SystemsClock.Case, async: false

  alias SalixIM.TestSupport.BanditServer

  @open_id "ou_ann"
  @email_scope "contact:user.email:readonly"

  defmodule FakePlatform do
    @moduledoc false
    use Agent
    import Plug.Conn

    def start_link(_ \\ []),
      do: Agent.start_link(fn -> %{routes: %{}, requests: []} end, name: __MODULE__)

    def route(path, status \\ 200, body),
      do: Agent.update(__MODULE__, &put_in(&1, [:routes, path], {status, body}))

    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))
    def requests(path), do: Enum.filter(requests(), &(&1.path == path))

    def init(opts), do: opts

    def call(conn, _opts) do
      conn = fetch_query_params(conn)
      {:ok, raw, conn} = read_body(conn)

      request = %{
        path: conn.request_path,
        query: conn.query_params,
        body: if(raw == "", do: nil, else: Jason.decode!(raw)),
        authorization: conn |> get_req_header("authorization") |> List.first()
      }

      Agent.update(__MODULE__, &%{&1 | requests: [request | &1.requests]})

      {status, body} =
        Agent.get(__MODULE__, &Map.get(&1.routes, conn.request_path)) ||
          {404, %{"code" => 1_770_002, "msg" => "not found"}}

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  for {provider, module, api, base_key} <- [
        {"feishu", SalixIM.Provider.Feishu.AppAvailability, SalixIM.Provider.Feishu.API,
         :feishu_api_base_url},
        {"lark", SalixIM.Provider.Lark.AppAvailability, SalixIM.Provider.Lark.API,
         :lark_api_base_url}
      ] do
    describe provider do
      @platform %{provider: provider, module: module, api: api, base_key: base_key}

      setup do
        platform = @platform
        previous = SystemsRuntime.get_env(:salix_im, platform.base_key)
        start_supervised!(FakePlatform)
        port = BanditServer.start!(fn p -> {Bandit, plug: FakePlatform, port: p} end)
        SystemsRuntime.put_env(:salix_im, platform.base_key, "http://127.0.0.1:#{port}/open-apis")
        platform.api.reset_token_cache()
        platform.module.reset_cache()

        on_exit(fn ->
          if is_nil(previous),
            do: SystemsRuntime.delete_env(:salix_im, platform.base_key),
            else: SystemsRuntime.put_env(:salix_im, platform.base_key, previous)

          platform.api.reset_token_cache()
          platform.module.reset_cache()
        end)

        FakePlatform.route("/open-apis/auth/v3/tenant_access_token/internal", %{
          "code" => 0,
          "tenant_access_token" => "t-app",
          "expire" => 7200
        })

        FakePlatform.route("/open-apis/contact/v3/users/#{@open_id}", %{
          "code" => 0,
          "data" => %{"user" => %{"name" => "Ann", "email" => "ann@acme.test"}}
        })

        connect = %{
          "provider" => platform.provider,
          "connect_id" => "cnx_#{platform.provider}_availability",
          "app_id" => "cli_app",
          "app_secret" => "secret"
        }

        Map.merge(platform, %{connect: connect})
      end

      test "a person on the white list is who the directory says, read once an hour",
           f do
        SystemsClock.manual()
        on_exit(&SystemsClock.reset/0)
        visibility(%{"in_white_list" => true, "in_black_list" => false})

        assert f.module.member(f.connect, @open_id) ==
                 {:ok, %{"name" => "Ann", "email" => "ann@acme.test"}}

        assert [check] = FakePlatform.requests(check_path())
        assert check.query == %{"user_id_type" => "open_id"}
        assert check.body == %{"user_ids" => [@open_id]}
        assert check.authorization == "Bearer t-app"
        assert [read] = FakePlatform.requests(user_path())
        assert read.query["user_id_type"] == "open_id"

        # The next call asks the app again but does not read the person again.
        assert {:ok, %{"email" => "ann@acme.test"}} = f.module.member(f.connect, @open_id)
        assert length(FakePlatform.requests(check_path())) == 2
        assert length(FakePlatform.requests(user_path())) == 1

        # An administrator's change applies to the next call.
        visibility(%{"in_white_list" => false})
        assert f.module.member(f.connect, @open_id) == {:error, :not_available}

        # After an hour the person is read again.
        visibility(%{"in_white_list" => true})
        SystemsClock.advance(3_600_001)
        assert {:ok, _person} = f.module.member(f.connect, @open_id)
        assert length(FakePlatform.requests(user_path())) == 2
      end

      test "off the white list, on the black list or not listed is not available",
           f do
        for items <- [
              [%{"user_id" => @open_id, "in_white_list" => false, "in_black_list" => false}],
              [%{"user_id" => @open_id, "in_white_list" => true, "in_black_list" => true}],
              [%{"user_id" => "ou_other", "in_white_list" => true}],
              []
            ] do
          FakePlatform.route(check_path(), %{
            "code" => 0,
            "data" => %{"user_visibility_list" => items}
          })

          assert f.module.member(f.connect, @open_id) == {:error, :not_available}
        end

        assert FakePlatform.requests(user_path()) == []
      end

      test "a person without an email cannot be matched", f do
        visibility(%{"in_white_list" => true})

        FakePlatform.route(user_path(), %{
          "code" => 0,
          "data" => %{"user" => %{"name" => "Ann", "email" => "", "enterprise_email" => ""}}
        })

        # The app has the email permission: the person has no email.
        scopes([%{"scope_name" => @email_scope, "grant_status" => 1, "scope_type" => "tenant"}])
        assert f.module.member(f.connect, @open_id) == {:error, :no_email}

        # Without it every email reads empty, and the refusal names the permission.
        scopes([
          %{"scope_name" => @email_scope, "grant_status" => 0, "scope_type" => "tenant"},
          %{"scope_name" => @email_scope, "grant_status" => 1, "scope_type" => "user"},
          %{
            "scope_name" => "contact:user.base:readonly",
            "grant_status" => 1,
            "scope_type" => "tenant"
          }
        ])

        assert f.module.member(f.connect, @open_id) ==
                 {:error, {:missing_scope, @email_scope}}

        # Scopes that cannot be read leave the best known cause.
        FakePlatform.route("/open-apis/application/v6/scopes", 400, %{
          "code" => 1,
          "msg" => "down"
        })

        assert f.module.member(f.connect, @open_id) == {:error, :no_email}
      end

      test "an app without the permission names it", f do
        FakePlatform.route(check_path(), 400, %{
          "code" => 99_991_672,
          "msg" =>
            "Access denied. One of the following scopes is required: [application:application:self_manage]."
        })

        assert f.module.member(f.connect, @open_id) ==
                 {:error, {:missing_scope, "application:application:self_manage"}}

        assert FakePlatform.requests(user_path()) == []
      end
    end
  end

  defp visibility(item) do
    FakePlatform.route(check_path(), %{
      "code" => 0,
      "data" => %{"user_visibility_list" => [Map.put(item, "user_id", @open_id)]}
    })
  end

  defp scopes(items),
    do:
      FakePlatform.route("/open-apis/application/v6/scopes", %{
        "code" => 0,
        "data" => %{"scopes" => items}
      })

  defp check_path,
    do: "/open-apis/application/v6/applications/cli_app/visibility/check_white_black_list"

  defp user_path, do: "/open-apis/contact/v3/users/#{@open_id}"
end
