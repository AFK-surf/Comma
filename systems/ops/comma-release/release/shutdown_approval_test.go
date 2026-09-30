package release

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"testing"
	"time"
)

type approvalRunner struct {
	issue          map[string]any
	comments       []map[string]any
	permission     string
	creates, reads int
	fail           bool
	closed         bool
	changed        bool
	appended       bool
}

func (r *approvalRunner) Run(_ context.Context, input []byte, args ...string) ([]byte, error) {
	if r.fail {
		return nil, fmt.Errorf("unavailable")
	}
	path := args[len(args)-1]
	if strings.HasSuffix(path, "/issues") {
		r.creates++
		if err := json.Unmarshal(input, &r.issue); err != nil {
			return nil, err
		}
		r.issue["state"] = "open"
		return json.Marshal(map[string]any{"number": 1, "created_at": time.Now().Add(-time.Hour)})
	}
	r.reads++
	switch {
	case strings.HasSuffix(path, "/issues/1"):
		if r.closed {
			r.issue["state"] = "closed"
		}
		if r.appended {
			r.issue["body"] = r.issue["body"].(string) + "\nDifferent shutdown scope"
		}
		if r.changed {
			r.issue["body"] = "changed candidate"
		}
		return json.Marshal(r.issue)
	case strings.HasSuffix(path, "/comments?per_page=100"):
		return json.Marshal(r.comments)
	case strings.HasSuffix(path, "/collaborators/human/permission"):
		return json.Marshal(map[string]string{"permission": r.permission})
	default:
		return nil, fmt.Errorf("unexpected API %s", path)
	}
}
func approvalComment(body, kind string) map[string]any {
	now := time.Now().Add(-time.Minute).UTC()
	return map[string]any{"id": 2, "body": body, "issue_url": "https://api.github.com/repos/org/repo/issues/1", "created_at": now, "updated_at": now, "user": map[string]string{"login": "human", "type": kind}}
}
func TestShutdownApprovalExecutionBoundary(t *testing.T) {
	for _, tc := range []string{"approved after wait", "bot", "wrong issue", "changed scope", "appended scope", "edited", "closed", "read only", "api failure", "comment limit", "timeout"} {
		t.Run(tc, func(t *testing.T) {
			ctx := context.Background()
			store := &memoryStore{}
			platform := &fakePlatform{plan: testPlan(t, ModeExclusive)}
			engine := Engine{Store: store, Platform: platform}
			if _, err := engine.Prepare(ctx, "staging", "r1", "image", []byte("bundle")); err != nil {
				t.Fatal(err)
			}
			runner := &approvalRunner{permission: "write", comments: []map[string]any{approvalComment("LGTM!", "User")}}
			switch tc {
			case "approved after wait", "timeout":
				runner.comments = nil
			case "bot":
				runner.comments[0] = approvalComment("yes", "Bot")
			case "wrong issue":
				runner.comments[0]["issue_url"] = "https://api.github.com/repos/org/repo/issues/3"
			case "appended scope":
				runner.appended = true
			case "changed scope":
				runner.changed = true
			case "edited":
				runner.comments[0]["updated_at"] = time.Now()
			case "closed":
				runner.closed = true
			case "read only":
				runner.permission = "read"
			case "api failure":
				runner.fail = true
			case "comment limit":
				runner.comments = make([]map[string]any, 100)
			}
			waits := 0
			notifications := 0
			approval := GitHubShutdownApproval{Repository: "org/repo", Runner: runner, Output: io.Discard, NotifyIssue: func(_ context.Context, url string) error {
				notifications++
				if url != "https://github.com/org/repo/issues/1" {
					t.Errorf("wrong issue notification: %s", url)
				}
				return fmt.Errorf("Slack unavailable")
			}, wait: func(context.Context, time.Duration) error {
				waits++
				if platform.quiesced {
					t.Fatal("shutdown before human reply")
				}
				if tc == "approved after wait" {
					runner.comments = []map[string]any{approvalComment("OK!", "User")}
					return nil
				}
				if tc == "timeout" {
					return nil
				}
				return context.Canceled
			}}
			engine.AuthorizeShutdown = approval.Authorize
			_, err := engine.Migrate(ctx)
			if tc == "approved after wait" {
				if err != nil || !platform.quiesced || waits != 1 {
					t.Fatalf("approval did not resume: %v waits=%d", err, waits)
				}
			} else {
				if err == nil || platform.quiesced {
					t.Fatalf("invalid approval allowed shutdown: %v", err)
				}
				for _, job := range platform.jobs {
					if job.Stage != "plan" {
						t.Fatalf("migration before approval: %s", job.Stage)
					}
				}
			}
			if !runner.fail && notifications != 1 {
				t.Fatalf("sent %d notifications", notifications)
			}
			if !runner.fail && runner.creates != 1 {
				t.Fatalf("created %d issues", runner.creates)
			}
			if runner.reads > 181 || waits > 40 {
				t.Fatal("unbounded approval wait")
			}
			if tc == "timeout" && waits != 40 {
				t.Fatal("timeout budget not exercised")
			}
		})
	}
}
func TestShutdownAssentRequiresWholeAffirmativeReply(t *testing.T) {
	for _, body := range []string{"yes", " OK! ", "LGTM.", "go ahead", "同意！", "approved"} {
		if !shutdownAssent(body) {
			t.Errorf("rejected %q", body)
		}
	}
	for _, body := range []string{"not ok", "yes but wait", "ok?", "> yes", "looks good except for data loss", "", "do not approve"} {
		if shutdownAssent(body) {
			t.Errorf("accepted %q", body)
		}
	}
}
func TestOnlineReleaseDoesNotCreateApprovalIssue(t *testing.T) {
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline)}
	runner := &approvalRunner{fail: true}
	engine := Engine{Store: store, Platform: platform, AuthorizeShutdown: GitHubShutdownApproval{Repository: "org/repo", Runner: runner}.Authorize}
	if _, err := engine.Prepare(context.Background(), "staging", "r1", "image", []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	if _, err := engine.Migrate(context.Background()); err != nil {
		t.Fatal(err)
	}
	if runner.creates != 0 || platform.quiesced {
		t.Fatal("online release requested shutdown")
	}
}

