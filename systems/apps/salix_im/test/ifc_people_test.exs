defmodule SalixIM.IFCPeopleTest do
  @moduledoc """
  The Data policy page finds a person of a connect by name, email or user id
  and shows every id with its name and email (`SalixIM.IFC.People`), with the
  provider directories faked: Lark matches a name in the stored copy of its
  Contacts data range, else walks the range, and reads an email or open_id
  directly; Slack asks the workspace directory.
  """

  use SystemsClock.Case, async: false

  alias SalixIM.IFC.{Admin, People}
  alias SalixIM.ProviderObservations
  alias SalixStore.{CasRecord, Ids, Keys, S3}

  defmodule FakeDirectory do
    @moduledoc "Lark's contact API and Slack's users API, as far as the page reads them."
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      conn = fetch_query_params(conn)
      {:ok, raw, conn} = read_body(conn)
      params = Map.merge(conn.query_params, decode(raw))
      path = "/" <> Enum.join(conn.path_info, "/")

      answer =
        if get_req_header(conn, "authorization") == ["Bearer broken"],
          do: %{"code" => 40_004, "msg" => "no dept authority error"},
          else: answer(conn.method, path, params)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(answer))
    end

    defp decode(""), do: %{}

    defp decode(raw) do
      case Jason.decode(raw) do
        {:ok, %{} = body} -> body
        _ -> URI.decode_query(raw)
      end
    end

    defp answer("POST", "/open-apis/auth/v3/tenant_access_token/internal", %{
           "app_id" => "cli_broken"
         }),
         do: %{"code" => 0, "tenant_access_token" => "broken", "expire" => 7200}

    defp answer("POST", "/open-apis/auth/v3/tenant_access_token/internal", _),
      do: %{"code" => 0, "tenant_access_token" => "t", "expire" => 7200}

    # The data range is the whole tenant: Ann sits in a sub-department.
    defp answer("GET", "/open-apis/contact/v3/scopes", _),
      do: %{"code" => 0, "data" => %{"department_ids" => ["0"], "has_more" => false}}

    defp answer("GET", "/open-apis/contact/v3/departments/0/children", _),
      do: %{
        "code" => 0,
        "data" => %{
          "items" => [
            %{"open_department_id" => "od_sales", "name" => "Sales", "parent_department_id" => "0"}
          ],
          "has_more" => false
        }
      }

    defp answer("GET", "/open-apis/contact/v3/users/find_by_department", %{
           "department_id" => "od_sales"
         }),
         do: %{"code" => 0, "data" => %{"items" => [lark_ann()], "has_more" => false}}

    defp answer("GET", "/open-apis/contact/v3/users/find_by_department", _),
      do: %{"code" => 0, "data" => %{"items" => [], "has_more" => false}}

    defp answer("GET", "/open-apis/contact/v3/users/ou_ann", _),
      do: %{"code" => 0, "data" => %{"user" => lark_ann()}}

    defp answer("GET", "/open-apis/contact/v3/users/ou_bob", _),
      do: %{"code" => 0, "data" => %{"user" => %{"name" => "Bob", "email" => "bob@acme.test"}}}

    defp answer("POST", "/open-apis/contact/v3/users/batch_get_id", %{
           "emails" => ["bob@acme.test"]
         }),
         do: %{
           "code" => 0,
           "data" => %{"user_list" => [%{"user_id" => "ou_bob", "email" => "bob@acme.test"}]}
         }

    defp answer("POST", "/api/users.lookupByEmail", %{"email" => "cat@acme.test"}),
      do: %{"ok" => true, "user" => slack_user("U02CAT", "Cat Chen", "cat@acme.test")}

    defp answer("POST", "/api/users.info", %{"user" => "U02CAT"}),
      do: %{"ok" => true, "user" => slack_user("U02CAT", "Cat Chen", "cat@acme.test")}

    defp answer("POST", "/api/users.list", _),
      do: %{
        "ok" => true,
        "members" => [
          slack_user("U02CAT", "Cat Chen", "cat@acme.test"),
          slack_user("U03DAN", "Dan Wu", "dan@acme.test"),
          Map.put(slack_user("U04OLD", "Cat Old", "old@acme.test"), "deleted", true)
        ],
        "response_metadata" => %{"next_cursor" => ""}
      }

    defp answer(_method, _path, _params),
      do: %{"code" => 99_999, "ok" => false, "error" => "not_faked"}

    defp lark_ann,
      do: %{
        "open_id" => "ou_ann",
        "name" => "孙宽",
        "email" => "ann@acme.test",
        "department_ids" => ["od_sales"]
      }

    defp slack_user(id, name, email),
      do: %{
        "id" => id,
        "name" => String.downcase(name),
        "profile" => %{"real_name" => name, "email" => email}
      }
  end

  setup do
    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      lark: SystemsRuntime.get_env(:salix_im, :lark_api_base_url),
      slack: SystemsRuntime.get_env(:salix_im, :slack_api_base_url)
    }

    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    if SystemsRuntime.Proc.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    bandit =
      start_supervised!(
        {Bandit, plug: FakeDirectory, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    SystemsRuntime.put_env(:salix_im, :lark_api_base_url, "http://127.0.0.1:#{port}/open-apis")
    SystemsRuntime.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")
    SalixIM.Provider.Lark.API.reset_token_cache()

    on_exit(fn ->
      for {key, value} <- [
            {{:salix_store, :s3_backend}, previous.s3},
            {{:salix_im, :lark_api_base_url}, previous.lark},
            {{:salix_im, :slack_api_base_url}, previous.slack}
          ] do
        {app, name} = key

        if is_nil(value),
          do: SystemsRuntime.delete_env(app, name),
          else: SystemsRuntime.put_env(app, name, value)
      end

      SalixIM.Provider.Lark.API.reset_token_cache()
    end)

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)

    {:ok, _} =
      S3.put(
        Keys.ctl_group(group),
        Jason.encode!(%{
          "group_id" => group,
          "tenant_id" => tenant,
          "router_conversation_id" => Ids.new_conversation_id(),
          "ifc" => %{
            "supervisors" => [
              "provider_user|lark-people|ou_ann",
              "provider_user|lark-people|ou_bob"
            ]
          }
        })
      )

    lark =
      connect(tenant, group, "lark-people", %{
        "provider" => "lark",
        "app_id" => "cli_x",
        "app_secret" => "s"
      })

    connect(tenant, group, "slack-people", %{
      "provider" => "slack",
      "bot_token" => "xoxb-test",
      "workspace_id" => "T1"
    })

    :ok = ProviderObservations.upsert_lark_user(lark, %{"open_id" => "ou_ann"})

    {:ok, tenant: tenant, group: group, lark: lark}
  end

  defp connect(tenant, group, connect_id, attrs) do
    record =
      Map.merge(
        %{
          "tenant_id" => tenant,
          "group_id" => group,
          "connect_id" => connect_id,
          "status" => "connected"
        },
        attrs
      )

    {:ok, _} = CasRecord.create(Keys.ctl_im_connect(group, connect_id), record)
    record
  end

  test "a Lark person is found by name in the directory, by email or by open_id", ctx do
    # A person the bot has seen is no better known than anyone else: an event
    # names its sender by id only.
    assert {:ok, [%{"id" => "ou_ann", "name" => "孙宽", "email" => "ann@acme.test"}]} =
             Admin.people(ctx.tenant, ctx.group, "lark-people", "孙宽")

    assert {:ok, [%{"id" => "ou_bob", "name" => "Bob", "email" => "bob@acme.test"}]} =
             Admin.people(ctx.tenant, ctx.group, "lark-people", "bob@acme.test")

    assert {:ok, [%{"id" => "ou_bob", "name" => "Bob"}]} =
             Admin.people(ctx.tenant, ctx.group, "lark-people", "ou_bob")

    # The whole data range was read and nobody matches.
    assert {:ok, []} = Admin.people(ctx.tenant, ctx.group, "lark-people", "nobody")
  end

  test "a name search the directory refused is not reported as nobody", ctx do
    connect(ctx.tenant, ctx.group, "lark-broken", %{
      "provider" => "lark",
      "app_id" => "cli_broken",
      "app_secret" => "s"
    })

    assert {:error, :directory_incomplete} =
             Admin.people(ctx.tenant, ctx.group, "lark-broken", "孙宽")
  end

  test "a name in the stored directory is found without a directory walk", ctx do
    # This app's directory refuses every read; only its stored copy names Ann.
    connect(ctx.tenant, ctx.group, "lark-broken", %{
      "provider" => "lark",
      "app_id" => "cli_broken",
      "app_secret" => "s"
    })

    {:ok, _} =
      CasRecord.create(Keys.ctl_im_lark_directory("lark-broken"), %{
        "connect_id" => "lark-broken",
        "complete" => true,
        "synced_at" => SystemsClock.system_time(:millisecond),
        "people" => [
          %{
            "open_id" => "ou_ann",
            "name" => "孙宽",
            "email" => "ann@acme.test",
            "departments" => ["Sales"]
          }
        ]
      })

    assert {:ok, [%{"id" => "ou_ann", "name" => "孙宽", "email" => "ann@acme.test"}]} =
             Admin.people(ctx.tenant, ctx.group, "lark-broken", "孙宽")
  end

  test "a Slack person is found by name, email or member id", ctx do
    assert {:ok, [%{"id" => "U02CAT", "name" => "Cat Chen", "email" => "cat@acme.test"}]} =
             Admin.people(ctx.tenant, ctx.group, "slack-people", "cat")

    assert {:ok, [%{"id" => "U02CAT"}]} =
             Admin.people(ctx.tenant, ctx.group, "slack-people", "cat@acme.test")

    assert {:ok, [%{"id" => "U02CAT"}]} =
             Admin.people(ctx.tenant, ctx.group, "slack-people", "U02CAT")

    assert {:ok, []} = Admin.people(ctx.tenant, ctx.group, "slack-people", "nobody")
  end

  test "a supervisor's name and email come from the directory, seen by the bot or not", ctx do
    # Before the sender's name was dropped, an event stored its sender_type as
    # the name; such a record names nobody.
    {:ok, _} =
      CasRecord.update(Keys.ctl_im_lark_user("lark-people", "ou_ann"), fn current ->
        Map.merge(current, %{"name" => "user", "email" => ""})
      end)

    assert {:ok, [listed]} = ProviderObservations.list_lark_users("lark-people", "", 50)
    refute Map.has_key?(listed, "name")

    assert {:ok,
            %{
              "ou_ann" => %{"name" => "孙宽", "email" => "ann@acme.test"},
              "ou_bob" => %{"name" => "Bob", "email" => "bob@acme.test"}
            }} = Admin.describe_people(ctx.tenant, ctx.group, "lark-people", ["ou_ann", "ou_bob"])
  end

  test "another Group's connect is not readable", ctx do
    other = Ids.new_group_id(ctx.tenant)
    assert {:error, :connect_not_found} = People.search(ctx.tenant, other, "lark-people", "ann")
  end
end
