package main

import (
	"strings"
	"unicode"
)

func runtimeAuthCodexToken(value string) bool {
	if value == "" {
		return false
	}
	return strings.IndexFunc(value, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) }) < 0
}
