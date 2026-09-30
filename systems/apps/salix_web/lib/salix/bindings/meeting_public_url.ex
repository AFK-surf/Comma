defmodule Salix.Bindings.MeetingPublicURL do
  @moduledoc false

  @behaviour SalixMeet.Ports.PublicURL

  @impl true
  def base_url, do: SalixWeb.Application.public_base_url()
end
