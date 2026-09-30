defmodule CommaWeb.TelegramCallbackPage do
  @moduledoc false

  # Standalone adaptation of @comma/ui login/Login.tsx and Button/styles.ts.
  # Typography, spacing and default-mode colors follow ui/src/styles/theme.css.
  # No client bundle or remote assets: use Comma's font fallback stack here.
  # Keep the callback's no-store/CSP policy and fixed return route in the router.
  def render(client, deep_link, success?, reason) do
    {status, label, title, detail} = content(success?, reason)
    client_name = Plug.HTML.html_escape(client.name)
    environment = Plug.HTML.html_escape(client.environment)
    return_url = Plug.HTML.html_escape(deep_link)

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{title} · #{client_name}</title>
        <style>
          :root {
            color-scheme: light dark;
            font-family: 'Inter Variable', 'SF Pro Display', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, 'Open Sans', 'Helvetica Neue', sans-serif;
            font-weight: 450; -webkit-font-smoothing: antialiased;
            color: #1a1b1e; background: #fff;
            --muted: #7f8286;
            --brand: #205bff; --brand-hover: #1040f2; --brand-border: #1040f2; --brand-border-hover: #092fc0;
            --button-shadow: 0 1px 2px 0 rgba(16, 24, 40, .05);
          }
          *, *::before, *::after { box-sizing: border-box; }
          body { margin: 0; min-height: 100vh; min-height: 100svh; display: grid; grid-template-columns: minmax(0, 1fr); place-items: center; padding: 32px 24px; }
          main { width: 100%; max-width: 360px; text-align: center; }
          .comma-mark { display: block; width: 48px; height: 48px; margin: 0 auto 16px; }
          h1 { font-size: 24px; font-weight: 500; letter-spacing: -.02em; line-height: 32px; margin: 0 0 8px; text-wrap: balance; }
          .detail { color: var(--muted); font-size: 13px; line-height: 20px; margin: 0; }
          .actions { display: grid; gap: 16px; margin-top: 24px; }
          .action { display: flex; align-items: center; justify-content: center; min-height: 40px; padding: 9px 14px; border: 1px solid transparent; border-radius: 8px; font: inherit; font-size: 13px; font-weight: 500; line-height: 20px; text-align: center; text-decoration: none; cursor: pointer; transition: background-color 150ms ease, border-color 150ms ease; }
          .primary { background: var(--brand); border-color: var(--brand-border); color: #fff; box-shadow: var(--button-shadow); }
          .secondary { justify-self: center; min-height: 32px; padding: 6px 8px; background: transparent; color: inherit; font-weight: 450; }
          .action:focus-visible { outline: 2px solid var(--brand); outline-offset: 3px; }
          .hint { margin: 16px 0 0; color: var(--muted); font-size: 12px; line-height: 18px; }
          .context { margin: 24px 0 0; color: var(--muted); font-size: 11px; line-height: 16px; }
          @media (hover: hover) and (pointer: fine) {
            .primary:hover { background: var(--brand-hover); border-color: var(--brand-border-hover); }
            .secondary:hover { text-decoration: underline; text-underline-offset: 3px; }
          }
          @media (prefers-color-scheme: dark) {
            :root {
              color: #f6f6f6; background: #0f0f10; --muted: #a4a5a9;
              --button-shadow: 0 1px 2px 0 rgba(0, 0, 0, .32);
            }
          }
          @media (prefers-reduced-motion: reduce) { .action { transition: none; } }
        </style>
      </head>
      <body>
        <main aria-labelledby="result-title" data-status="#{status}">
          #{comma_mark()}
          <section aria-labelledby="result-title">
            <h1 id="result-title">#{title}</h1>
            <p class="detail">#{detail}</p>
            <div class="actions">
              <a id="comma-return" data-auto-return="#{success?}" class="action primary" href="#{return_url}">Return to #{client_name}</a>
              <button class="action secondary" id="comma-close" type="button">Close this window</button>
            </div>
          </section>
          <p class="hint">#{if success?, do: "If this window stays open, return to Comma to continue.", else: "Already have Comma open? Switch back to Settings → Channels."}</p>
          <p class="context">#{environment} · #{label}</p>
        </main>
        #{CommaWeb.AppReturnPage.script()}
      </body>
    </html>
    """
  end

  # Exact CommaMark brand geometry from ui/src/components/login/BrandMarks.tsx.
  # Kept inline so the callback CSP needs no image or remote asset exceptions.
  defp comma_mark do
    ~s(<svg class="comma-mark" role="img" aria-label="Comma" focusable="false" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M24.0293 4.44182C35.2292 4.44193 44.3086 13.5212 44.3086 24.7211C44.3086 26.2292 44.141 27.698 43.8271 29.1117C43.7274 29.5609 43.0935 29.5949 42.8828 29.186C41.9591 27.3916 40.5289 25.8315 38.6514 24.7475C33.4379 21.7378 26.7689 23.5256 23.7588 28.7387C20.7499 33.9519 22.5373 40.6193 27.75 43.6293C27.798 43.657 27.8462 43.6845 27.8945 43.7113C28.2968 43.9348 28.2441 44.5646 27.792 44.6498C26.5728 44.8795 25.3151 45.0004 24.0293 45.0004C12.8294 45.0004 3.75017 35.9209 3.75 24.7211C3.75001 13.5212 12.8293 4.44182 24.0293 4.44182ZM27.5752 30.475C29.5842 26.9956 34.0342 25.803 37.5137 27.8119C40.8501 29.7385 42.081 33.9084 40.4053 37.3158C40.4099 37.3203 40.4144 37.3251 40.4189 37.3295C40.3568 37.4447 40.2857 37.5685 40.2051 37.6977C40.1952 37.715 40.1858 37.7331 40.1758 37.7504C39.7991 38.4028 39.3363 38.9749 38.8105 39.4604C37.1152 41.2376 34.3055 43.2112 30.4131 43.7602C30.2618 43.7814 30.1769 43.5981 30.29 43.4955C30.9997 42.8536 31.8303 42.0905 32.6543 41.2846C31.8262 41.1437 31.0084 40.8571 30.2383 40.4125C26.7589 38.4036 25.5665 33.9545 27.5752 30.475Z" fill="currentColor" /></svg>)
  end

  defp content(true, _reason),
    do:
      {"connected", "Connected", "Telegram connected",
       "You can close this page and return to Comma."}

  defp content(false, :invalid_telegram_oidc_attempt),
    do:
      {"expired", "Request expired", "Telegram connection failed",
       "This login request has expired or is no longer active. Return to Comma and start a new Telegram connection."}

  defp content(false, :telegram_provider_unavailable),
    do:
      {"unavailable", "Try again shortly", "Telegram connection failed",
       "Telegram login is temporarily unavailable. Return to Comma and try again shortly."}

  defp content(false, _reason),
    do:
      {"failed", "Not connected", "Telegram connection failed",
       "Return to Comma and try connecting again."}
end
