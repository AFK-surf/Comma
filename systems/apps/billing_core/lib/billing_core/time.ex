defmodule BillingCore.Time do
  @moduledoc false

  @spec compare(DateTime.t() | nil, DateTime.t() | nil) :: :lt | :eq | :gt
  def compare(nil, nil), do: :eq
  def compare(nil, _right), do: :lt
  def compare(_left, nil), do: :gt
  def compare(left, right), do: DateTime.compare(left, right)

  @spec before_or_equal?(DateTime.t() | nil, DateTime.t() | nil) :: boolean()
  def before_or_equal?(nil, _right), do: true
  def before_or_equal?(_left, nil), do: false
  def before_or_equal?(left, right), do: DateTime.compare(left, right) in [:lt, :eq]

  @spec after?(DateTime.t() | nil, DateTime.t() | nil) :: boolean()
  def after?(_left, nil), do: false
  def after?(nil, _right), do: false
  def after?(left, right), do: DateTime.compare(left, right) == :gt

  @spec add_one_month(DateTime.t()) :: DateTime.t()
  def add_one_month(%DateTime{} = datetime) do
    date = Date.add(datetime |> DateTime.to_date(), 31)

    {:ok, expires_at} =
      DateTime.new(date, DateTime.to_time(datetime), datetime.time_zone, datetime.zone_abbr)

    expires_at
  rescue
    _ -> DateTime.add(datetime, 31 * 24 * 60 * 60, :second)
  end
end
