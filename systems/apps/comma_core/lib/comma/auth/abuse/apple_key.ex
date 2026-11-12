defmodule Comma.Auth.Abuse.AppleKey do
  @moduledoc "Verified App Attest material bound to one exact auth target, without User or Device authority."
  use Ecto.Schema
  @primary_key {:key_id, :string, autogenerate: false}
  schema "comma_app_attest_keys" do
    field(:email_fingerprint, :string)
    field(:app_id, :string)
    field(:environment, :string)
    field(:public_key, :binary)
    field(:counter, :integer, default: 0)
    field(:inserted_at, :utc_datetime_usec)
  end
end
