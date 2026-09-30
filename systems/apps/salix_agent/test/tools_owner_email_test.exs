defmodule SalixAgent.ToolsOwnerEmailTest do
  @moduledoc """
  Owner notification tool (`SalixAgent.Tools.OwnerEmail`): `email.send_to_owners`
  against a Bandit mock of the Postmark /email endpoint, with a stub group
  context providing the platform-managed `owner_emails` list. Asserts the
  recipient list is resolved server-side and never surfaces in tool output or
  error messages.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.Tools.OwnerEmail

  @owners ["alice@example.com", "bob@example.com"]

  defmodule MockPostmark do
    @moduledoc "Mock Postmark /email endpoint; records requests for assertions."
    @behaviour Plug
    import Plug.Conn

    def start_link(_), do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
    def requests, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()
    def last_request, do: __MODULE__ |> Agent.get(& &1) |> List.first()

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{method: "POST", request_path: "/email"} = conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      req = Jason.decode!(raw)
      token = conn |> get_req_header("x-postmark-server-token") |> List.first()
      Agent.update(__MODULE__, &[%{body: req, token: token} | &1])

      cond do
        String.contains?(req["Subject"] || "", "reject-422") ->
          resp = %{"ErrorCode" => 300, "Message" => "Invalid 'To' address: 'alice@example.com'."}

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(422, Jason.encode!(resp))

        String.contains?(req["Subject"] || "", "reject-200") ->
          resp = %{"ErrorCode" => 406, "Message" => "Inactive recipient"}

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(resp))

        true ->
          resp = %{"ErrorCode" => 0, "Message" => "OK", "MessageID" => "mid-1"}

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(resp))
      end
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")
  end

  defmodule StubGroupContext do
    @moduledoc "Group context returning the owner_emails configured via app env."
    @behaviour SalixAgent.GroupContext

    defp record, do: Application.get_env(:salix_agent, :owner_email_stub_group)

    @impl true
    def list(_tenant_id), do: []

    @impl true
    def get(group_id, tenant_id) do
      case record() do
        %{} = rec -> {:ok, Map.merge(%{"group_id" => group_id, "tenant_id" => tenant_id}, rec)}
        {:error, _} = err -> err
        nil -> {:error, :not_found}
      end
    end
  end

  # The Postmark HTTP client (token + endpoint) lives on :salix_store; the
  # tool's From address stays on :salix_agent.
  @env_keys [
    {:salix_store, :postmark_base_url},
    {:salix_store, :postmark_server_token},
    {:salix_agent, :owner_notification_from_email},
    {:salix_agent, :group_context_mod},
    {:salix_agent, :owner_email_stub_group}
  ]

  setup do
    start_supervised!(MockPostmark)

    # Retry on port collisions (randomized ports can collide across suites).
    port =
      Enum.find_value(1..10, fn _ ->
        p = 40000 + :erlang.phash2(make_ref(), 20000)

        case start_supervised({Bandit, plug: MockPostmark, port: p}, id: {:bandit, p}) do
          {:ok, _pid} -> p
          {:error, _} -> nil
        end
      end)

    prev = Map.new(@env_keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)

    Application.put_env(:salix_store, :postmark_base_url, "http://127.0.0.1:#{port}")
    Application.put_env(:salix_store, :postmark_server_token, "test-token")
    Application.put_env(:salix_agent, :owner_notification_from_email, "agents@comma.test")
    Application.put_env(:salix_agent, :group_context_mod, StubGroupContext)
    Application.put_env(:salix_agent, :owner_email_stub_group, %{"owner_emails" => @owners})

    on_exit(fn ->
      Enum.each(prev, fn
        {{app, key}, nil} -> Application.delete_env(app, key)
        {{app, key}, value} -> Application.put_env(app, key, value)
      end)
    end)

    {:ok, ctx: %{agent_id: "agent-oe", tenant_id: "tenant-oe", group_id: "group-oe"}}
  end

  describe "defs/0" do
    test "exposes email.send_to_owners as a 2-arity fun with normal auto wait" do
      assert [{"email.send_to_owners", desc, fun, 20, [safety: "write"]}] = OwnerEmail.defs()
      assert is_function(fun, 2)
      assert desc =~ "not visible"
    end
  end

  describe "email.send_to_owners" do
    test "sends one message to every configured owner without echoing addresses", %{ctx: ctx} do
      out = OwnerEmail.send_to_owners(%{"subject" => "Report", "body" => "All done."}, ctx)

      assert Jason.decode!(out) == %{"status" => "sent", "recipients" => 2}
      for owner <- @owners, do: refute(out =~ owner)

      assert [%{body: body, token: "test-token"}] = MockPostmark.requests()
      assert body["From"] == "agents@comma.test"
      assert body["To"] == Enum.join(@owners, ",")
      assert body["Subject"] == "Report"
      assert body["TextBody"] == "All done."
      assert body["MessageStream"] == "outbound"
    end

    test "normalizes the record's owner list before sending", %{ctx: ctx} do
      Application.put_env(:salix_agent, :owner_email_stub_group, %{
        "owner_emails" => [" alice@example.com ", "", "alice@example.com", nil, "bob@example.com"]
      })

      out = OwnerEmail.send_to_owners(%{"subject" => "s", "body" => "b"}, ctx)

      assert Jason.decode!(out)["recipients"] == 2
      assert MockPostmark.last_request().body["To"] == "alice@example.com,bob@example.com"
    end

    test "rejects a missing subject or body without calling Postmark", %{ctx: ctx} do
      assert_raise RuntimeError, ~r/missing subject/, fn ->
        OwnerEmail.send_to_owners(%{"body" => "b"}, ctx)
      end

      assert_raise RuntimeError, ~r/missing body/, fn ->
        OwnerEmail.send_to_owners(%{"subject" => "s"}, ctx)
      end

      assert MockPostmark.requests() == []
    end

    test "errors politely when the group has no owner emails", %{ctx: ctx} do
      for record <- [%{}, %{"owner_emails" => []}, {:error, :not_found}] do
        Application.put_env(:salix_agent, :owner_email_stub_group, record)

        assert_raise RuntimeError, ~r/no owner email addresses are configured/, fn ->
          OwnerEmail.send_to_owners(%{"subject" => "s", "body" => "b"}, ctx)
        end
      end

      assert MockPostmark.requests() == []
    end

    test "surfaces Postmark rejections without leaking recipient addresses", %{ctx: ctx} do
      err =
        assert_raise RuntimeError, fn ->
          OwnerEmail.send_to_owners(%{"subject" => "reject-422", "body" => "b"}, ctx)
        end

      assert err.message =~ "postmark http 422 error code 300"
      for owner <- @owners, do: refute(err.message =~ owner)
    end

    test "treats a 200 response with a non-zero ErrorCode as a failure", %{ctx: ctx} do
      assert_raise RuntimeError, ~r/postmark http 200 error code 406/, fn ->
        OwnerEmail.send_to_owners(%{"subject" => "reject-200", "body" => "b"}, ctx)
      end
    end

    for {name, app, key} <- [
          {"the Postmark sender", :salix_store, :postmark_server_token},
          {"the tool's from address", :salix_agent, :owner_notification_from_email}
        ] do
      test "errors when #{name} is not configured", %{ctx: ctx} do
        Application.put_env(unquote(app), unquote(key), "")

        assert_raise RuntimeError, ~r/set the Postmark server token/, fn ->
          OwnerEmail.send_to_owners(%{"subject" => "s", "body" => "b"}, ctx)
        end
      end
    end
  end
end
