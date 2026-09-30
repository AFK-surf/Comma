defmodule BillingCore.BillingJSONRepair do
  @moduledoc "Converge Comma billing JSON expressions after the graceful core rollout."

  @columns [
             {"billing_packages", "code", "metadata", "surface = 'comma'"},
             {"billing_package_versions", "id", "usage_policy", "surface = 'comma'"},
             {"billing_provider_prices", "id", "metadata",
              "package_code IN (SELECT code FROM billing_packages WHERE surface = 'comma')"},
             {"billing_provider_customers", "id", "metadata", "surface = 'comma'"},
             {"billing_subscriptions", "id", "source_metadata", "surface = 'comma'"},
             {"billing_one_time_purchases", "id", "source_metadata", "surface = 'comma'"}
           ] ++
             for(
               column <- ["metadata", "package_snapshot", "policy_snapshot"],
               do:
                 {"credit_grants", "id", column,
                  "billing_account_id IN (SELECT id FROM billing_accounts WHERE surface = 'comma')"}
             )

  def run(repo) do
    columns =
      @columns ++
        [
          {"credit_grant_events", "id", "snapshot",
           "billing_account_id IN (SELECT id FROM billing_accounts WHERE surface = 'comma')"}
        ]

    Map.new(columns, fn {table, _, column, _} = spec ->
      {{table, column}, repair(repo, spec, 0)}
    end)
  end

  defp repair(repo, {table, identity, column, condition} = spec, count) do
    {:ok, size} =
      repo.transaction(fn ->
        rows =
          Ecto.Adapters.SQL.query!(
            repo,
            """
            SELECT #{identity}, #{column} FROM #{table}
            WHERE #{condition} AND jsonb_typeof(#{column}) <> 'object'
            ORDER BY #{identity} LIMIT 100 FOR UPDATE
            """,
            []
          ).rows

        Enum.each(rows, fn [id, raw] ->
          object =
            try do
              BillingCore.Metadata.object(raw)
            rescue
              error ->
                raise "invalid Comma billing JSON at #{table}.#{column}/#{id}: #{Exception.message(error)}"
            end

          Ecto.Adapters.SQL.query!(
            repo,
            "UPDATE #{table} SET #{column} = $2 WHERE #{identity} = $1",
            [id, object]
          )
        end)

        length(rows)
      end)

    if size == 0, do: count, else: repair(repo, spec, count + size)
  end
end
