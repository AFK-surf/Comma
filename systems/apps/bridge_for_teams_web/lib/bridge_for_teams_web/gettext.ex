defmodule BridgeForTeamsWeb.Gettext do
  @moduledoc """
  Gettext backend for the BridgeForTeams dashboard.

  Call sites bring the `gettext/1,2`, `dgettext/3`, `ngettext/3`, … macros into
  scope with `use Gettext, backend: BridgeForTeamsWeb.Gettext` — this is wired
  into the shared `html_helpers/0` (see `BridgeForTeamsWeb.Dashboard`) so every
  LiveView, component, and HTML controller can translate without extra
  boilerplate.

  Catalogs live under `priv/gettext/{en,zh_Hans}/LC_MESSAGES/`. The supported
  locales and default are configured in `config/config.exs` and mirrored in
  `BridgeForTeamsWeb.I18n`. See `docs/bridge-for-teams/design.md`.
  """
  use Gettext.Backend, otp_app: :bridge_for_teams_web
end
