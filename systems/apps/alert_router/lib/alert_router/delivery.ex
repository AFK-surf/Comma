defmodule AlertRouter.Delivery do
  @moduledoc """
  Shared, finite delivery policy for Slack mutations and reconciliation.

  Database time is the lease clock. Oban uniqueness is deliberately treated as
  load control only; every Slack permission is backed by a persisted lease and
  every result is fenced by its token.
  """

  alias AlertRouter.Repo

  @spec db_now!() :: DateTime.t()
  def db_now! do
    case Ecto.Adapters.SQL.query!(Repo, "SELECT clock_timestamp()", []) do
      %Postgrex.Result{rows: [[%DateTime{} = now]]} -> now
    end
  end

  @spec lease_expires_at(DateTime.t()) :: DateTime.t()
  def lease_expires_at(%DateTime{} = now), do: DateTime.add(now, lease_seconds(), :second)

  @spec active_lease?(struct(), DateTime.t()) :: boolean()
  def active_lease?(%{delivery_lease_token: token, delivery_lease_expires_at: expires_at}, now) do
    is_binary(token) and is_struct(expires_at, DateTime) and DateTime.after?(expires_at, now)
  end

  @spec lease_wait_seconds(struct(), DateTime.t()) :: pos_integer()
  def lease_wait_seconds(%{delivery_lease_expires_at: %DateTime{} = expires_at}, now) do
    expires_at
    |> DateTime.diff(now, :second)
    |> max(1)
  end

  def lease_wait_seconds(_row, _now), do: 1

  @spec token() :: Ecto.UUID.t()
  def token, do: Ecto.UUID.generate()

  @spec max_delivery_attempts() :: pos_integer()
  def max_delivery_attempts, do: positive_config(:max_delivery_attempts, 5)

  @spec max_reconcile_attempts() :: pos_integer()
  def max_reconcile_attempts, do: positive_config(:max_reconcile_attempts, 3)

  @spec reconcile_delay_seconds() :: pos_integer()
  def reconcile_delay_seconds, do: positive_config(:reconcile_delay_seconds, 5)

  @spec timeline_batch_size() :: pos_integer()
  def timeline_batch_size, do: positive_config(:timeline_batch_size, 25)

  @spec history_window(DateTime.t()) :: {String.t(), String.t()}
  def history_window(%DateTime{} = ambiguous_since) do
    seconds = positive_config(:history_window_seconds, 300)

    {
      ambiguous_since |> DateTime.add(-seconds, :second) |> slack_timestamp(),
      ambiguous_since |> DateTime.add(seconds, :second) |> slack_timestamp()
    }
  end

  @spec error_class(term()) :: String.t()
  def error_class({:slack_http, status}) when is_integer(status) and status >= 500,
    do: "unavailable"

  def error_class({:transport, _detail}), do: "transport"

  def error_class({:slack_rejected, status, _detail}) when status in [401, 403],
    do: "auth"

  def error_class({:slack_rejected, 409, _detail}), do: "conflict"
  def error_class({class, _detail}) when is_atom(class), do: finite_error_class(class)
  def error_class(class) when is_atom(class), do: finite_error_class(class)
  def error_class(_reason), do: "provider"

  defp lease_seconds, do: positive_config(:delivery_lease_seconds, 15)

  defp positive_config(key, default) do
    case Application.get_env(:alert_router, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp slack_timestamp(datetime) do
    microseconds = DateTime.to_unix(datetime, :microsecond)
    seconds = div(microseconds, 1_000_000)
    fraction = microseconds |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
    "#{seconds}.#{fraction}"
  end

  defp finite_error_class(class)
       when class in [
              :auth,
              :conflict,
              :history_incomplete,
              :history_negative,
              :lease_lost,
              :multiple_matches,
              :provider,
              :rate_limited,
              :retry_exhausted,
              :schema,
              :timeout,
              :transport,
              :unavailable
            ],
       do: Atom.to_string(class)

  defp finite_error_class(_class), do: "provider"
end
