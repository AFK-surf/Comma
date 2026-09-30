defmodule Comma.EmailDeliveryTest do
  use ExUnit.Case, async: false

  setup do
    origin = Application.fetch_env!(:comma_web, :web_cookie_origin)

    on_exit(fn ->
      Application.put_env(:comma_web, :web_cookie_origin, origin)
    end)
  end

  test "loads the logo from the configured web origin and preserves the code and expiry" do
    for origin <- [
          "https://app.comma.surf",
          "https://app-staging.comma.surf",
          "https://comma.example.com"
        ] do
      Application.put_env(:comma_web, :web_cookie_origin, origin)
      message = Comma.EmailDelivery.render("email_login", "123456", %{ttl_seconds: 120})
      assert message.html =~ ~s(src="#{origin}/brand/comma/icon.png")
      assert message.html =~ "123456"
      assert message.html =~ "2 minutes"
      assert message.text =~ "2 minutes"
    end
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
    recipient = "smtp-template-#{System.unique_integer([:positive])}@example.com"
    assert :ok = Comma.EmailDelivery.SMTP.send_login_code(recipient, "456789", %{ttl_seconds: 120})
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