func TestShutdownApprovalMissingAuthorityFailsClosed(t *testing.T) {
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeExclusive)}
	engine := Engine{Store: store, Platform: platform}
	if _, err := engine.Prepare(context.Background(), "staging", "r1", "image", []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	if _, err := engine.Migrate(context.Background()); err == nil || platform.quiesced {
		t.Fatal("missing authority allowed shutdown")
	}
}

func TestShutdownApprovalHardCutCannotBypassOnlinePlan(t *testing.T) {
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline)}
	engine := Engine{Store: store, Platform: platform, RequireLifecycleWriterEpoch: true}
	if _, err := engine.Prepare(context.Background(), "staging", "r1", "image", []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	if _, err := engine.Migrate(context.Background()); err == nil || platform.quiesced {
		t.Fatal("hard cut bypassed human approval")
	}
	if store.record.State.LifecycleWriterEpoch.Status != "" {
		t.Fatal("writer epoch acquired before approval")
	}
}

func TestNewAttemptPreservesForwardOnlyCutover(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeExclusive), fail: "cutover"}
	engine := Engine{Store: store, Platform: platform, AuthorizeShutdown: func(context.Context, State) error { return nil }}
	if _, err := engine.Prepare(ctx, "staging", "r1", "image", []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	if _, err := engine.Migrate(ctx); err == nil {
		t.Fatal("expected cutover failure")
	}
	recovered, err := engine.Recover(ctx, "r1")
	if err != nil || recovered.Phase != PhaseForwardOnly {
		t.Fatalf("recover: %v", err)
	}
	before := string(Encode(store.record.State))
	for _, id := range []string{"r1", "r2"} {
		if _, err := engine.Prepare(ctx, "staging", id, "image", []byte("bundle")); err == nil {
			t.Fatal("ordinary prepare replaced forward repair")
		}
		if string(Encode(store.record.State)) != before {
			t.Fatal("forward cutover facts changed")
		}
	}
	engine.AuthorizeShutdown = nil // Existing cutover recovery must preserve data without a fresh approval.
	if _, err := engine.ResumeForward(ctx, "r1", PhaseCutover, true); err != nil {
		t.Fatal(err)
	}
	platform.fail = ""
	if _, err := engine.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
}
