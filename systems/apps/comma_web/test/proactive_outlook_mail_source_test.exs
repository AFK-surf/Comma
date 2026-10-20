defmodule CommaWeb.ProactiveOutlookMailSourceTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]
  alias CommaWeb.{ProactiveOutlookMailSource, ProactiveRoutine}

  defp message(id, body \\ "<p>Please review</p>") do
    %{
      "id" => id,
      "conversationId" => "thread-1",
      "webLink" => "https://outlook.office.com/mail/id/" <> id,
      "subject" => "Review",
      "from" => %{"emailAddress" => %{"address" => "sender@example.com"}},
      "body" => %{"contentType" => "html", "content" => body},
      "sentDateTime" => "2026-10-02T12:00:00Z",
      "hasAttachments" => false
    }
  end

  defmodule Proxy do
    def create_proxy_session(_settings, group, account, toolkit, _opts) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:session, group, account, toolkit})
      {:ok, "test-session"}
    end

    def delete_proxy_session(_settings, "test-session"),
      do: SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), :deleted_session)

    def proxy_execute(
          _settings,
          "test-session",
          %{"method" => "GET", "endpoint" => endpoint} = request,
          _opts
        ) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:endpoint, endpoint, request["parameters"]}
      )

      message = %{
        "id" => "AAMk1=",
        "conversationId" => "thread-1",
        "webLink" => "https://outlook.office.com/mail/id/AAMk1",
        "subject" => "Review",
        "body" => %{"contentType" => "text", "content" => "Please review"},
        "sentDateTime" => "2026-10-02T12:00:00Z"
      }

      data =
        cond do
          String.contains?(endpoint, "/messages/AAMk1%3D") -> message
          String.contains?(endpoint, "/messages?") -> %{"value" => [message]}
          true -> %{"id" => "self", "mail" => "me@example.com"}
        end

      {:ok, %{"status" => 200, "data" => data}}
    end
  end

  test "pins proxy to Outlook account and checks full conversation before returning" do
    previous = SystemsRuntime.get_env(:salix_web, :composio_client_mod)
    SystemsRuntime.put_env(:salix_web, :composio_client_mod, Proxy)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_web, :composio_client_mod, previous),
        else: SystemsRuntime.delete_env(:salix_web, :composio_client_mod)
    end)

    assert {:ok, %{"mailbox" => "me@example.com", "thread_complete" => true}} =
             ProactiveOutlookMailSource.read(%{}, "owner-group", "outlook-account", "AAMk1=")

    assert_received {:session, "owner-group", "outlook-account", "outlook"}
    # Graph returns text bodies only when asked; its default is HTML.
    text = [
      %{"name" => "Prefer", "value" => ~s(outlook.body-content-type="text"), "type" => "header"}
    ]

    assert_received {:endpoint, "https://graph.microsoft.com/v1.0/me/messages/AAMk1%3D" <> _,
                     ^text}

    assert_received {:endpoint, "https://graph.microsoft.com/v1.0/me/messages?" <> query, ^text}
    assert URI.decode(query) =~ "uniqueBody"
    assert_received :deleted_session

    assert {:error, :invalid_message_id} =
             ProactiveOutlookMailSource.read(%{}, "owner-group", "outlook-account", "../other")
  end
end
