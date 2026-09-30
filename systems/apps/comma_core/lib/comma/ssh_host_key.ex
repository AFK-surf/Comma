defmodule Comma.SSHHostKey do
  @moduledoc "One durable SSH endpoint key shared by serving replicas."
  alias Comma.Repo

  defmodule Key do
    use Ecto.Schema
    @primary_key {:name, :string, autogenerate: false}
    schema "comma_ssh_host_keys" do
      field(:private_key_pem, :string)
    end
  end

  def load_or_create! do
    if Repo.get(Key, "default") == nil do
      private = :public_key.generate_key({:namedCurve, :ed25519})
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, private)])

      Repo.insert!(%Key{name: "default", private_key_pem: pem},
        on_conflict: :nothing,
        conflict_target: :name,
        log: false
      )
    end

    row = Repo.get!(Key, "default")

    case :public_key.pem_decode(row.private_key_pem) do
      [entry] -> :public_key.pem_entry_decode(entry)
      _ -> raise "Cannot decode persisted Comma SSH host key"
    end
  end
end
