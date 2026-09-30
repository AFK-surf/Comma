package main

import (
	"context"
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

func (c *connector) computeSubscriptionSync(ctx context.Context, request message, session computeRuntimeSession, carrier *runtimeTransport) (map[string]any, error) {
	current := func() bool {
		return ctx.Err() == nil && carrier != nil && c.getActiveTransport() == carrier && c.computeRuntimeTargetMatches(mapParam(request.Params, "target"), session)
	}
	if request.ID == "" || len(request.Params) != 1 || !computeExternalRuntimeProvider(c.cfg.computeRuntimeProvider) || !current() {
		return nil, errSubscriptionUnavailable
	}
	params, err := c.computeRuntimeAuthParams(request.Params, session)
	if err != nil {
		return nil, errSubscriptionUnavailable
	}
	target, err := c.runtimeCredentialTarget(params, "provider", "identity_material")
	if err != nil {
		return nil, errSubscriptionUnavailable
	}
	access, err := c.subscriptionAccessRequest(ctx, carrier, target.identityMaterial, "", true)
	if err != nil || !current() {
		return nil, errSubscriptionUnavailable
	}
	if access["bound"] == false {
		return nil, errSubscriptionUnavailable
	}
	if _, err = c.applySubscriptionDelivery(ctx, target, access, current); err != nil {
		return nil, errSubscriptionUnavailable
	}
	return map[string]any{"delivery_revision": access["delivery_revision"], "revoked": access["revoked"] == true}, nil
}
