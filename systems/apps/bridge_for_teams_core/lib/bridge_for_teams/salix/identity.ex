defmodule BridgeForTeams.Salix.Identity do
  @moduledoc false

  @generated_id_retries 5

  def retry_generated(fun, identity_fields, attempts \\ @generated_id_retries)
      when is_function(fun, 0) and is_list(identity_fields) and attempts > 0 do
    case fun.() do
      {:error, %Ecto.Changeset{} = changeset} = error ->
        if identity_collision?(changeset, identity_fields) and attempts > 1 do
          retry_generated(fun, identity_fields, attempts - 1)
        else
          error
        end

      result ->
        result
    end
  end

  defp identity_collision?(changeset, identity_fields) do
    Enum.any?(changeset.errors, fn
      {field, {_message, metadata}} ->
        field in identity_fields and metadata[:constraint] == :unique

      _error ->
        false
    end)
  end
end
