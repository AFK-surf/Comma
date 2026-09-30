package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/AFK-surf/comma/systems/runtime-images/internal/runtimeinputs"
)

func main() {
	var root string
	var output string
	flag.StringVar(&root, "root", "", "Comma repository root")
	flag.StringVar(&output, "output", "", "output input-digest manifest path")
	flag.Parse()

	if root == "" || output == "" {
		fatalf("root and output are required")
	}
	manifest, err := runtimeinputs.Generate(root)
	if err != nil {
		fatalf("generate runtime input digests: %v", err)
	}
	if err := runtimeinputs.Write(output, manifest); err != nil {
		fatalf("write runtime input digests: %v", err)
	}
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
