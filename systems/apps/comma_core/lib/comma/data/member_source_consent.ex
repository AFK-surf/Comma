defmodule Comma.Data.MemberSourceConsent do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "comma_member_source_consents" do
    field(:workspace_id, :string, primary_key: true)
    field(:user_id, :string, primary_key: true)
    field(:toolkit, :string, primary_key: true)
    field(:connection_id, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
