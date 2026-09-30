defmodule SalixWeb.OAuthCallbackPage do
  @moduledoc """
  Terminal browser page for every Salix authorization callback that has no
  `redirect_after` (Figma `P0HbtMUd3lTy0FcGn0ojxT`, node `1618:14595`).

  The page is self-contained: logos are the Figma exports under
  `priv/oauth_callback`, inlined at compile time.
  """

  @asset_dir Path.expand("../../priv/oauth_callback", __DIR__)

  # provider key => display name; each key has a `<key>.svg` export.
  @providers %{
    "github" => "GitHub",
    "google" => "Google Workspace",
    "linear" => "Linear",
    "notion" => "Notion",
    "slack" => "Slack"
  }

  @svgs (for name <- ["comma", "arrow", "failed", "mcp" | Map.keys(@providers)], into: %{} do
           path = Path.join(@asset_dir, name <> ".svg")
           @external_resource path
           {name, File.read!(path)}
         end)

  @style "html,body{margin:0;height:100%;background:#fcfcfd;" <>
           ~s(font-family:"Inter Variable",Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;) <>
           "-webkit-font-smoothing:antialiased}" <>
           "body{display:flex;align-items:center;justify-content:center}" <>
           "main{display:flex;flex-direction:column;align-items:center;gap:24px;" <>
           "box-sizing:border-box;width:100%;max-width:514px;padding:0 16px 40px;text-align:center}" <>
           ".logos{display:flex;align-items:center;gap:16px}" <>
           ".tile{position:relative;box-sizing:border-box;width:56px;height:56px;overflow:hidden;" <>
           "border:1px solid #dfe0e2;border-radius:11.667px;background:#fff;" <>
           "box-shadow:0 1px 2px rgba(16,24,40,.05)}" <>
           ".tile.tile-mcp svg{top:8px;left:8px;width:38px;height:38px}" <>
           ".tile svg{position:absolute;top:-1px;left:-1px;width:56px;height:56px}" <>
           ".logos>svg{display:block;flex:none}" <>
           ".text{display:flex;flex-direction:column;gap:4px;width:100%;overflow-wrap:anywhere}" <>
           "h1{margin:0;font-size:20px;font-weight:500;line-height:30px;letter-spacing:-.2px;color:#1b1c1d}" <>
           "p{margin:0;font-size:16px;font-weight:400;line-height:24px;letter-spacing:-.16px;color:#5b5e62}"

  @doc """
  Renders the page. `service` is a provider key or a user-chosen alias; only a
  known provider key gets its logo and product name. A non-nil `error_message`
  renders the failure state.
  """
  @spec render(String.t(), String.t() | nil) :: String.t()
  def render(service, error_message \\ nil) do
    key = service |> to_string() |> String.trim() |> String.downcase()
    name = Map.get(@providers, key, String.trim(to_string(service)))

    render_page(name, key, error_message)
  end

  @doc """
  Renders an MCP connection without treating its user-chosen alias as a provider key.
  The MCP asset is the supplied export from Figma node `1620:14762`.
  """
  @spec render_mcp(String.t(), String.t() | nil) :: String.t()
  def render_mcp(service, error_message \\ nil) do
    name = service |> to_string() |> String.trim()
    name = if name == "", do: "remote MCP", else: name
    render_page(name, :mcp, error_message)
  end

  defp render_page(name, key, error_message) do
    {heading, body} =
      if error_message,
        do: {"Authorization failed", error_message},
        else: {"Successfully connected to " <> name, "You can close this window now."}

    ~s(<!doctype html><html lang="en"><head><meta charset="utf-8"><title>) <>
      escape(heading) <>
      ~s(</title><meta name="viewport" content="width=device-width,initial-scale=1"><style>) <>
      @style <>
      ~s(</style></head><body><main><div class="logos">) <>
      logos(key, if(error_message, do: "failed", else: "arrow")) <>
      ~s(</div><div class="text"><h1>) <>
      escape(heading) <>
      "</h1><p>" <>
      escape(body) <>
      "</p></div></main></body></html>"
  end

  defp logos(:mcp, link),
    do: tile("comma") <> @svgs[link] <> tile("mcp")

  defp logos(key, link) when is_map_key(@providers, key),
    do: tile("comma") <> @svgs[link] <> tile(key)

  defp logos(_key, _link), do: tile("comma")

  defp tile("mcp"),
    do: ~s(<div class="tile tile-mcp" role="img" aria-label="MCP">) <> @svgs["mcp"] <> "</div>"

  defp tile(name), do: ~s(<div class="tile">) <> @svgs[name] <> "</div>"

  defp escape(value), do: Plug.HTML.html_escape(to_string(value))
end
