defmodule SalixMedia.TestImage do
  @moduledoc false

  # 64x64 FFmpeg test patterns.
  def small_tiff do
    Base.decode64!(
      "SUkqAA4KAACAEqBEpuqaBwSDQOCweClGHFEtPCHxB4JGLJEbCKLxiNReMxuPx4RNKSNIIJKSyaUSWTym" <>
        "WyxJCmZCl4G6ZzSbTOazedzqczKamqhGplN6h0SjUOi0el0pvKqoKpTBCo1KqVGp1Ws1gIQxTB6wB5Lo" <>
        "mw2KyWGxiC1CA7py12xODC5DA3Gm53S7XO63e93o0kDAEAyITA4LCYHB4XE4hCBbHBZOHzH5DJY/I5PL" <>
        "5bK47IibPCZJJfP6DRZ/Q6PT6ZLjbWDZEmTW67Ya3X7Ha7QyV6y2Pd2ewWMccEcGlFW+23y83K+8rk3j" <>
        "kYrD4DF9Lo4boZjN5TsdvNdjUaXPanw+DSd/bbPWbf0+jZefdWjfJI/pdJfUPE1Z/UcJIhLMfB8SQfCy" <>
        "Sr/wALJIvqSQYCGVb6hgSUGLlBQwD+57GOhDDAEkLBJwSIAglk+oLEkJ5YMcSQLEGRrHklFUEgtEsRRJ" <>
        "E0RxSRrvxw1UctAPZRQSGwlFU+obElILWEkGw6D21pJSVH8gomiLRjm+kEhqYIZSyGQ2Ee4ThkVBJJSv" <>
        "MMrh1MwdDOPgbzWG40jvMhgueSQgEkJhRznOc7OhODrs1OE4Owu5CDnOFBDnB8Hi6TRJNAEwyFY784PO" <>
        "88/ysYLzyieEpyq+srhkSVPigVBJP2HAnlNStOmCHRJVYJxPEkG9YieTk4S1LY2Qy6k90tOk6TtFEUDT" <>
        "WFLUBYNhwVBVFUKudB0NQ1I0tIkiC/IckWrVMxUvJBJWrTNN1tLUuS84lszLM80zZNs30tW42DYuZJDC" <>
        "PwYhiSQYjKP1eVVPrOD5cxg0DZtCUtZ8JDgQ0JBhhFDUk3FKWLaTcW+z8qBYSQWBYMNYU/CBav2+r+wC" <>
        "/8BwBkkEVYSQglhWWQlfMQahqLxC3deEFBhed73rfNbj0M4ZkkGYZjbf86ZUWURvrGLHxVGsbWDGcHvq" <>
        "JJXZvheE4HRGr6thms5vhFuSKVUiPrIMkNZJVpySPewygh8pYqS+M4yOBJ3dLrhOJAofDKQ29jKQMzzR" <>
        "NU2TdmOYjWOOaruN40Xreo6jRnuf6EGY/jNw4akIMrzu5f3PMpgy5WdrPS9HQ+B0nh/VvXTG3ng4y3LW" <>
        "tu73IRW/79AvAcFdPCjvzPE8WufG8eGPI8nyvLcxw/NvOu5GjSFXpBUSA29AzN/dEGHSdP7VB9V1vWPb" <>
        "ifX9j83Z9ktS29xv/A3Rwk18Nw/g3FeHh8dx/jy1n3k8vzLzTcPPei9N6oJIDAkEoHE3YdjvGqe86h7r" <>
        "qXxHqfG+E9amXzvqfSXCDJcDkO8fgut4Din6uMfw5ByT+3KNCf88xzkAS5vQem9QNsB4EQKLQHYDEOwM" <>
        "CbD1DyHof0dnlR0ap8EFYkQUNfBh9EHS2xOLiX45ByIRvCLk8R/MKUsv8crC1mMAD1wChnAWA8CYFxAh" <>
        "9GgP4G42AbEyIQ3sQzQxHiUeyOsTINRQihFOKUfTmR8ivCd40WgZRchY8uL8L4wwxgG9KMkBozQ5jRD+" <>
        "Hgm41xtjeb0EMmwQiVEfDYSglI6R2lI64hxEY9RNlVBqQBzo/SuOYrowzyIuyIc1Io2UYoCQ1jLDg38O" <>
        "pKyUh3JaNsbo4Hwk5J2T8ZRKGjEiJiGwixMSjlMRSVMeZVwelecuWE3S6yyOmdYxj/5cGvl1I6XkkJfF" <>
        "imBMOYUQZiyZmRJyT0oJmmfmfNETAI5+AjEMJkEVAQRCBE1NWVE2Yn0Ig2cebZzZuUPL+heiSu6JmGYE" <>
        "XKGUu5QTrEvO2Hs75iSYmOb8RMyZ6zMmdNCA80p+z+oBQKgkyQ+CbjxByhUe6GytohOA6s4afGNO7UFf" <>
        "1G4zzBjVPGkZZqTTLkhPcz0+aVz7n7P+gVAxNUypo+Wm9W5WU5q9LGitP6ePXOy9g7RmpJ1HpFJqelTI" <>
        "EVOBNVCA1LKp0voDTGTlM1M17dfXyU5EnXkgI6RYkNhLBkcsES4lZJCX2MsWSqxRPCfk4slZUn1kimDe" <>
        "b2OQSJXgrWfCsNYXYYrSBiGeNANNqQ0jDG+GS1wZBXDiC/bML4mRzBbtwFsQg6bQBWDeO2vxFLgkRuGP" <>
        "AP1xw/CAEBci5Ny7kXKuZcqxJMLFXVuoTCyxQLJk9u0EQJIewmi/CaIgOwVQ6CfBwH4RQhRDCaDwHsRY" <>
        "fg7ilEcIQRAaw7irE4I8RQnBAiFB4IYSwfQ1CdDgGkQgew1CxFpa+2FsraW2tzbq3loLf3FwxX1190bn" <>
        "XHuhc/Dtzbp2OutiS69jrs2UsuT4KgVQlhlF8E0Tgcgcg7FkEURIcxMCBEyHUTghw2CJEwHIOobg/iDF" <>
        "cKMRAlA2CDE8H8Nwcg5CVFaKDIwcBAisFRg62NtLa23tzbu3uF8NV/wzmbDeIMOZrxBiOyGJ834mxRiu" <>
        "7WKSahfCSI8MYqwghKEMFkLWNw6hxDYIoWYrTQhzESJIMweg86KFUJoQQmQ9iYEcF0TYeQ+CKEuHATwn" <>
        "hQCpEABYrQEMvYSzDhWz+ZM0atuFmXV9f82YexDh/WmbrG5x11rkk+drt6/DODsNgPBghPDcGYNIahUA" <>
        "+EEJEP4jBKhsEQHAO4chYinEmIIRYlBFhXE4JxuoiAoBrEuHwR4nQ+6fFCKQyWpd3FczHcDWFxN52A1c" <>
        "RHWdzd83SJFiXXdj9eExzpirOpPgng+CaFgZIVAghBCSIHYoiL2B/E0HcS4cg8CIE/jwPAhZPBgEMIEQ" <>
        "wjxLBvESHkTgbBPCBE6KgUwqRIAT3eVArfNCr82zPrHnW9NZZq59rTDmuOAdD39r3gd3OCE4CqFoPwKs" <>
        "YiGCgH0JYqggCVDeJwsYVEm6SEmGgOwlxHCREeF8QwgBFiREoGkQ4hBDB0FAIQT4phTCoEfzIrnMyral" <>
        "5zzzne9iKb71r4HoXReiXY6Pr+yQnRLhIEII8FwXAwBXDOLQIwhQ+B2DxpENYkhDiSEwHMQolg+BzE8I" <>
        "AOYhg9CKFIIsOoehNiHh8KQUAo+NgV7xzXvJXO99+757243P99fA35YbwnxfDcF+R0kmoQw/g3C5eINw" <>
        "SAgCTFgEQTYfBLBr8+GsSAchJCjEWJcPImw3iXDiIcNofhDimEgIAN4hw55VE6KETwqhA6k7v/nm3et6" <>
        "+7UysFAAJFAC+Izg4C8I19AQ8OszAWKdAYKEKK9u5u9y/290/7As3uIrAFA0sNAGI4+Mzk3/AS+S6RBI" <>
        "DdAcKRBOKbAeKe/1AnBc9wKm/9AuIpA6sKsRA3A9AK8LBA6NBG8Q8OsxAbCFBXBTBZApCPBfAlBjBm98" <>
        "uLBqsPBtCiJHB1A+JVBE+VB+u1CLC2KdAjC8K4ICCAAIAAgASAAAAAEAAABIAAAAAQAAAExhdmM2MS4x" <>
        "OS4xMDEADwAAAAEAAADrAAAAAQAAAIAAAAABAAAA8AAAAAEAAACAAAAAAQAAAPAAAAABAAAAEAD+AAQA" <>
        "AQAAAAAAAAAAAQQAAQAAAEAAAAABAQQAAQAAAEAAAAACAQMAAwAAALoJAAADAQMAAQAAAAUAAAAGAQMA" <>
        "AQAAAAYAAAARAQQAAQAAAAgAAAAVAQMAAQAAAAMAAAAWAQQAAQAAAEAAAAAXAQQAAQAAALIJAAAaAQUA" <>
        "AQAAAMAJAAAbAQUAAQAAAMgJAAAoAQMAAQAAAAIAAAAxAQIADgAAANAJAAASAgMAAgAAAAIAAgAUAgUA" <>
        "BgAAAN4JAAAAAAAA"
    )
  end

  def small_avif do
    Base.decode64!(
      "AAAAIGZ0eXBhdmlmAAAAAGF2aWZtaWYxbWlhZk1BMUIAAAD5bWV0YQAAAAAAAAAvaGRscgAAAAAAAAAA" <>
        "cGljdAAAAAAAAAAAAAAAAFBpY3R1cmVIYW5kbGVyAAAAAA5waXRtAAAAAAABAAAAHmlsb2MAAAAARAAA" <>
        "AQABAAAAAQAAASEAAAHUAAAAKGlpbmYAAAAAAAEAAAAaaW5mZQIAAAAAAQAAYXYwMUNvbG9yAAAAAGpp" <>
        "cHJwAAAAS2lwY28AAAAUaXNwZQAAAAAAAABAAAAAQAAAABBwaXhpAAAAAAMICAgAAAAMYXYxQ4EADAAA" <>
        "AAATY29scm5jbHgAAgACAAIAAAAAF2lwbWEAAAAAAAAAAQABBAECgwQAAAHcbWRhdAoGGBV//bAIMskD" <>
        "RoABiDERQOeBAN2oKqdSdTlDWVcwh0bEFYmK08fJPP3uqb5ncGQFBVOjEC1LzvbDT9Jz8MqDrvPsDucI" <>
        "1ilb7b3KnNfFCH6d1xOHVd1iyKoBb/L0b9p5+E5m5ZM28oKLqWPcgZkJF4cnhCLOkeS3KM0MYPTUedzg" <>
        "DLjmFxks9vc3OQWTC+V+tVaPMlIbndv94Q2/PV5rLGxgRzL0/Y6lIgw2du0Jie5kT/Nb9tCLlUKAF4pc" <>
        "qC+L6LhuGHAhGYTN1lWQY0RmDRQDabxBMRO9iEy+9CFFtnbq2yi6R5FJcCtG13B6lUHBoHUk3X+DnzQ3" <>
        "etcxhuMzt7cTeVDILo4VM8T4W1qm1pqZXVJwx3nSdfAxEomE7fxGQLLZBYlHq2U1T32UmvHe6AfRtVaW" <>
        "3h/JEwKMBJwpSR7jSy/tkmgmbwd5xUi6eDKM7Ye8ps7VPzGgMk1I3GWuvz7nVhhRx2HeDGC4yEBLE0zY" <>
        "QULW3OyBB62s68eSsdXMi59HBCcd37t7VucTMJgsnp/YchYtf1ijt+Z/l4Wo5ZRXGlyWJzV90xbmcMdJ" <>
        "bOR7OIyvkRSEewIJk1TAX2B19VoIBcxZ0es0hPOKxI1Zpp2uUA=="
    )
  end

  def small_bmp do
    pixels = :binary.copy(<<32, 100, 180, 0>>, 16)
    size = 54 + byte_size(pixels)

    <<"BM", size::little-32, 0::32, 54::little-32, 40::little-32, 4::little-32, 4::little-32,
      1::little-16, 32::little-16, 0::32, byte_size(pixels)::little-32, 0::64, 0::64>> <> pixels
  end

  # A 256x256 gradient that macOS `sips` encoded.
  def small_heic do
    Base.decode64!(
      "AAAAJGZ0eXBoZWljAAAAAG1pZjFNaVBybWlhZk1pSEJoZWljAAABg21ldGEAAAAAAAAAIWhkbHIAAAAA" <>
        "AAAAAHBpY3QAAAAAAAAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAA" <>
        "DnBpdG0AAAAAAAEAAAAjaWluZgAAAAAAAQAAABVpbmZlAgAAAAABAABodmMxAAAAAONpcHJwAAAAwmlw" <>
        "Y28AAAATY29scm5jbHgAAgACAAaAAAAADGNsbGkAywBAAAAAFGlzcGUAAAAAAAABAAAAAQAAAAAJaXJv" <>
        "dAAAAAAQcGl4aQAAAAADCAgIAAAAbmh2Y0MBA3AAAACwAAAAAAA88AD8/fj4AAALA6AAAQAXQAEMAf//" <>
        "A3AAAAMAsAAAAwAAAwA8cCShAAEAIUIBAQNwAAADALAAAAMAAAMAPKAICAQFiHuRZVNwICBgCKIAAQAI" <>
        "RAHAaLIRFNkAAAAZaXBtYQAAAAAAAAABAAEGgQIDBYaEAAAAHmlsb2MAAAAARAAAAQABAAAAAQAAAbcA" <>
        "AAHbAAAAAW1kYXQAAAAAAAAB6wAAAdcoAa+IPRcN2jVozueVf8JVcJMwITb8JbxIm/EmzE6RKR2hYQE/" <>
        "r4ekXsz1ieWKw/dROd2z1bOq14IkDZ3AxDKBAtnUMJDynySwYxGKrzoQDIHJQTwFSmv/H1JFlgiS9HhT" <>
        "Kw97FgRhx4qblqC1IRCFVTPJFYymXkI0vjO0tHOrRX2YA7T/j257hT3LvlGQSvx9BLmt/EBUMPiY9/gi" <>
        "Hs2s5Y+HV4PfZDH5G6JOr93x3Krwi3mzc2UWfk/bTLMDlW16dIv+UP3iJ3cfzDeRCAbTBsvXQlvZvDtl" <>
        "Wz811tbFcx0JqHCZ5HNmbbrwzvGJigoGFf7bURO3tkZ8vbYzpcgEBwMYAGPMjXQlmg76n7IwzL8+2z5M" <>
        "ZwuZXkQ23QWVRbz6n4JSYWnS6ZzXVKyfhodtCTnqMxxv4BqAC8S7JLr7PMEU4XCya4DiTyE41UHJg4Nm" <>
        "otDdsDFBZvUc80YSdai15cfYfjr03JXFixsYGWAeescE1/z7/0nHHMI6PC7peaMRmmMORH+uswOSOQ3z" <>
        "seqsYL0Cm0h85E91k0yCjvgbKX3EANzP+4MlGG0XpwjQ0i/VGhAhmSZ2O4aRFIs2zoqtf3lAjEW52YmP" <>
        "z9PsoXqls3bdiPk4Lcg="
    )
  end

  # A real, deliberately uncompressed PNG, bigger than the old 3 MiB request
  # frame once base64 encoded. No private incident attachment is checked in.
  def large_png do
    width = 1800
    height = 800
    pixels = :binary.copy(<<0>> <> :binary.copy(<<32, 100, 180>>, width), height)
    z = :zlib.open()

    compressed =
      try do
        :ok = :zlib.deflateInit(z, 0)
        :zlib.deflate(z, pixels, :finish) |> IO.iodata_to_binary()
      after
        :zlib.close(z)
      end

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk("IHDR", <<width::32, height::32, 8, 2, 0, 0, 0>>) <>
      chunk("IDAT", compressed) <> chunk("IEND", "")
  end

  defp chunk(type, bytes),
    do: <<byte_size(bytes)::32>> <> type <> bytes <> <<:erlang.crc32(type <> bytes)::32>>
end
