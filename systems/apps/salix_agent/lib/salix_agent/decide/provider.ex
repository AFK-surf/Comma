defmodule SalixAgent.Decide.Provider do
  @moduledoc "One Jev-compatible HTTP exchange through Req, without retries or redirects."
  @max_body 64 * 1024

  def request(args, config) do
    body = Map.put(args, "model", config.model)

    timeout =
      if is_integer(config[:deadline]),
        do: max(config.deadline - System.monotonic_time(:millisecond), 1),
        else: 2_000

    case Req.post(config.endpoint,
           headers: [{"authorization", "Bearer " <> config.api_key}],
           json: body,
           retry: false,
           redirect: false,
           decode_body: false,
           receive_timeout: timeout,
           pool_timeout: timeout,
           connect_options: [timeout: timeout],
           into: fn {:data, data}, {req, resp} ->
             content = (resp.body || "") <> data

             if byte_size(content) > @max_body do
               {:halt, {req, %{resp | body: {:too_large, binary_part(content, 0, @max_body)}}}}
             else
               {:cont, {req, %{resp | body: content}}}
             end
           end
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} ->
            case SalixAgent.Decide.decode(
                   decoded,
                   args["questions"],
                   if(config[:profile] == :miniskill, do: @max_body, else: 15 * 1024)
                 ) do
              {:ok, answer, meta} -> {:ok, answer, Map.put(meta, "provider_response", decoded)}
              {:error, code} -> failure(code, decoded)
            end

          _ ->
            failure(:invalid_response, body)
        end

      {:ok, %{body: {:too_large, prefix}}} ->
        failure(:invalid_response, %{body_prefix: prefix, truncated: true})

      {:ok, %{status: 429, body: body}} ->
        failure(:rate_limited, body)

      {:ok, response} ->
        failure(:provider_error, %{status: response.status, body: response.body})

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _} ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp failure(code, response) do
    usage =
      case response do
        %{"usage" => %{"input_tokens" => i, "output_tokens" => o}}
        when is_integer(i) and i >= 0 and is_integer(o) and o >= 0 ->
          %{"prompt_tokens" => i, "completion_tokens" => o}

        _ ->
          %{}
      end

    {:error, %{decide_error: code, provider_response: response, usage: usage}}
  end
end
