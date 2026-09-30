package accountproxy

import (
	"encoding/binary"
	"encoding/json"
	"github.com/cloudflare/circl/hpke"
	"testing"
)

func TestSubscriptionSealingBindsRecipientAndWorkload(t *testing.T) {
	public, private, err := hpke.KEM_P256_HKDF_SHA256.Scheme().GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := public.MarshalBinary()
	fields := []string{"comma.subscription.v1", "tenant", "project", "workload", "instance", "1", "epoch", "pi", "nonce"}
	access := json.RawMessage(`{"access_token":"synthetic-access","delivery_revision":1}`)
	body, _ := json.Marshal(map[string]any{"public_key": encoded, "context": fields, "access": access})
	var response []byte
	if err := sealSubscription(body, func(data []byte) error { response = append(response, data...); return nil }); err != nil {
		t.Fatal(err)
	}
	var envelope struct {
		Enc        []byte `json:"enc"`
		Ciphertext []byte `json:"ciphertext"`
	}
	if json.Unmarshal(response, &envelope) != nil {
		t.Fatal("invalid envelope")
	}
	var aad []byte
	for _, field := range fields {
		aad = binary.BigEndian.AppendUint32(aad, uint32(len(field)))
		aad = append(aad, field...)
	}
	receiver, _ := hpke.NewSuite(hpke.KEM_P256_HKDF_SHA256, hpke.KDF_HKDF_SHA256, hpke.AEAD_AES128GCM).NewReceiver(private, []byte("comma.runtime-auth.input.v1"))
	opener, err := receiver.Setup(envelope.Enc)
	if err != nil {
		t.Fatal(err)
	}
	plaintext, err := opener.Open(envelope.Ciphertext, aad)
	if err != nil || string(plaintext) != string(access) {
		t.Fatal("recipient cannot recover access")
	}
	opener, _ = receiver.Setup(envelope.Enc)
	aad[len(aad)-1] ^= 1
	if _, err = opener.Open(envelope.Ciphertext, aad); err == nil {
		t.Fatal("accepted different workload context")
	}
}
