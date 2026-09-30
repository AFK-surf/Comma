package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/AFK-surf/comma/systems/runtime-images/internal/bundlemanifest"
	"github.com/AFK-surf/comma/systems/runtime-images/internal/runtimeinputs"
)

type imageFlags map[string]string

func (f imageFlags) String() string { return fmt.Sprint(map[string]string(f)) }

func (f imageFlags) Set(value string) error {
	class, path, ok := strings.Cut(value, "=")
	if !ok || class == "" || path == "" {
		return fmt.Errorf("image must be class=path, got %q", value)
	}
	if _, exists := f[class]; exists {
		return fmt.Errorf("duplicate image class %q", class)
	}
	f[class] = path
	return nil
}

func main() {
	var revision string
	var output string
	var inputsPath string
	images := imageFlags{}
	flag.StringVar(&revision, "revision", "", "Comma Server source revision (provenance only)")
	flag.StringVar(&inputsPath, "inputs", "", "per-class runtime input digest manifest")
	flag.StringVar(&output, "output", "", "output manifest path")
	flag.Var(images, "image", "OCI archive as class=path (repeat for shell, external, meeting)")
	flag.Parse()

	if output == "" || inputsPath == "" {
		fatalf("output path and inputs path are required")
	}
	data, err := os.ReadFile(inputsPath)
	if err != nil {
		fatalf("read runtime input digests: %v", err)
	}
	var inputs runtimeinputs.Manifest
	if err := json.Unmarshal(data, &inputs); err != nil || inputs.SchemaVersion != 1 {
		fatalf("decode runtime input digests: invalid schema")
	}
	inputDigests := make(map[string]string, len(inputs.Images))
	for _, image := range inputs.Images {
		if _, exists := inputDigests[image.Class]; exists {
			fatalf("duplicate runtime input class %q", image.Class)
		}
		inputDigests[image.Class] = image.InputDigest
	}
	manifest, err := bundlemanifest.Generate(revision, inputDigests, images)
	if err != nil {
		fatalf("generate bundle manifest: %v", err)
	}
	if err := bundlemanifest.Write(output, manifest); err != nil {
		fatalf("write bundle manifest: %v", err)
	}
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
