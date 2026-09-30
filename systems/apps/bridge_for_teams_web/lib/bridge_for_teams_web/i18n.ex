defmodule BridgeForTeamsWeb.I18n do
  @moduledoc """
  The single source of truth for the dashboard's supported locales, the default
  locale, their human labels, the `<html lang>` tags, and `Accept-Language`
  negotiation.

  The dashboard supports English (`en`, default) and Simplified Chinese
  (`zh_Hans`).
  The list is mirrored in `config/config.exs` (so Gettext compiles only these
  catalogs) and in `BridgeForTeams.Schema.User`'s changeset validation. Keep the
  three in sync when adding a locale. See `docs/bridge-for-teams/design.md`.
  """

  @default "en"
  @supported ["en", "zh_Hans"]

  # Gettext locale -> BCP-47 tag for <html lang>.
  @lang_tags %{"en" => "en", "zh_Hans" => "zh-Hans"}

  # Native names shown in the locale switcher.
  @labels %{"en" => "English", "zh_Hans" => "中文（简体）"}

  @doc "The default locale used when nothing else resolves."
  @spec default_locale() :: String.t()
  def default_locale, do: @default

  @doc "All supported Gettext locales."
  @spec supported_locales() :: [String.t()]
  def supported_locales, do: @supported

  @doc "Whether `locale` is one we support."
  @spec supported?(term()) :: boolean()
  def supported?(locale), do: locale in @supported

  @doc "The supported locale list as `{label, value}` pairs for a `<select>`/switcher."
  @spec options() :: [{String.t(), String.t()}]
  def options, do: Enum.map(@supported, &{label(&1), &1})

  @doc "The BCP-47 language tag for `<html lang>` (falls back to the default)."
  @spec lang_tag(String.t()) :: String.t()
  def lang_tag(locale), do: Map.get(@lang_tags, locale, Map.fetch!(@lang_tags, @default))

  @doc "The native display label for a locale."
  @spec label(String.t()) :: String.t()
  def label(locale), do: Map.get(@labels, locale, locale)

  @doc """
  Return `locale` if supported, otherwise the first supported value from
  `fallbacks`, otherwise the default. Used by the resolution plug to apply the
  session > user > Accept-Language > default precedence.
  """
  @spec resolve(term(), [term()]) :: String.t()
  def resolve(locale, fallbacks \\ []) do
    [locale | fallbacks]
    |> Enum.find(&supported?/1)
    |> Kernel.||(@default)
  end

  @doc """
  Pick the best supported locale for an `Accept-Language` header value (a string
  or the raw `get_req_header/2` list). Unknown/garbage input yields the default.
  """
  @spec negotiate(String.t() | [String.t()] | nil) :: String.t()
  def negotiate([value | _]), do: negotiate(value)
  def negotiate([]), do: @default

  def negotiate(accept_language) when is_binary(accept_language) do
    accept_language
    |> parse_accept_language()
    |> Enum.find_value(@default, fn tag -> match_tag(tag) end)
  end

  def negotiate(_), do: @default

  # "zh-CN,zh;q=0.9,en;q=0.8" -> ["zh-cn", "zh", "en"] ordered by q desc.
  defp parse_accept_language(header) do
    header
    |> String.split(",", trim: true)
    |> Enum.map(fn part ->
      case String.split(part, ";", parts: 2) do
        [tag] -> {String.downcase(String.trim(tag)), 1.0}
        [tag, q] -> {String.downcase(String.trim(tag)), parse_q(q)}
      end
    end)
    |> Enum.sort_by(fn {_tag, q} -> q end, :desc)
    |> Enum.map(fn {tag, _q} -> tag end)
  end

  defp parse_q("q=" <> value) do
    case Float.parse(value) do
      {q, _} -> q
      :error -> 0.0
    end
  end

  defp parse_q(_), do: 0.0

  # Map a single Accept-Language tag onto a supported locale (or nil).
  defp match_tag("zh" <> _), do: "zh_Hans"
  defp match_tag("en" <> _), do: "en"
  defp match_tag(_), do: nil
end
