module github.com/AFK-surf/Comma/systems/gateway/salix-vmm-gateway

go 1.26.3

require (
	github.com/AFK-surf/agent-vmm v0.0.0
	google.golang.org/grpc v1.82.1
	google.golang.org/protobuf v1.36.11
)

require (
	golang.org/x/net v0.56.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	golang.org/x/text v0.40.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260414002931-afd174a4e478 // indirect
)

// Local cross-repository development source. CI resolves agent-vmm main once
// per build and uses that checkout; generated wire types are never copied into Comma.
replace github.com/AFK-surf/agent-vmm => ../../../../agent-vmm
