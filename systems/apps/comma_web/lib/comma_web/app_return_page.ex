defmodule CommaWeb.AppReturnPage do
  @moduledoc false

  # The fixed script reads the escaped link. Callback values never become code.
  @script """
  const returnLink = document.getElementById("comma-return");
  let closeTimer;
  const closeLater = () => {
    window.clearTimeout(closeTimer);
    closeTimer = window.setTimeout(() => window.close(), 1500);
  };
  returnLink.addEventListener("click", closeLater);
  document.getElementById("comma-close")?.addEventListener("click", () => window.close());
  if (returnLink.dataset.autoReturn === "true") {
    closeLater();
    window.setTimeout(() => { window.location.href = returnLink.href; }, 250);
  }
  """

  def script, do: "<script>" <> @script <> "</script>"

  # Retain the callback CSP. Permit only the script owned by this page.
  def content_security_policy do
    digest = :crypto.hash(:sha256, @script) |> Base.encode64()

    "default-src 'none'; style-src 'unsafe-inline'; script-src 'sha256-#{digest}'; " <>
      "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
  end
end
