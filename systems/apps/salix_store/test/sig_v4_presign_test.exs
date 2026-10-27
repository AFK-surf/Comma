defmodule SalixStore.SigV4PresignTest do
  use ExUnit.Case, async: true

  alias SalixStore.SigV4

  # AWS's published example of a query-string signed GET ("Authenticating
  # Requests: Using Query Parameters", Signature Version 4).
  test "signs a GET as AWS's documented example does" do
    cfg = %SalixStore.Config{
      endpoint: "https://examplebucket.s3.amazonaws.com",
      region: "us-east-1",
      bucket: "examplebucket",
      access_key_id: "AKIAIOSFODNN7EXAMPLE",
      secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      atomic_operations: :s3
    }

    url =
      SigV4.presign(
        "GET",
        "https://examplebucket.s3.amazonaws.com/test.txt",
        cfg,
        86_400,
        {{2013, 5, 24}, {0, 0, 0}}
      )

    assert url ==
             "https://examplebucket.s3.amazonaws.com/test.txt" <>
               "?X-Amz-Algorithm=AWS4-HMAC-SHA256" <>
               "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request" <>
               "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host" <>
               "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
  end
end
