package main

import (
	"os"

	"github.com/AFK-surf/comma/systems/cli/bft/internal/commands"
)

func main() {
	os.Exit(commands.Run(os.Args[1:], os.Stdout, os.Stderr, os.Getenv))
}
