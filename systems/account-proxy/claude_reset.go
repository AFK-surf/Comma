package accountproxy

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"slices"
	"time"

	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
)

// A Claude subscription's limit resets, as Claude Code's /limit-reset reads
// and uses them. The usage endpoint lists them only to Claude Code's own CLI
// of a version that has them (its User-Agent), in two programs:
//   - juniper_tide: a 5-hour limit reset once a week, there only at the
//     5-hour limit; used with {program} alone;
//   - cedar_ember: resets granted to the account (Fable's launch, say), each
//     grant some resets until a date, usable now or once at a limit; used with
//     {program, grant_id, request_id}, the request id making a retry after a
//     lost reply harmless.
//
// Both are used at POST /api/organizations/<organization>/reset_rate_limits,
// the organization as /api/oauth/profile says. Salix lists them by kind
// (systems/profiles quota.rs claude_resets) and a person picks the kind.

// The usage read that also says the resets (no spend, which is not read).
const claudeUsagePath = "/api/oauth/usage?at_wall=1&skip_spend=1"

var (
	claudeVersion      = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)
	claudeOrganization = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)
	claudeResetKinds   = []string{"session", "weekly", "model", "full"}
)

// Claude Code's own headers for its OAuth endpoints. The executor adds the token.
func setClaudeHeaders(req *http.Request, version string) {
	req.Header.Set("anthropic-beta", "oauth-2025-04-20")
	if claudeVersion.MatchString(version) {
		req.Header.Set("User-Agent", "claude-cli/"+version+" (external, cli)")
	}
}

type claudeGrant struct {
	ID              string   `json:"id"`
	Type            string   `json:"type"`
	Clears          []string `json:"clears"`
	GivesBackWeekly bool     `json:"gives_back_weekly"`
	ResetsLeft      int      `json:"resets_left"`
	Paused          bool     `json:"paused"`
	UsableNow       bool     `json:"usable_now"`
	EndsAt          string   `json:"ends_at"`
}

type claudeUsage struct {
	Tide *struct {
		Eligible  bool   `json:"eligible"`
		Arm       string `json:"arm"`
		Available bool   `json:"available"`
	} `json:"juniper_tide"`
	Ember *struct {
		Eligible    bool          `json:"eligible"`
		NextGrantID string        `json:"next_grant_id"`
		Grants      []claudeGrant `json:"grants"`
	} `json:"cedar_ember"`
}

// A grant's kind, as systems/profiles quota.rs claude_grant_kind names it.
func claudeGrantKind(g claudeGrant) string {
	if g.GivesBackWeekly || g.Type == "fable" {
		return "model"
	}
	if g.Type == "session" || g.Type == "weekly" || g.Type == "full" {
		return g.Type
	}
	session := slices.Contains(g.Clears, "five_hour")
	other := slices.ContainsFunc(g.Clears, func(c string) bool { return c != "five_hour" })
	switch {
	case session && !other:
		return "session"
	case other && !session:
		return "weekly"
	default:
		return "full"
	}
}

func claudeEnds(g claudeGrant) time.Time {
	t, err := time.Parse(time.RFC3339, g.EndsAt)
	if err != nil {
		return time.Unix(1<<40, 0)
	}
	return t
}

// The claim the usage answer allows now for a reset of `kind` (empty: any,
// the weekly 5-hour reset first): the weekly 5-hour reset for the 5-hour kind
// when it is there, else of that kind's usable grants the one the provider
// names next, else the one that ends first. No claim: "nothing_to_reset" when
// resets of the kind are held that cannot be used now, "no_credit" when none are.
func claudeClaim(u claudeUsage, key, kind string) (map[string]string, string) {
	if (kind == "" || kind == "session") && u.Tide != nil && u.Tide.Eligible && u.Tide.Arm == "reset" && u.Tide.Available {
		return map[string]string{"program": "juniper_tide"}, ""
	}
	var held, usable []claudeGrant
	if u.Ember != nil && u.Ember.Eligible {
		for _, g := range u.Ember.Grants {
			if g.ID == "" || g.ResetsLeft <= 0 || g.Paused || (kind != "" && claudeGrantKind(g) != kind) {
				continue
			}
			held = append(held, g)
			if g.UsableNow {
				usable = append(usable, g)
			}
		}
	}
	slices.SortStableFunc(usable, func(a, b claudeGrant) int { return claudeEnds(a).Compare(claudeEnds(b)) })
	if len(usable) > 0 {
		grant := usable[0]
		if i := slices.IndexFunc(usable, func(g claudeGrant) bool { return g.ID == u.Ember.NextGrantID }); i >= 0 {
			grant = usable[i]
		}
		// Claude Code's request id is [A-Za-z0-9_-]{1,64}: Salix's key made to fit, the same on each retry.
		sum := sha256.Sum256([]byte(key))
		return map[string]string{"program": "cedar_ember", "grant_id": grant.ID, "request_id": hex.EncodeToString(sum[:])}, ""
	}
	if len(held) > 0 || ((kind == "" || kind == "session") && u.Tide != nil && u.Tide.Eligible) {
		return nil, "nothing_to_reset"
	}
	return nil, "no_credit"
}

