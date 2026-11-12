namespace UnsafeFixtures

@[export recursion_fixture_unsafe]
unsafe def entry (items : List UInt8) : List UInt8 := unsafeCast items

end UnsafeFixtures
