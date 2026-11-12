module github.com/AFK-surf/Comma/systems/gateway/salix-vmm-gateway

go 1.26.3

require (
	github.com/AFK-surf/agent-vmm v0.0.0
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260706201446-f0a921348800
	google.golang.org/grpc v1.84.0
	google.golang.org/protobuf v1.36.12
)

require (
	golang.org/x/net v0.62.0 // indirect
	golang.org/x/sys v0.49.0 // indirect
	golang.org/x/text v0.43.0 // indirect
)

// Local cross-repository development source. CI checks out agent-vmm at the
// revision of the Host pin (.github/agent-vmm-host.json release_id) and uses
// that checkout; generated wire types are never copied into Comma.
replace github.com/AFK-surf/agent-vmm => ../../../../agent-vmm
