package main

import (
	"context"
	"errors"
	"strconv"
)

// The authenticated live carrier supplies product scope; current connection
// identity and indexed runtime inventory independently bind the local target.
// No user-supplied path or credential source is selected here.
func (c *connector) connectedPrivateRuntimeAuth(ctx context.Context, session *connectionSession, method string, params map[string]any) (map[string]any, error) {
	if err := c.acquireRuntimeAuth(ctx); err != nil {
		return nil, err
	}
	defer func() { <-c.runtimeAuthSlots }()
	wire := mapParam(params, "target")
	allowed := map[string]bool{}
	for _, key := range []string{"actor_id", "tenant_id", "project_id", "device_id", "runtime_id", "provider", "identity_material", "runtime_instance_id", "generation", "connection_epoch"} {
		allowed[key] = true
	}
	if len(wire) != len(allowed) {
		return nil, errRuntimeAuthInputInvalid
	}
	for key := range wire {
		if !allowed[key] {
			return nil, errRuntimeAuthInputInvalid
		}
	}
	for _, key := range []string{"actor_id", "tenant_id", "project_id", "device_id", "runtime_id", "runtime_instance_id", "connection_epoch"} {
		if value := stringParam(wire, key); value == "" || len(value) > 256 {
			return nil, errRuntimeAuthInputInvalid
		}
	}
	c.connectionMu.Lock()
	valid := session != nil && c.activeConnection == session && session.ctx.Err() == nil &&
		c.deviceID == stringParam(wire, "device_id") && c.connectorRunID == stringParam(wire, "runtime_instance_id") &&
		c.connectionGeneration == int64Param(wire, "generation", 0) && c.connectionGeneration > 0 &&
		strconv.FormatInt(c.connectionGeneration, 10) == stringParam(wire, "connection_epoch")
	c.connectionMu.Unlock()
	if !valid {
		return nil, errors.New("runtime auth target changed")
	}
	provider := stringParam(wire, "provider")
	if !computeExternalRuntimeProvider(provider) {
		return nil, errRuntimeAuthInputInvalid
	}
	target, present := c.runtimeInventory.target(provider, stringParam(wire, "identity_material"))
	if !present {
		return nil, errors.New("runtime auth target changed")
	}
	binding := runtimeAuthInputContext{
		ActorID: stringParam(wire, "actor_id"), TenantID: stringParam(wire, "tenant_id"), ProjectID: stringParam(wire, "project_id"),
		TargetKind: "connected_runtime", DeviceID: stringParam(wire, "device_id"), RuntimeID: stringParam(wire, "runtime_id"),
		RuntimeInstanceID: stringParam(wire, "runtime_instance_id"), Generation: strconv.FormatInt(int64Param(wire, "generation", 0), 10),
		ConnectionEpoch: stringParam(wire, "connection_epoch"), Provider: provider,
	}
	return c.privateRuntimeAuth(ctx, message{Method: method, Params: params}, target, binding, &runtimeAuthPrivateTarget{carrier: c.getActiveTransport(), connection: session})
}

// Same ordering as request admission: connection -> lifecycle -> transport.
// The target section is already held. Closing/replacing the connection cannot
// cross an admitted native rename. Compute uses its existing transport fence.
func (c *connector) commitPrivateRuntimeAuth(ctx context.Context, local *runtimeAuthPrivateTarget, scope runtimeAuthInputContext, commit func() runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
	if local.connection != nil {
		c.connectionMu.Lock()
		defer c.connectionMu.Unlock()
		local.connection.lifecycleMu.Lock()
		defer local.connection.lifecycleMu.Unlock()
		if c.activeConnection != local.connection || local.connection.closed ||
			c.deviceID != scope.DeviceID || c.connectorRunID != scope.RuntimeInstanceID ||
			strconv.FormatInt(c.connectionGeneration, 10) != scope.Generation {
			return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "target_changed"}
		}
	}
	return c.commitRuntimeAuthTransport(ctx, local.carrier, commit)
}

func (c *connector) privateRuntimeAuthCurrent(ctx context.Context, local *runtimeAuthPrivateTarget, scope runtimeAuthInputContext) bool {
	if ctx.Err() != nil || local == nil || local.carrier == nil {
		return false
	}
	c.connectionMu.Lock()
	defer c.connectionMu.Unlock()
	if local.connection != nil && (local.connection.ctx.Err() != nil || c.activeConnection != local.connection || c.deviceID != scope.DeviceID || c.connectorRunID != scope.RuntimeInstanceID || strconv.FormatInt(c.connectionGeneration, 10) != scope.Generation) {
		return false
	}
	return c.getActiveTransport() == local.carrier
}
