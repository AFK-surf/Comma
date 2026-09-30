package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/AFK-surf/comma/systems/runtime-images/internal/runtimeinputs"
	"github.com/AFK-surf/comma/systems/runtime-images/internal/runtimereuse"
)

func main() {
	var inputsPath, approvedDir, outputDir string
	flag.StringVar(&inputsPath, "inputs", "", "current runtime input manifest")
	flag.StringVar(&approvedDir, "approved", "", "prior approved mainline bundle directory")
	flag.StringVar(&outputDir, "output", "", "runtime output directory")
	flag.Parse()
	if inputsPath == "" || outputDir == "" {
		fatalf("inputs and output are required")
	}
	data, err := os.ReadFile(inputsPath)
	if err != nil {
		fatalf("read runtime inputs: %v", err)
	}
	var inputs runtimeinputs.Manifest
	if err := json.Unmarshal(data, &inputs); err != nil || inputs.SchemaVersion != 1 {
		fatalf("decode runtime inputs: invalid schema")
	}
	reused, err := runtimereuse.Copy(inputs, approvedDir, outputDir)
	if err != nil {
		fatalf("reuse approved runtime bundle: %v", err)
	}
	if len(reused) > 0 {
		fmt.Printf("reused approved mainline runtime artifacts: %s\n", strings.Join(reused, ","))
	}
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
