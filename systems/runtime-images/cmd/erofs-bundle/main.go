package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/AFK-surf/comma/systems/runtime-images/internal/erofsbundle"
)

func main() {
	if len(os.Args) < 2 {
		fatalf("usage: erofs-bundle <flatten-oci|pack|unpack> [flags]")
	}
	switch os.Args[1] {
	case "flatten-oci":
		runFlattenOCI(os.Args[2:])
	case "pack":
		runPack(os.Args[2:])
	case "unpack":
		runUnpack(os.Args[2:])
	default:
		fatalf("unknown subcommand %q (expected flatten-oci, pack, or unpack)", os.Args[1])
	}
}

func runFlattenOCI(args []string) {
	fs := flag.NewFlagSet("flatten-oci", flag.ExitOnError)
	var ociPath, tarOutPath, metaOutPath string
	fs.StringVar(&ociPath, "oci", "", "input .oci.tar path")
	fs.StringVar(&tarOutPath, "tar-out", "-", "output merged tar path ('-' for stdout)")
	fs.StringVar(&metaOutPath, "meta-out", "", "output metadata JSON path")
	_ = fs.Parse(args)

	if ociPath == "" || metaOutPath == "" {
		fatalf("--oci and --meta-out are required")
	}

	var tarOut io.Writer
	var outFile *os.File
	if tarOutPath == "-" {
		tarOut = os.Stdout
	} else {
		var err error
		outFile, err = os.OpenFile(tarOutPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
		if err != nil {
			fatalf("open --tar-out: %v", err)
		}
		tarOut = outFile
	}

	meta, err := erofsbundle.FlattenOCI(ociPath, tarOut)
	if err != nil {
		if outFile != nil {
			_ = outFile.Close()
		}
		fatalf("flatten-oci: %v", err)
	}
	if outFile != nil {
		if err := outFile.Close(); err != nil {
			fatalf("close --tar-out: %v", err)
		}
	}

	metaBytes, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		fatalf("marshal meta: %v", err)
	}
	if err := os.WriteFile(metaOutPath, append(metaBytes, '\n'), 0o644); err != nil {
		fatalf("write --meta-out: %v", err)
	}
}

func runPack(args []string) {
	fs := flag.NewFlagSet("pack", flag.ExitOnError)
	var metaPath, erofsPath, zstdErofsPath, compression, outputPath string
	fs.StringVar(&metaPath, "meta", "", "metadata JSON path from flatten-oci")
	fs.StringVar(&erofsPath, "erofs", "", "4096-byte aligned raw EROFS image path")
	fs.StringVar(&zstdErofsPath, "zstd-erofs", "", "zstd-compressed EROFS payload path")
	fs.StringVar(&compression, "compression", erofsbundle.CompressionZstd, "payload compression (zstd or none)")
	fs.StringVar(&outputPath, "output", "", "output COMMA_EROFS_V1 archive path")
	_ = fs.Parse(args)

	if metaPath == "" || erofsPath == "" || outputPath == "" {
		fatalf("--meta, --erofs, and --output are required")
	}
	if _, err := erofsbundle.Pack(metaPath, erofsPath, zstdErofsPath, compression, outputPath); err != nil {
		fatalf("pack: %v", err)
	}
}

func runUnpack(args []string) {
	fs := flag.NewFlagSet("unpack", flag.ExitOnError)
	var inputPath, erofsOutPath string
	fs.StringVar(&inputPath, "input", "", "input COMMA_EROFS_V1 archive path")
	fs.StringVar(&erofsOutPath, "erofs-out", "", "optional output raw EROFS image path")
	_ = fs.Parse(args)

	if inputPath == "" {
		fatalf("--input is required")
	}
	if _, err := erofsbundle.Unpack(inputPath, erofsOutPath); err != nil {
		fatalf("unpack: %v", err)
	}
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