// Uses one of a Claude account's resets of `kind`. The outcomes are Codex's
// words, and "unavailable" when Claude refuses one for now (cooldown,
// ineligible, rate limited).
func claudeReset(ctx context.Context, e auth.ProviderExecutor, a *auth.Auth, version, key, kind string) (resetResult, error) {
	ask := func(method, path string, body any, out any) (int, error) {
		var reader io.Reader
		if body != nil {
			data, _ := json.Marshal(body)
			reader = bytes.NewReader(data)
		}
		req, err := http.NewRequestWithContext(ctx, method, "https://api.anthropic.com"+path, reader)
		if err != nil {
			return 0, err
		}
		setClaudeHeaders(req, version)
		req.Header.Set("Accept", "application/json")
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		resp, err := e.HttpRequest(ctx, a, req)
		if err != nil {
			return 0, err
		}
		defer resp.Body.Close()
		data, err := io.ReadAll(io.LimitReader(resp.Body, 1024*1024+1))
		if err != nil || len(data) > 1024*1024 {
			return resp.StatusCode, fmt.Errorf("invalid Claude response")
		}
		if resp.StatusCode == http.StatusOK && json.Unmarshal(data, out) != nil {
			return resp.StatusCode, fmt.Errorf("invalid Claude response")
		}
		return resp.StatusCode, nil
	}
	var usage claudeUsage
	if status, err := ask("GET", claudeUsagePath, nil, &usage); err != nil || status != http.StatusOK {
		return resetResult{}, fmt.Errorf("claude usage HTTP %d: %v", status, err)
	}
	claim, none := claudeClaim(usage, key, kind)
	if claim == nil {
		return resetResult{Code: none}, nil
	}
	var profile struct {
		Organization struct {
			UUID string `json:"uuid"`
		} `json:"organization"`
	}
	if status, err := ask("GET", "/api/oauth/profile", nil, &profile); err != nil || status != http.StatusOK || !claudeOrganization.MatchString(profile.Organization.UUID) {
		return resetResult{}, fmt.Errorf("claude profile HTTP %d: %v", status, err)
	}
	var answer struct {
		Result string `json:"result"`
	}
	status, err := ask("POST", "/api/organizations/"+profile.Organization.UUID+"/reset_rate_limits", claim, &answer)
	if err != nil {
		return resetResult{}, err
	}
	if status == http.StatusTooManyRequests {
		return resetResult{Code: "unavailable"}, nil
	}
	if status != http.StatusOK {
		return resetResult{}, fmt.Errorf("claude reset HTTP %d", status)
	}
	switch answer.Result {
	case "reset":
		return resetResult{Code: "reset"}, nil
	case "already_used":
		return resetResult{Code: "already_redeemed"}, nil
	case "not_limited":
		return resetResult{Code: "nothing_to_reset"}, nil
	case "cooldown", "ineligible":
		return resetResult{Code: "unavailable"}, nil
	default:
		return resetResult{}, fmt.Errorf("unknown Claude reset outcome")
	}
}

// The usage answer with the account's plan beside it, as `plan`: Claude's
// usage endpoint does not say it, its OAuth profile does (organization_type,
// rate_limit_tier). Without a profile answer the usage answer stays as it is.
func withClaudePlan(ctx context.Context, e auth.ProviderExecutor, a *auth.Auth, version string, usage []byte) []byte {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://api.anthropic.com/api/oauth/profile", nil)
	if err != nil {
		return usage
	}
	setClaudeHeaders(req, version)
	resp, err := e.HttpRequest(ctx, a, req)
	if err != nil {
		return usage
	}
	defer resp.Body.Close()
	var profile struct {
		Organization struct {
			Type string `json:"organization_type"`
			Tier string `json:"rate_limit_tier"`
		} `json:"organization"`
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1024*1024))
	if err != nil || resp.StatusCode != http.StatusOK || json.Unmarshal(data, &profile) != nil || profile.Organization.Type == "" {
		return usage
	}
	var body map[string]json.RawMessage
	if json.Unmarshal(usage, &body) != nil || body == nil {
		return usage
	}
	plan, _ := json.Marshal(map[string]string{"organization_type": profile.Organization.Type, "rate_limit_tier": profile.Organization.Tier})
	body["plan"] = plan
	out, err := json.Marshal(body)
	if err != nil {
		return usage
	}
	return out
}
