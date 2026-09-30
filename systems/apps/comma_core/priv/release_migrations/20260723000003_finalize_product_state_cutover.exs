defmodule Comma.Repo.Migrations.FinalizeProductStateCutover do
  use Ecto.Migration
  @disable_ddl_transaction true

  @release_identity "comma-product-state-final-import-v1"

  def up do
    repo = repo()

    case repo.get(Comma.Data.ImportRun, @release_identity) do
      %Comma.Data.ImportRun{status: "complete", evidence_digest: digest}
      when is_binary(digest) ->
        with {:ok, evidence} <-
               Comma.Migrations.ProductStateImporter.audit(
                 repo: repo,
                 expected_ledger_digest: digest,
                 expected_release_identity: @release_identity
               ),
             :ok <- Comma.Migrations.ProductStateImporter.audit_postcondition(evidence) do
          :ok
        else
          {:error, reason} ->
            raise "product-state cutover marker rejected import ledger: #{inspect(reason)}"
        end

      _ ->
        raise "product-state cutover marker requires a complete validated import ledger"
    end
  end
end
