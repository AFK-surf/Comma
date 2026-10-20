# Direct clock calls that existed before `mix systems.clock_calls`. Remove
# entries as code moves to SystemsClock; never add one by hand.
%{
  "SalixStore.Ids" => ["System.system_time/1"],
  "SalixStore.ULID" => ["System.system_time/1"]
}
