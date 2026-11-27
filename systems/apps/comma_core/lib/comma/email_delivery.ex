defmodule Comma.EmailDelivery do
  @moduledoc """
  Email delivery boundary for Comma: login codes for product auth, and short
  notices (`send_notice/4`): the invitation to a Task together (`invitation/1`).
  """

  @callback send_login_code(String.t(), String.t(), map()) :: :ok | {:error, term()}
  @callback send_notice(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  @optional_callbacks send_notice: 4

  @doc "The configured adapter, the same one login codes use."
  def impl do
    :comma_core
    |> SystemsRuntime.get_env(:auth, [])
    |> get_in([:email_delivery]) || Comma.EmailDelivery.Postmark
  end

  @doc """
  The invitation to a Task together: `host` (`name`, `email`) invited the
  reader to `task_title`. `body` says what working together means, `hint`
  how to answer, and one button labeled `action` goes to `url`. Every value
  is escaped; nothing else goes in.
  """
  def invitation(%{
        host: host,
        task_title: task_title,
        body: body,
        hint: hint,
        action: action,
        url: url
      }) do
    origin = String.trim_trailing(SystemsRuntime.fetch_env!(:comma_web, :web_cookie_origin), "/")
    logo_url = origin <> "/brand/comma/icon.png"
    title = "#{host.name} invited you to collaborate"
    initial = host.name |> String.trim() |> String.first() |> Kernel.||("?") |> String.upcase()

    # A name that is the address itself names no one twice.
    host_email =
      if host.email in [nil, ""] or host.email == host.name,
        do: "",
        else: ~s(<span class="muted" style="color:#7a7a7a"> · #{escape(host.email)}</span>)

    text =
      Enum.join(
        [
          title,
          body,
          "Task: \"#{task_title}\"",
          hint,
          action <> ": " <> url,
          "Contact " <> support_email()
        ],
        "\n\n"
      )

    html = """
    <!DOCTYPE html>
    <html lang="en" dir="ltr">
    <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="x-apple-disable-message-reformatting"><meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark"><title>#{escape(title)}</title>
    <style>
      @media (prefers-color-scheme: dark) {
        .page { background-color:#0f0f10 !important; color:#ededed !important; }
        .card { background-color:#18191b !important; border-color:#2a2b2e !important; }
        .muted { color:#9a9a9f !important; }
        .rule { border-color:#2a2b2e !important; }
        .button { background-color:#ededed !important; color:#141414 !important; }
        .avatar { background-color:#ededed !important; color:#141414 !important; }
        .link { color:#9a9a9f !important; }
      }
      @media (max-width: 480px) { .button { display:block !important; text-align:center !important; } }
    </style></head>
    <body class="page" style="margin:0;padding:0;background-color:#ffffff;color:#141414;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,Helvetica,sans-serif">
      <div style="display:none;max-height:0;overflow:hidden">#{escape(host.name)} wants to work on &quot;#{escape(task_title)}&quot; with you in Comma.</div>
      <table role="presentation" class="page" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#ffffff"><tr><td align="center" style="padding:32px 24px 48px">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:510px;text-align:left">
          <tr><td style="padding-bottom:24px"><img src="#{escape(logo_url)}" alt="Comma" width="40" height="40" style="display:block;border:0;border-radius:10px"></td></tr>
          <tr><td><h1 style="margin:0;font-size:24px;line-height:32px;font-weight:600;letter-spacing:-0.24px">#{escape(title)}</h1></td></tr>
          <tr><td style="padding-top:12px;font-size:16px;line-height:26px">#{escape(body)}</td></tr>
          <tr><td style="padding-top:24px">
            <table role="presentation" class="card" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#ffffff;border:1px solid #e6e6e6;border-radius:12px"><tr><td style="padding:20px 24px 22px">
              <div style="font-size:18px;line-height:26px;font-weight:600;letter-spacing:-0.18px;word-break:break-word">#{escape(task_title)}</div>
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:14px"><tr>
                <td class="avatar" width="24" height="24" align="center" valign="middle" style="width:24px;height:24px;border-radius:12px;background-color:#141414;color:#ffffff;font-size:12px;line-height:24px;font-weight:600">#{escape(initial)}</td>
                <td style="padding-left:8px;font-size:14px;line-height:20px" valign="middle"><span style="font-weight:600">#{escape(host.name)}</span>#{host_email}</td>
              </tr></table>
            </td></tr></table>
          </td></tr>
          <tr><td style="padding-top:28px"><a class="button" href="#{escape(url)}" style="display:inline-block;padding:12px 24px;background-color:#141414;color:#ffffff;border-radius:8px;font-size:16px;line-height:20px;font-weight:600;text-decoration:none">#{escape(action)}</a></td></tr>
          <tr><td class="muted" style="padding-top:16px;font-size:14px;line-height:22px;color:#7a7a7a">#{escape(hint)}</td></tr>
          <tr><td style="padding-top:32px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr><td class="rule" style="border-top:1px solid #e6e6e6"></td></tr></table></td></tr>
          <tr><td class="muted" style="padding-top:24px;font-size:14px;line-height:22px;color:#7a7a7a">Contact <a class="link" href="mailto:#{escape(support_email())}" style="color:#7a7a7a;text-decoration:underline">#{escape(support_email())}</a></td></tr>
          <tr><td class="muted" style="padding-top:8px;font-size:14px;line-height:22px;color:#7a7a7a">© #{SystemsClock.utc_now().year} AFK INC.</td></tr>
        </table>
      </td></tr></table>
    </body></html>
    """

    %{subject: title, text: text, html: html}
  end

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

  def message("account_deletion", code) do
    {"Confirm deleting your Comma account",
     "Your Comma account deletion code is #{code}.\n\n" <>
       "Enter it only if you asked to delete your Comma account. Deletion cannot be undone. " <>
       "This code expires soon."}
  end

  def message("email_change_current", code) do
    {"Confirm changing your Comma email",
     "Your Comma email change code is #{code}.\n\n" <>
       "Enter it only if you asked to change the email you sign in to Comma with. " <>
       "This code expires soon."}
  end

  def message("email_change_new", code) do
    {"Confirm your new Comma email",
     "Your Comma email confirmation code is #{code}.\n\n" <>
       "Enter it only if you asked to sign in to Comma with this email. " <>
       "This code expires soon."}
  end

  def message("collaboration_guest", code) do
    {"Your Comma shared task verification code",
     "Your Comma verification code to open the shared task is #{code}.\n\n" <>
       "Enter it only on the shared task link you opened. This code expires soon."}
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
      String.trim_trailing(SystemsRuntime.fetch_env!(:comma_web, :web_cookie_origin), "/") <>
        "/brand/comma/icon.png"

    intro =
      case purpose do
        purpose when purpose in ["google_link", :google_link] ->
          "Use this code only if you started linking Google to your Comma account."

        "ssh_enrollment" ->
          "Enter this code only in the SSH connection you started. This grants future account access to that key."

        "account_deletion" ->
          "Enter this code only if you asked to delete your Comma account. Deletion cannot be undone."

        "email_change_current" ->
          "Enter this code only if you asked to change the email you sign in to Comma with."

        "email_change_new" ->
          "Enter this code only if you asked to sign in to Comma with this email."

        "collaboration_guest" ->
          "Enter this code on the shared task page to verify your email and join the task."

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
    SystemsRuntime.get_env(:comma_core, :support_email, "support@comma.surf")
  end
end
