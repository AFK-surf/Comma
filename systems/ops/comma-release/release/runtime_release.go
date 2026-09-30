package release

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"
)

// PublishRuntimeRelease publishes desired images after durable core success.
// The Job uses the successful release's immutable image. Workload convergence
// continues independently and never rolls back the core release.
func (p KubectlPlatform) PublishRuntimeRelease(ctx context.Context, state State) error {
	if state.Phase != PhaseSucceeded || state.Helm.ServingRevision <= 0 {
		return errors.New("Runtime publication requires successful core rollout")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	// Publication is idempotent. A new Job lets a later invocation retry a
	// failed executor without deleting its diagnostic logs.
	spec := JobSpec{
		Name:  runtimeReleaseJobName(state.ReleaseID, time.Now().UnixNano()),
		Stage: "runtime-target", Image: state.Image, BundleName: state.BundleName,
		Fence: state.ReleaseID, RuntimeRelease: &state,
	}
	if _, err := p.ensureJob(ctx, spec); err != nil {
		return fmt.Errorf("core succeeded; Runtime target publication failed; retry publish-runtime-release: %w", err)
	}
	return nil
}

func runtimeReleaseJobName(releaseID string, nonce int64) string {
	return fmt.Sprintf("comma-release-%s-runtime-target-%s", sanitize(releaseID), strconv.FormatInt(nonce, 36))
}
