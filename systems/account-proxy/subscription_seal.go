package accountproxy

import (
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"github.com/cloudflare/circl/hpke"
)

// Seal access material before it enters the Compute carrier. The authenticated
// Salix owner supplies the exact workload/instance context; HPKE does not grant
// account access or replace the carrier's authorization.
func sealSubscription(body json.RawMessage, emit emitter) error {
	var in struct {
		PublicKey []byte          `json:"public_key"`
		Context   []string        `json:"context"`
		Access    json.RawMessage `json:"access"`
	}
	invalid := &operationError{400, "invalid_subscription_envelope"}
	if json.Unmarshal(body, &in) != nil || len(in.PublicKey) != 65 || len(in.Context) != 9 || len(in.Access) == 0 || len(in.Access) > 64<<10 {
		return invalid
	}
	var aad []byte
	for _, value := range in.Context {
		if len(value) == 0 || len(value) > 512 {
			return invalid
		}
		aad = binary.BigEndian.AppendUint32(aad, uint32(len(value)))
		aad = append(aad, []byte(value)...)
	}
	public, err := hpke.KEM_P256_HKDF_SHA256.Scheme().UnmarshalBinaryPublicKey(in.PublicKey)
	if err != nil {
		return invalid
	}
	sender, err := hpke.NewSuite(hpke.KEM_P256_HKDF_SHA256, hpke.KDF_HKDF_SHA256, hpke.AEAD_AES128GCM).NewSender(public, []byte("comma.runtime-auth.input.v1"))
	if err != nil {
		return invalid
	}
	enc, sealer, err := sender.Setup(rand.Reader)
	if err != nil {
		return invalid
	}
	ciphertext, err := sealer.Seal(in.Access, aad)
	if err != nil {
		return invalid
	}
	payload, err := json.Marshal(map[string]any{"enc": enc, "ciphertext": ciphertext})
	if err != nil {
		return invalid
	}
	return emit(payload)
}
