defmodule SalixIM.Provider.Slack.RichCard do
  @moduledoc """
  Slack adapter for provider-neutral map, stock, and weather surfaces.

  `SalixIM.MessageRenderer.Surface` carries normalized semantic data to the
  selected provider renderer. This module validates the Slack adapter's data
  and turns it into Block Kit plus safe fallback text.
  """

  @types ~w(map stock weather)
  @card_body_limit 200
  @max_points 20
  @labels %{
    en: %{
      map: "Map",
      open_map: "View map",
      map_of: "Map of",
      stock: "Stock",
      change_unavailable: "Change unavailable",
      open: "Open",
      high: "High",
      low: "Low",
      volume: "Volume",
      source: "Source",
      market_data: "Market data",
      price_trend: "Price trend",
      weather: "Weather",
      feels_like: "Feels like",
      humidity: "Humidity",
      precipitation: "Precipitation",
      wind: "Wind",
      full_forecast: "Full forecast",
      weather_data: "Weather data",
      forecast: "Forecast",
      hourly: "Hourly",
      today: "Today"
    },
    zh_cn: %{
      map: "地图",
      open_map: "在地图中查看",
      map_of: "地图",
      stock: "股票",
      change_unavailable: "暂无涨跌数据",
      open: "开盘",
      high: "最高",
      low: "最低",
      volume: "成交量",
      source: "数据来源",
      market_data: "行情数据",
      price_trend: "价格走势",
      weather: "天气",
      feels_like: "体感",
      humidity: "湿度",
      precipitation: "降水",
      wind: "风力",
      full_forecast: "完整预报",
      weather_data: "天气数据",
      forecast: "未来天气",
      hourly: "逐小时",
      today: "今日"
    }
  }

  @spec render(String.t(), map()) ::
          {:ok, %{text: String.t(), blocks: [map()]}} | {:error, String.t()}
  def render(type, params) when type in @types and is_map(params) do
    try do
      {:ok, apply(__MODULE__, String.to_existing_atom("render_#{type}"), [params])}
    rescue
      error in ArgumentError -> {:error, truncate(error.message, 240)}
    end
  end

  def render(_type, _params), do: {:error, "unsupported Slack rich card type"}

  def render_map(params) do
    locale = locale(params)
    location = required_string(params, "location")
    latitude = required_number(params, "latitude", min: -90, max: 90)
    longitude = required_number(params, "longitude", min: -180, max: 180)
    address = optional_string(params, "address")
    note = optional_string(params, "note")
    map_url = optional_url(params, "map_url") || google_maps_url(latitude, longitude)
    image_url = optional_url(params, "image_url")
    coordinates = "#{format_number(latitude)}, #{format_number(longitude)}"

    subtitle = address || coordinates

    body = map_body(note, map_url, locale)

    block =
      %{
        "type" => "card",
        "title" => mrkdwn(escape(location), 150),
        "subtitle" => plain_text(subtitle, 150),
        "body" => mrkdwn(body, @card_body_limit)
      }
      |> maybe_put("subtext", if(address, do: plain_text(coordinates, 200)))
      |> maybe_put(
        "hero_image",
        image_element(image_url, "#{label(locale, :map_of)} #{location}")
      )

    %{
      text: escape("#{fallback_prefix(locale, :map)}#{location} — #{coordinates}"),
      blocks: [block]
    }
  end

  def render_stock(params) do
    locale = locale(params)
    symbol = required_string(params, "symbol") |> String.upcase()
    price = required_number(params, "price", min: 0)
    currency = currency(params)
    company = optional_string(params, "company_name")
    change = optional_number(params, "change")
    change_percent = optional_number(params, "change_percent", min: -100, max: 100)
    open = optional_number(params, "open", min: 0)
    high = optional_number(params, "high", min: 0)
    low = optional_number(params, "low", min: 0)
    volume = optional_number(params, "volume", min: 0)
    history = points(params, "price_history", "label", "value")
    exchange = optional_string(params, "exchange")
    period = optional_string(params, "period")
    as_of = optional_string(params, "as_of")
    market_status = optional_string(params, "market_status")
    source_url = optional_url(params, "source_url")

    change_line =
      [display_signed_money(change, currency), display_percent(change_percent)]
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> label(locale, :change_unavailable)
        values -> Enum.join(values, " · ")
      end

    title = if company, do: "#{company} · #{symbol}", else: symbol

    metrics =
      [
        metric_field(label(locale, :open), display_money(open, currency)),
        metric_field(label(locale, :high), display_money(high, currency)),
        metric_field(label(locale, :low), display_money(low, currency)),
        metric_field(label(locale, :volume), compact_quantity(volume))
      ]
      |> Enum.reject(&is_nil/1)

    source =
      if source_url,
        do: "<#{slack_url(source_url)}|#{label(locale, :source)}>",
        else: nil

    timing = [market_status, as_of] |> Enum.reject(&is_nil/1) |> Enum.map_join(" · ", &escape/1)

    footer =
      [if(timing == "", do: label(locale, :market_data), else: timing), source]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    children = [section("*#{escape(display_money(price, currency))}*\n#{escape(change_line)}")]

    children =
      if history == [] do
        children
      else
        children ++ [section(stock_trend(locale, history))]
      end

    children = if metrics == [], do: children, else: children ++ [section_fields(metrics)]
    children = children ++ [context(footer)]

    subtitle =
      [exchange, currency, period]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    container =
      %{
        "type" => "container",
        "width" => "narrow",
        "title" => plain_text(title, 150),
        "child_blocks" => children,
        "has_header_divider" => true
      }
      |> maybe_put("subtitle", if(subtitle == "", do: nil, else: plain_text(subtitle, 150)))

    %{
      text:
        escape(
          "#{fallback_prefix(locale, :stock)}#{symbol} #{display_money(price, currency)}; #{change_line}"
        ),
      blocks: [container]
    }
  end

  def render_weather(params) do
    locale = locale(params)
    location = required_string(params, "location")
    condition = required_string(params, "condition")
    temperature = required_number(params, "temperature")
    unit = enum(params, "unit", ~w(C F))
    feels_like = optional_number(params, "feels_like")
    high = optional_number(params, "high")
    low = optional_number(params, "low")
    precipitation = optional_number(params, "precipitation_percent", min: 0, max: 100)
    humidity = optional_number(params, "humidity_percent", min: 0, max: 100)
    wind = optional_string(params, "wind")
    hourly = points(params, "hourly_forecast", "time", "temperature")
    daily = daily_forecast(params)
    as_of = optional_string(params, "as_of")
    forecast_url = optional_url(params, "forecast_url")
    degree = "°#{unit}"

    details =
      [
        metric_field(label(locale, :feels_like), temperature(feels_like, degree)),
        metric_field(label(locale, :humidity), percentage(humidity)),
        metric_field(label(locale, :precipitation), percentage(precipitation)),
        metric_field(label(locale, :wind), wind)
      ]
      |> Enum.reject(&is_nil/1)

    footer =
      [
        if(as_of, do: escape(as_of)),
        if(forecast_url,
          do: "<#{slack_url(forecast_url)}|#{label(locale, :full_forecast)}>"
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")
      |> case do
        "" -> label(locale, :weather_data)
        value -> value
      end

    current =
      %{
        "type" => "section",
        "text" => mrkdwn("*#{display_number(temperature)}#{degree}*", 3_000)
      }
      |> maybe_put("fields", if(details == [], do: nil, else: details))

    children = [current]

    children =
      if hourly == [] do
        children
      else
        children ++ [section(weather_trend(locale, hourly))]
      end

    children =
      if daily == [] do
        children
      else
        children ++
          [
            %{"type" => "divider"},
            %{
              "type" => "section",
              "text" => mrkdwn("*#{label(locale, :forecast)}*", 3_000),
              "fields" => Enum.map(Enum.take(daily, 6), &daily_field(&1, locale, unit))
            }
          ]
      end

    children = children ++ [context(footer)]

    range = weather_range(locale, high, low, degree)

    subtitle =
      [condition, range]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    container = %{
      "type" => "container",
      "width" => "standard",
      "title" => plain_text("#{weather_icon(condition)} #{location}", 150),
      "subtitle" => plain_text(subtitle, 150),
      "child_blocks" => children,
      "has_header_divider" => true
    }

    %{
      text:
        escape(
          "#{fallback_prefix(locale, :weather)}#{location} #{display_number(temperature)}#{degree}, #{condition}"
        ),
      blocks: [container]
    }
  end

  defp section(text),
    do: %{"type" => "section", "text" => mrkdwn(text, 3_000)}

  defp section_fields(fields),
    do: %{"type" => "section", "fields" => fields}

  defp context(text),
    do: %{"type" => "context", "elements" => [mrkdwn(text, 2_000)]}

  defp map_body(note, map_url, locale) do
    link = "<#{slack_url(map_url)}|#{label(locale, :open_map)}>"

    if String.length(link) > @card_body_limit do
      raise ArgumentError, "map_url is too long for Slack card body"
    end

    note =
      case note do
        nil ->
          nil

        value ->
          note_limit = @card_body_limit - String.length(link) - 1
          if note_limit > 0, do: value |> escape() |> truncate(note_limit)
      end

    [note, link]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp plain_text(text, max),
    do: %{"type" => "plain_text", "text" => text |> to_string() |> truncate(max), "emoji" => true}

  defp mrkdwn(text, max),
    do: %{"type" => "mrkdwn", "text" => truncate(text, max), "verbatim" => true}

  defp image_element(nil, _alt_text), do: nil

  defp image_element(url, alt_text),
    do: %{"type" => "image", "image_url" => url, "alt_text" => truncate(alt_text, 2_000)}

  defp metric_field(_label, nil), do: nil

  defp metric_field(label, value),
    do: mrkdwn("*#{escape(label)}*\n#{escape(value)}", 2_000)

  defp stock_trend(locale, history) do
    first = List.first(history)
    last = List.last(history)

    "*#{label(locale, :price_trend)}*\n#{escape(first.label)}  `#{sparkline(history)}`  #{escape(last.label)}"
  end

  defp weather_trend(locale, hourly) do
    first = List.first(hourly)
    last = List.last(hourly)

    "*#{label(locale, :hourly)}*\n#{escape(first.label)}  `#{sparkline(hourly)}`  #{escape(last.label)}"
  end

  defp sparkline(points) do
    glyphs = String.graphemes("▁▂▃▄▅▆▇█")
    values = Enum.map(points, & &1.value)
    minimum = Enum.min(values)
    maximum = Enum.max(values)

    if maximum == minimum do
      String.duplicate(Enum.at(glyphs, 3), length(values))
    else
      Enum.map_join(values, fn value ->
        index = round((value - minimum) / (maximum - minimum) * (length(glyphs) - 1))
        Enum.at(glyphs, min(index, length(glyphs) - 1))
      end)
    end
  end

  defp daily_field(day, _locale, unit) do
    mrkdwn(
      "*#{escape(day.day)} · #{weather_icon(day.condition)} #{escape(day.condition)}*\n" <>
        "#{display_number(day.high)}° / #{display_number(day.low)}°#{unit}",
      2_000
    )
  end

  defp weather_range(locale, high, low, degree) when not is_nil(high) and not is_nil(low),
    do: "#{label(locale, :today)} #{display_number(low)}°–#{display_number(high)}#{degree}"

  defp weather_range(_locale, high, nil, degree) when not is_nil(high),
    do: "↑ #{display_number(high)}#{degree}"

  defp weather_range(_locale, nil, low, degree) when not is_nil(low),
    do: "↓ #{display_number(low)}#{degree}"

  defp weather_range(_locale, nil, nil, _degree), do: nil

  defp weather_icon(condition) do
    normalized = String.downcase(condition)

    cond do
      contains_any?(normalized, ["雷", "thunder", "lightning"]) -> "⛈️"
      contains_any?(normalized, ["雪", "冰", "snow", "sleet"]) -> "🌨️"
      contains_any?(normalized, ["雨", "rain", "shower", "drizzle"]) -> "🌧️"
      contains_any?(normalized, ["雾", "霾", "fog", "mist", "haze"]) -> "🌫️"
      contains_any?(normalized, ["多云", "晴间", "partly", "mostly cloudy"]) -> "🌤️"
      contains_any?(normalized, ["晴", "sun", "clear"]) -> "☀️"
      contains_any?(normalized, ["云", "阴", "cloud", "overcast"]) -> "☁️"
      contains_any?(normalized, ["风", "台风", "wind", "typhoon", "hurricane"]) -> "💨"
      true -> "🌡️"
    end
  end

  defp contains_any?(value, tokens), do: Enum.any?(tokens, &String.contains?(value, &1))

  defp temperature(nil, _degree), do: nil
  defp temperature(value, degree), do: "#{display_number(value)}#{degree}"

  defp percentage(nil), do: nil
  defp percentage(value), do: "#{display_number(value)}%"

  defp display_money(nil, _currency), do: nil

  defp display_money(number, currency),
    do: currency_prefix(currency) <> fixed_number(number, 2)

  defp display_signed_money(nil, _currency), do: nil

  defp display_signed_money(number, currency) do
    sign = if number >= 0, do: "+", else: "−"
    sign <> display_money(abs(number), currency)
  end

  defp currency_prefix("USD"), do: "US$"
  defp currency_prefix("CNY"), do: "¥"
  defp currency_prefix("HKD"), do: "HK$"
  defp currency_prefix("JPY"), do: "¥"
  defp currency_prefix("EUR"), do: "€"
  defp currency_prefix("GBP"), do: "£"
  defp currency_prefix(currency), do: currency <> " "

  defp compact_quantity(nil), do: nil

  defp compact_quantity(number) when number >= 1_000_000_000,
    do: compact_unit(number, 1_000_000_000, "B")

  defp compact_quantity(number) when number >= 1_000_000,
    do: compact_unit(number, 1_000_000, "M")

  defp compact_quantity(number) when number >= 1_000,
    do: compact_unit(number, 1_000, "K")

  defp compact_quantity(number), do: display_number(number)

  defp compact_unit(number, divisor, suffix) do
    number
    |> Kernel./(divisor)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing(".0")
    |> Kernel.<>(suffix)
  end

  defp fixed_number(number, decimals) do
    [whole, fraction] =
      number
      |> :erlang.float_to_binary(decimals: decimals)
      |> String.split(".", parts: 2)

    delimit_integer(whole) <> "." <> fraction
  end

  defp delimit_integer(integer) do
    integer
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&(&1 |> Enum.reverse() |> Enum.join()))
    |> Enum.reverse()
    |> Enum.join(",")
  end

  defp locale(params) do
    case optional_string(params, "locale") do
      nil ->
        :en

      value ->
        case value |> String.replace("_", "-") |> String.downcase() do
          "en" -> :en
          "zh-cn" -> :zh_cn
          _ -> raise ArgumentError, "locale must be one of en, zh-CN"
        end
    end
  end

  defp label(locale, key), do: get_in(@labels, [locale, key])

  defp fallback_prefix(:zh_cn, key), do: label(:zh_cn, key) <> "："
  defp fallback_prefix(:en, key), do: label(:en, key) <> ": "

  defp required_string(params, key) do
    case optional_string(params, key) do
      nil -> raise ArgumentError, "#{key} is required"
      value -> value
    end
  end

  defp optional_string(params, key) do
    case Map.get(params, key) do
      nil ->
        nil

      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: truncate(value, 1_000)

      _ ->
        raise ArgumentError, "#{key} must be a string"
    end
  end

  defp enum(params, key, values) do
    value = required_string(params, key) |> String.upcase()

    if value in values,
      do: value,
      else: raise(ArgumentError, "#{key} must be one of #{Enum.join(values, ", ")}")
  end

  defp currency(params) do
    value = required_string(params, "currency") |> String.upcase()

    if Regex.match?(~r/^[A-Z]{3}$/, value),
      do: value,
      else: raise(ArgumentError, "currency must be a 3-letter ISO code")
  end

  defp required_number(params, key, opts \\ []) do
    case optional_number(params, key, opts) do
      nil -> raise ArgumentError, "#{key} is required"
      value -> value
    end
  end

  defp optional_number(params, key, opts \\ []) do
    case Map.get(params, key) do
      nil -> nil
      value -> validate_number(parse_number(value, key), key, opts)
    end
  end

  defp parse_number(value, _key) when is_integer(value) or is_float(value), do: value * 1.0

  defp parse_number(value, key) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> raise ArgumentError, "#{key} must be a number"
    end
  end

  defp parse_number(_value, key), do: raise(ArgumentError, "#{key} must be a number")

  defp validate_number(number, key, opts) do
    min = Keyword.get(opts, :min)
    max = Keyword.get(opts, :max)

    cond do
      min != nil and number < min ->
        raise ArgumentError, "#{key} must be between #{min} and #{max || "infinity"}"

      max != nil and number > max ->
        raise ArgumentError, "#{key} must be between #{min || "-infinity"} and #{max}"

      true ->
        number
    end
  end

  defp points(params, key, label_key, value_key) do
    case Map.get(params, key) do
      nil ->
        []

      values when is_list(values) and length(values) in 1..@max_points ->
        Enum.map(values, fn
          value when is_map(value) ->
            label = required_string(value, label_key) |> truncate(20)
            number = required_number(value, value_key)
            %{label: label, value: number}

          _ ->
            raise ArgumentError, "#{key} entries must be objects"
        end)

      values when is_list(values) ->
        raise ArgumentError, "#{key} must contain 1 to #{@max_points} entries"

      _ ->
        raise ArgumentError, "#{key} must be an array"
    end
  end

  defp daily_forecast(params) do
    case Map.get(params, "daily_forecast") do
      nil ->
        []

      values when is_list(values) and length(values) in 1..10 ->
        Enum.map(values, fn
          value when is_map(value) ->
            day = required_string(value, "day")
            condition = required_string(value, "condition")
            high = required_number(value, "high")
            low = required_number(value, "low")

            %{day: day, condition: condition, high: high, low: low}

          _ ->
            raise ArgumentError, "daily_forecast entries must be objects"
        end)

      values when is_list(values) ->
        raise ArgumentError, "daily_forecast must contain 1 to 10 entries"

      _ ->
        raise ArgumentError, "daily_forecast must be an array"
    end
  end

  defp optional_url(params, key) do
    case optional_string(params, key) do
      nil ->
        nil

      value ->
        case URI.parse(value) do
          %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> value
          _ -> raise ArgumentError, "#{key} must be an https URL"
        end
    end
  end

  defp google_maps_url(latitude, longitude) do
    query = URI.encode_www_form("#{format_number(latitude)},#{format_number(longitude)}")
    "https://www.google.com/maps/search/?api=1&query=#{query}"
  end

  defp display_number(number), do: format_number(number)
  defp display_percent(nil), do: nil
  defp display_percent(number) when number > 0, do: "+#{format_number(number)}%"
  defp display_percent(number), do: "#{format_number(number)}%"

  defp format_number(number),
    do:
      number
      |> :erlang.float_to_binary(decimals: 6)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")

  defp slack_url(url), do: String.replace(url, ["<", ">", "|"], "")

  defp escape(value),
    do:
      value
      |> to_string()
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp truncate(value, max), do: String.slice(value, 0, max)
end
