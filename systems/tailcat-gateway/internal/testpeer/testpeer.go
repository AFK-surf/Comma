// Package testpeer runs a Tailcat server behind a local relay for tests.
package testpeer

import (
	"io"
	"net"
	"sync"

	"github.com/comma/salix-tailcat-gateway/internal/devderp"
	"github.com/tailscale/tailcat"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

// Peer is a running Tailcat server and its relay.
type Peer struct {
	Relay   *devderp.Relay
	Server  *tailcat.Server
	Address tailcat.Addr

	mu      sync.Mutex
	remotes []string
}

// Remotes returns the tunnel address of each accepted connection's client.
// Tailcat derives that address from the client's node key.
func (p *Peer) Remotes() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]string(nil), p.remotes...)
}

// Start serves port on the Tailcat server by forwarding each connection to
// target. A non-empty allow admits only those client keys.
func Start(logf logger.Logf, port uint16, target string, allow ...key.NodePublic) (*Peer, error) {
	return start(logf, port, func(*tailcat.Server) func(net.Conn) {
		return func(c net.Conn) { forward(c, target) }
	}, allow)
}

// StartSSH serves port 22 with tailcat's built-in SSH server, as
// `tailcat serve --ssh-authorized-keys=<keys> ssh` does: a login shell, exec
// and SFTP as the current user, for clients with one of authorizedKeys.
func StartSSH(logf logger.Logf, authorizedKeys []string) (*Peer, error) {
	if err := tailcat.ValidateSSHAuthorizedKeys(authorizedKeys); err != nil {
		return nil, err
	}
	return start(logf, 22, func(s *tailcat.Server) func(net.Conn) {
		return s.SSHConnHandler(tailcat.SSHOptions{Shell: true, AuthorizedKeys: authorizedKeys})
	}, nil)
}

func start(logf logger.Logf, port uint16, handler func(*tailcat.Server) func(net.Conn), allow []key.NodePublic) (*Peer, error) {
	relay, err := devderp.Start(logf)
	if err != nil {
		return nil, err
	}
	peer := &Peer{Relay: relay}
	s := &tailcat.Server{
		Logf:           logf,
		Region:         relay.Region,
		AllowedClients: allow,
	}
	serve := handler(s)
	s.OnTCP = func(p uint16) func(net.Conn) {
		if p != port {
			return nil
		}
		return func(c net.Conn) {
			host, _, _ := net.SplitHostPort(c.RemoteAddr().String())
			peer.mu.Lock()
			peer.remotes = append(peer.remotes, host)
			peer.mu.Unlock()
			serve(c)
		}
	}
	if err := s.Start(); err != nil {
		relay.Close()
		return nil, err
	}
	peer.Server, peer.Address = s, s.TailcatAddr()
	return peer, nil
}

// Close stops the server and the relay.
func (p *Peer) Close() {
	p.Server.Close()
	p.Relay.Close()
}

func forward(c net.Conn, target string) {
	defer c.Close()
	t, err := net.Dial("tcp", target)
	if err != nil {
		return
	}
	defer t.Close()
	done := make(chan struct{}, 2)
	go func() { io.Copy(t, c); done <- struct{}{} }()
	go func() { io.Copy(c, t); done <- struct{}{} }()
	<-done
}
