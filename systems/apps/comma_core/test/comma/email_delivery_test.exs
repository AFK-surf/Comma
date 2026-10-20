defmodule Comma.EmailDeliveryTest do
  use SystemsClock.Case, async: false

  setup do
    origin = SystemsRuntime.fetch_env!(:comma_web, :web_cookie_origin)

    on_exit(fn ->
      SystemsRuntime.put_env(:comma_web, :web_cookie_origin, origin)
    end)
  end

  test "escapes HTML and preserves the authorization warning for SSH enrollment" do
    message = Comma.EmailDelivery.render("ssh_enrollment", "<123456>", %{ttl_seconds: 90})
    assert message.html =~ "&lt;123456&gt;"
    assert message.html =~ "This grants future account access to that key."
    assert message.text =~ "This grants future account access to that key."
    assert message.html =~ "90 seconds"
  end

  @tag skip: is_nil(System.get_env("COMMA_TEST_MAILPIT_URL"))
  test "SMTP delivers readable alternatives without attachments" do
    base = System.fetch_env!("COMMA_TEST_MAILPIT_URL")
    recipient = "smtp-template-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.com"

    assert :ok =
             Comma.EmailDelivery.SMTP.send_login_code(recipient, "456789", %{ttl_seconds: 120})

    response = Req.get!(base <> "/api/v1/search", params: [query: "to:" <> recipient])
    assert [%{"ID" => id} | _] = response.body["messages"]
    raw = Req.get!(base <> "/api/v1/message/#{id}/raw").body

    assert {"multipart", "alternative", _headers, _parameters, parts} =
             :mimemail.decode(raw, encoding: :none)

    assert [{"text", "plain", _, _, _}, {"text", "html", _, _, _}] = parts
    received = Req.get!(base <> "/api/v1/message/" <> id).body
    assert received["Text"] =~ "456789"
    assert received["HTML"] =~ "456789"
    assert received["HTML"] =~ "2 minutes"
    assert received["Inline"] == []
    assert received["Attachments"] == []
  end
end
