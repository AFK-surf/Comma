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

  defmodule AttachmentProxy do
    def create_proxy_session(_settings, _group, _account, "outlook", _opts),
      do: {:ok, "test-session"}

    def delete_proxy_session(_settings, "test-session"), do: :ok

    def proxy_execute(_settings, "test-session", %{"endpoint" => endpoint}, _opts) do
      message = %{
        "id" => "AAMk1=",
        "conversationId" => "thread-1",
        "webLink" => "https://outlook.office.com/mail/id/AAMk1",
        "subject" => "Error report",
        "body" => %{"contentType" => "text", "content" => "Details in the file."},
        "sentDateTime" => "2026-10-02T12:00:00Z",
        "hasAttachments" => true
      }

      file = fn id, name, type, size ->
        %{
          "@odata.type" => "#microsoft.graph.fileAttachment",
          "id" => id,
          "name" => name,
          "contentType" => type,
          "size" => size,
          "isInline" => false
        }
      end

      data =
        case URI.parse(endpoint).path do
          "/v1.0/me" ->
            %{"id" => "self", "mail" => "me@example.com"}

          "/v1.0/me/messages" ->
            %{"value" => [message]}

          "/v1.0/me/messages/AAMk1%3D" ->
            message

          "/v1.0/me/messages/AAMk1%3D/attachments" ->
            %{
              "value" => [
                file.("log", "crash.log", "application/octet-stream", 40),
                file.("pdf", "invoice.pdf", "application/pdf", 9_000),
                file.("big", "dump.txt", "text/plain", 5_000_000)
              ]
            }

          "/v1.0/me/messages/AAMk1%3D/attachments/log" ->
            %{"contentBytes" => Base.encode64("ScreenCam 1.0.15 crashed")}
        end

      {:ok, %{"status" => 200, "data" => data}}
    end
  end

  test "reads the message's small text attachments and names the others" do
    previous = SystemsRuntime.get_env(:salix_web, :composio_client_mod)
    SystemsRuntime.put_env(:salix_web, :composio_client_mod, AttachmentProxy)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_web, :composio_client_mod, previous),
        else: SystemsRuntime.delete_env(:salix_web, :composio_client_mod)
    end)

    assert {:ok, %{"attachments_read" => true, "attachments" => files}} =
             ProactiveOutlookMailSource.read(%{}, "owner-group", "outlook-account", "AAMk1=")

    assert [
             %{"name" => "crash.log", "text" => "ScreenCam 1.0.15 crashed", "truncated" => false},
             %{"name" => "invoice.pdf"} = pdf,
             %{"name" => "dump.txt"} = big
           ] = files

    refute Map.has_key?(pdf, "text")
    refute Map.has_key?(big, "text")
  end
end
