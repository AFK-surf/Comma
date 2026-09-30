package release

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"time"
)

// GitHub owns approval identity and permission. A human token cannot prove who typed a comment.
type GitHubShutdownApproval struct {
	Repository  string
	Runner      Runner
	Output      io.Writer
	NotifyIssue func(context.Context, string) error
	wait        func(context.Context, time.Duration) error
}

const ShutdownApprovalWarning = "HUMAN APPROVAL REQUIRED - AGENTS MUST NOT APPROVE"

func shutdownAssent(body string) bool {
	body = strings.ToLower(strings.Join(strings.Fields(strings.TrimSpace(body)), " "))
	body = strings.TrimRight(body, ".!。！")
	switch body {
	case "yes", "ok", "okay", "lgtm", "approve", "approved", "i approve", "go ahead", "looks good to me", "yes, proceed", "yes, please proceed", "同意", "批准", "可以", "可以发布", "可以部署", "同意发布", "同意部署":
		return true
	}
	return false
}

func (a GitHubShutdownApproval) Authorize(ctx context.Context, s State) error {
	if !regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`).MatchString(a.Repository) {
		return fmt.Errorf("shutdown approval requires GITHUB_REPOSITORY")
	}
	runner := a.Runner
	if runner == nil {
		runner = ExecRunner{Name: "gh"}
	}
	output := a.Output
	if output == nil {
		output = os.Stderr
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	api := func(method, path string, input any, out any) error {
		callCtx, done := context.WithTimeout(ctx, 45*time.Second)
		defer done()
		args := []string{"api", "--hostname", "github.com", "--method", method}
		var body []byte
		if input != nil {
			body = Encode(input)
			args = append(args, "--input", "-")
		}
		args = append(args, "repos/"+a.Repository+path)
		result, err := runner.Run(callCtx, body, args...)
		if err != nil {
			return fmt.Errorf("GitHub shutdown approval API failed (%s %s); no shutdown authorized", method, path)
		}
		return json.Unmarshal(result, out)
	}
	hardCut := s.LifecycleWriterEpoch != nil && s.LifecycleWriterEpoch.Required
	title := ShutdownApprovalWarning + ": staging " + s.ReleaseID
	body := fmt.Sprintf(`%s

Comma requires a deployment-wide shutdown. Agents must not approve or impersonate a human, including through a human token.
A human with repository write permission must manually comment yes, ok, lgtm, approved, go ahead, 同意, or 批准.
Use a standalone approval. Questions, conditional replies, quoted text, and edited comments do not approve.
Closing this issue cancels the wait. This request expires when this execution stops waiting (at most 10 minutes).

## Deployment scope

Environment: %s
Release: %s
Image: %s
Chart: %s
Manifest: %s
Mode: %s
Session lifecycle hard cut: %t
Pending migration IDs: %s

## Human review

Before approval, check the release plan and linked change for the shutdown reason, durable facts, disposable scope,
required backup/restore evidence, downtime budget, and rollback or forward repair.
Temporary failures during rolling updates alone do not justify shutdown.
The staging writer-fenced cutover budget is 10 minutes. Core rollout/convergence is 20 minutes; provider convergence is 30 minutes.
See https://github.com/%s/blob/main/docs/release-operations.md for the authoritative policy and recovery procedure.
`, ShutdownApprovalWarning, s.Environment, s.ReleaseID, s.Image, s.Artifacts.ChartReference, s.ManifestDigest, s.RequiredMode, hardCut, strings.Join(s.InitialPending, ", "), a.Repository)
	var issue struct {
		Number    int
		CreatedAt time.Time `json:"created_at"`
	}
	if err := api("POST", "/issues", map[string]string{"title": title, "body": body}, &issue); err != nil {
		return err
	}
	if issue.Number <= 0 || issue.CreatedAt.IsZero() {
		return fmt.Errorf("GitHub returned no valid shutdown approval issue")
	}
	path := fmt.Sprintf("/issues/%d", issue.Number)
	url := fmt.Sprintf("https://github.com/%s/issues/%d", a.Repository, issue.Number)
	fmt.Fprintf(output, "Waiting up to 10 minutes for human shutdown approval: %s\n", url)
	if a.NotifyIssue != nil {
		if err := a.NotifyIssue(ctx, url); err != nil {
			fmt.Fprintln(output, "Warning: Slack notification failed. Use the GitHub issue link above; approval is still pending.")
		}
	}

	// One issue per invocation, 40 polls, one page of fewer than 100 comments.
	// Each comment can trigger at most one permission lookup over the entire wait.
	checked := map[int64]bool{}
	for poll := 0; poll < 40; poll++ {
		var current struct{ Title, Body, State string }
		if err := api("GET", path, nil, &current); err != nil {
			return err
		}
		if current.State != "open" || current.Title != title || current.Body != body {
			return fmt.Errorf("shutdown approval issue closed or scope changed: %s", url)
		}
		var comments []struct {
			ID        int64
			Body      string
			IssueURL  string    `json:"issue_url"`
			CreatedAt time.Time `json:"created_at"`
			UpdatedAt time.Time `json:"updated_at"`
			User      struct{ Login, Type string }
		}
		if err := api("GET", path+"/comments?per_page=100", nil, &comments); err != nil {
			return err
		}
		if len(comments) >= 100 {
			return fmt.Errorf("shutdown approval comment limit reached: %s; retry deployment", url)
		}
		for _, comment := range comments {
			if checked[comment.ID] || comment.ID <= 0 || comment.User.Type != "User" || !regexp.MustCompile(`^[A-Za-z0-9-]+$`).MatchString(comment.User.Login) || !shutdownAssent(comment.Body) || !comment.CreatedAt.Equal(comment.UpdatedAt) || comment.CreatedAt.Before(issue.CreatedAt) || comment.IssueURL != "https://api.github.com/repos/"+a.Repository+path {
				continue
			}
			if len(checked) >= 100 {
				return fmt.Errorf("shutdown approval permission-check limit reached: %s", url)
			}
			checked[comment.ID] = true
			var permission struct{ Permission string }
			if err := api("GET", "/collaborators/"+comment.User.Login+"/permission", nil, &permission); err != nil {
				return err
			}
			switch permission.Permission {
			case "admin", "maintain", "write":
				fmt.Fprintf(output, "Human shutdown approval by %s: %s#issuecomment-%d\n", comment.User.Login, url, comment.ID)
				return nil
			}
		}
		wait := a.wait
		if wait == nil {
			wait = func(ctx context.Context, d time.Duration) error {
				timer := time.NewTimer(d)
				defer timer.Stop()
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-timer.C:
					return nil
				}
			}
		}
		if err := wait(ctx, 15*time.Second); err != nil {
			return fmt.Errorf("shutdown approval wait ended: %s: %w", url, err)
		}
	}
	return fmt.Errorf("shutdown approval timed out: %s; retry deployment for a new request", url)
}
