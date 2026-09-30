defmodule Comma.EmailDelivery do
  @moduledoc "Email delivery boundary for Comma product auth."

  @callback send_login_code(String.t(), String.t(), map()) :: :ok | {:error, term()}

  @spec message(String.t() | atom() | nil, String.t()) :: {String.t(), String.t()}
  def message(purpose, code)

  def message(purpose, code) when purpose in ["google_link", :google_link] do
    {
      "Confirm your Google account link",
      "Your Comma Google account linking code is #{code}.\n\n" <>
        "Use this code only if you started linking Google to your Comma account. " <>
        "This code expires soon."
    }
  end

  def message("ssh_enrollment", code) do
    {"Connect an SSH key to Comma",
     "Your Comma SSH enrollment code is #{code}.\n\n" <>
       "Enter it only in the SSH connection you started. This grants future account access to that key."}
  end

  def message(_purpose, code) do
    {
      "Your Comma login code",
      "Your Comma login verification code is #{code}.\n\nThis code expires soon."
    }
  end

  def render(purpose, code, opts \\ %{}) do
    {subject, text} = message(purpose, code)
    ttl = Map.get(opts, :ttl_seconds, 900)
    duration = if rem(ttl, 60) == 0, do: "#{div(ttl, 60)} minutes", else: "#{ttl} seconds"
    expiry = "This code expires in #{duration}."
    text = String.replace(text, "This code expires soon.", expiry)
    text = if String.contains?(text, expiry), do: text, else: text <> "\n\n" <> expiry

    logo_url =
      String.trim_trailing(Application.fetch_env!(:comma_web, :web_cookie_origin), "/") <>
        "/brand/comma/icon.png"

    intro =
      case purpose do
        purpose when purpose in ["google_link", :google_link] ->
          "Use this code only if you started linking Google to your Comma account."

        "ssh_enrollment" ->
          "Enter this code only in the SSH connection you started. This grants future account access to that key."

        _ ->
          "You're signing in to Comma. Please use the code below to validate your email."
      end

    title =
      if purpose in [nil, "email_login", :email_login], do: "Validate your email", else: subject

    html = html(title, intro, code, expiry, Date.utc_today().year, logo_url)

    %{
      subject: subject,
      text: text <> "\n\nContact " <> support_email(),
      html: html
    }
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp html(title, intro, code, expiry, year, logo_url) do
    """
    <!DOCTYPE html>
    <html lang="en" dir="ltr">
    <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="x-apple-disable-message-reformatting"><title>#{escape(title)}</title></head>
    <body style="margin:0;padding:0;background-color:#ffffff;color:#141414;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,Helvetica,sans-serif">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr><td align="center" style="padding:32px 24px 48px">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:510px;text-align:left">
          <tr><td style="padding-bottom:24px"><img src="#{escape(logo_url)}" alt="Comma" width="40" height="40" style="display:block;border:0"></td></tr>
          <tr><td><h1 style="margin:0;font-size:24px;line-height:32px;font-weight:600;letter-spacing:-0.24px">#{escape(title)}</h1></td></tr>
          <tr><td style="padding-top:28px;font-size:16px;line-height:26px">Hi,</td></tr>
          <tr><td style="padding-top:4px;font-size:16px;line-height:26px">#{escape(intro)}</td></tr>
          <tr><td style="padding-top:28px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr><td align="center" style="padding:16px 8px;background-color:#f5f5f5;border-radius:6px;font-size:28px;line-height:36px;font-weight:600;letter-spacing:2px">#{escape(code)}</td></tr></table></td></tr>
          <tr><td style="padding-top:8px;font-size:13px;line-height:20px">#{escape(expiry)}</td></tr>
          <tr><td style="padding-top:32px;font-size:14px;line-height:22px;color:#7a7a7a">Contact <a href="mailto:#{escape(support_email())}" style="color:#7a7a7a;text-decoration:underline">#{escape(support_email())}</a></td></tr>
          <tr><td style="padding-top:24px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr><td style="border-top:1px solid #e6e6e6"></td></tr></table></td></tr>
          <tr><td style="padding-top:24px;font-size:14px;line-height:22px;color:#7a7a7a">© #{year} AFK INC.</td></tr>
        </table>
      </td></tr></table>
    </body></html>
    """
  end

  defp support_email do
    Application.get_env(:comma_core, :support_email, "support@comma.surf")
  end
end
