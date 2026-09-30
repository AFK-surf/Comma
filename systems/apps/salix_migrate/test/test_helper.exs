# :go_exporter needs go + sqlite3 + bash; opt in with `mix test --include go_exporter`.
ExUnit.start(exclude: [:go_exporter])
