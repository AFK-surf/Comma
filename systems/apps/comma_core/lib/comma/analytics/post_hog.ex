defmodule Comma.Analytics.PostHog do
  @moduledoc false

  def send_batch(events) do
    config = Comma.Analytics.config()

    ProductAnalytics.PostHog.send_batch(
      events,
      config[:api_key],
      config[:host],
      [:comma_product, :analytics, :batch]
    )
  end
end
