package accountproxy

import (
	"errors"
	"io"

	"github.com/tidwall/gjson"
)

// A provider's quota answer, bounded and valid JSON; Salix reads it
// (systems/profiles quota.rs).
func readQuotaBody(r io.Reader) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r, 1024*1024+1))
	if err != nil {
		return nil, err
	}
	if len(b) > 1024*1024 || !gjson.ValidBytes(b) {
		return nil, errors.New("invalid quota response")
	}
	return b, nil
}
