// The isolated VMM fixture pairs a Guest ForwardTCP listener with a loopback
// callback listener to carry real Salix
// HTTP/WebSocket traffic over the existing authenticated ForwardTCP stream.
// It adds no Guest egress exception or production transport implementation.
package main

import (
	"io"
	"log"
	"net"
)

func main() {
	reverse, err := net.Listen("tcp", ":18080")
	if err != nil {
		log.Fatal(err)
	}
	local, err := net.Listen("tcp", "127.0.0.1:18081")
	if err != nil {
		log.Fatal(err)
	}
	waiting := make(chan net.Conn, 2)
	go func() {
		for {
			connection, err := reverse.Accept()
			if err != nil {
				return
			}
			waiting <- connection
		}
	}()
	for {
		client, err := local.Accept()
		if err != nil {
			return
		}
		server := <-waiting
		go func() {
			defer client.Close()
			defer server.Close()
			finished := make(chan struct{}, 2)
			go func() { _, _ = io.Copy(server, client); finished <- struct{}{} }()
			go func() { _, _ = io.Copy(client, server); finished <- struct{}{} }()
			<-finished
		}()
	}
}
