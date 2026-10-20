defmodule SalixIM.Multipart do
  @moduledoc """
  A Req plugin for requests with `form_multipart:`. It encodes the body as
  Req does, but draws the boundary through
  `SystemsRuntime.Proc.random_bytes/1`. The boundary only has to be unique
  within the body.

      Req.post(url, form_multipart: fields, plugins: [SalixIM.Multipart])
  """

  @doc false
  def attach(%Req.Request{} = request),
    do: Req.Request.prepend_request_steps(request, salix_multipart: &encode/1)

  defp encode(request) do
    case Req.Request.fetch_option(request, :form_multipart) do
      {:ok, fields} ->
        boundary =
          Base.encode16(SystemsRuntime.Proc.random_bytes(16), padding: false, case: :lower)

        multipart = Req.Utils.encode_form_multipart(fields, boundary: boundary)

        %{request | body: multipart.body}
        |> Req.Request.delete_option(:form_multipart)
        |> Req.Request.put_new_header("content-type", multipart.content_type)
        |> content_length(multipart.size)

      :error ->
        request
    end
  end

  defp content_length(request, nil), do: request

  defp content_length(request, size),
    do: Req.Request.put_new_header(request, "content-length", Integer.to_string(size))
end
