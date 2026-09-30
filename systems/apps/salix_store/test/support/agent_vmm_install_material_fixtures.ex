defmodule SalixStore.AgentVMMInstallMaterialFixtures do
  @moduledoc false

  @trust_bundle """
  -----BEGIN CERTIFICATE-----
  MIICtDCCAZwCCQDbuGZMfWmt7DANBgkqhkiG9w0BAQsFADAcMRowGAYDVQQDDBFB
  Z2VudCBWTU0gVGVzdCBDQTAeFw0yNjA4MjQxMzA1NTJaFw0zNjA4MjExMzA1NTJa
  MBwxGjAYBgNVBAMMEUFnZW50IFZNTSBUZXN0IENBMIIBIjANBgkqhkiG9w0BAQEF
  AAOCAQ8AMIIBCgKCAQEArO5Y8Bo7Wlt20PvZ7TuZjeM8nrWsY9YHlvVDg/oCdqNS
  vFohh4z9xx2iOLQvoH619JeF+cfZMq0uapi4AntNduXOAj+EnPNGlcv6Wt8FUqW1
  T0DE9IVYRPWclAH+eG+kq5e8+OVzKoVyQdyYRGSASUTD2EfDK+X6IbyqrW8kwBUK
  kGHEvUbre4m7YXMib/eikkgRUyxr3YgHDNTIT40HgamgiUeTfz+qb/zNqvXU7aNt
  O0IMvWSbi04u7fYsR8CpNSGdY6kzeEjc1HgjwZAIZkZSH8Oe5NLEZ2rAP0Dgd9da
  o9TSxcid5InbKKiiCM9QEgR8HKMZnHsuSTWnrytuIQIDAQABMA0GCSqGSIb3DQEB
  CwUAA4IBAQBUdxK9c05izuEeBFjoI7f13bV6QJHFoYJD4xZV/nC80/wpTMoy1itU
  /VW96bnvRYm7TEokz0d6Ssj7pZm7KTDorzX7MDpG63hfmmbmMP2QYWVYI4OpK9Gz
  3VhxSIxueQvGLHhjx2Nd0hmydMqaQH6TXg4xoawQ+ngDj17VbfrVnaJpxBT9Ofk0
  dOwS6GxB/FRm1sH9jgPgm4HGAb6RBkVTYgMDNtmpsGs8KCf+eEV+t0MmzIekknY0
  oWrS31NAt9478vVIQ8gtt5dIAbz22IwwajBCa7VoCRRuX4Wo6ceYPmydDy7jONfg
  zReAW5cvWXKHijQxmv03NQHcitn7M11h
  -----END CERTIFICATE-----
  """

  def catalog do
    %{
      "remote_enrollment" => %{
        "gateway_endpoint" => "vmm.example.test:7443",
        "trust_bundle" => Base.encode64(@trust_bundle)
      }
    }
  end
end
