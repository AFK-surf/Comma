defmodule SalixAgent.ToolsOwnerEmailTest do
  @moduledoc """
  Owner notification tool (`SalixAgent.Tools.OwnerEmail`): `email.send_to_owners`
  against a Bandit mock of the Postmark /email endpoint, with a stub group
  context providing the platform-managed `owner_emails` list. Asserts the
  recipient list is resolved server-side and never surfaces in tool output or
  error messages.
  """
  use SystemsClock.Case, async: false

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

    defp record, do: SystemsRuntime.get_env(:salix_agent, :owner_email_stub_group)

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

    # Bind the request's address: macOS permits a wildcard listener to coexist
    # with another loopback service. Let the kernel reserve an unused endpoint.
    bandit = start_supervised!({Bandit, plug: MockPostmark, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)

    prev = Map.new(@env_keys, fn {app, key} -> {{app, key}, SystemsRuntime.get_env(app, key)} end)

    SystemsRuntime.put_env(:salix_store, :postmark_base_url, "http://127.0.0.1:#{port}")
    SystemsRuntime.put_env(:salix_store, :postmark_server_token, "test-token")
    SystemsRuntime.put_env(:salix_agent, :owner_notification_from_email, "agents@comma.test")
    SystemsRuntime.put_env(:salix_agent, :group_context_mod, StubGroupContext)
    SystemsRuntime.put_env(:salix_agent, :owner_email_stub_group, %{"owner_emails" => @owners})

    on_exit(fn ->
      Enum.each(prev, fn
        {{app, key}, nil} -> SystemsRuntime.delete_env(app, key)
        {{app, key}, value} -> SystemsRuntime.put_env(app, key, value)
      end)
    end)

    {:ok, ctx: %{agent_id: "agent-oe", tenant_id: "tenant-oe", group_id: "group-oe"}}
  end

  describe "defs/0" do
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

    for {name, app, key} <- [
          {"the Postmark sender", :salix_store, :postmark_server_token},
          {"the tool's from address", :salix_agent, :owner_notification_from_email}
        ] do
    end
  end
end
