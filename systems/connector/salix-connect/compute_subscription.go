package main

import (
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"strconv"
)

func (c *connector) computeSubscriptionOffer() (*runtimeAuthInputKey, map[string]any, []byte, error) {
	key, public, err := newRuntimeAuthInputKey()
	if err != nil {
		return nil, nil, nil, err
	}
	nonce := make([]byte, 16)
	if _, err = rand.Read(nonce); err != nil {
		key.destroy()
		return nil, nil, nil, err
	}
	challenge := hex.EncodeToString(nonce)
	fields := []string{"comma.subscription.v1", c.cfg.computeRuntimeTenantID, c.cfg.computeRuntimeProjectID, c.cfg.computeRuntimeWorkloadID, c.cfg.computeRuntimeInstanceID, strconv.Itoa(c.cfg.computeRuntimeGeneration), c.cfg.computeRuntimeEpoch, c.cfg.computeRuntimeProvider, challenge}
	var aad []byte
	for _, value := range fields {
		aad = binary.BigEndian.AppendUint32(aad, uint32(len(value)))
		aad = append(aad, []byte(value)...)
	}
	return key, map[string]any{"public_key": public, "nonce": challenge}, aad, nil
}
