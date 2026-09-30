package config

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

const DefaultAPIBaseURL = "https://teams.bridge.surf"

var environmentURLs = map[string]string{
	"prod":       DefaultAPIBaseURL,
	"production": DefaultAPIBaseURL,
	"staging":    "https://teams-staging.bridge.surf",
	"stage":      "https://teams-staging.bridge.surf",
	"dev":        "http://127.0.0.1:4101",
	"local":      "http://127.0.0.1:4101",
}

type Env func(string) string

type Config struct {
	APIBaseURL  string   `json:"api_base_url,omitempty"`
	Token       string   `json:"token,omitempty"`
	ExpiresAt   string   `json:"expires_at,omitempty"`
	GrantedOrgs []OrgRef `json:"granted_orgs,omitempty"`
}

type OrgRef struct {
	ID   string `json:"id,omitempty"`
	Slug string `json:"slug,omitempty"`
	Name string `json:"name,omitempty"`
}

type Options struct {
	ConfigPath string
	URL        string
	APIBaseURL string
	EnvName    string
	TokenEnv   string
}

func DefaultPath(env Env) string {
	if path := strings.TrimSpace(env("BFT_CLI_CONFIG")); path != "" {
		return expandHome(path)
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return filepath.Join(".bridge-for-teams", "cli.json")
	}
	return filepath.Join(home, ".bridge-for-teams", "cli.json")
}

func Path(path string, env Env) string {
	if strings.TrimSpace(path) != "" {
		return expandHome(path)
	}
	return DefaultPath(env)
}

func Load(path string, env Env) (Config, error) {
	resolved := Path(path, env)
	body, err := os.ReadFile(resolved)
	if errors.Is(err, os.ErrNotExist) {
		return Config{}, nil
	}
	if err != nil {
		return Config{}, err
	}
	if len(strings.TrimSpace(string(body))) == 0 {
		return Config{}, nil
	}
	var cfg Config
	if err := json.Unmarshal(body, &cfg); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func Persist(path string, env Env, cfg Config) error {
	resolved := Path(path, env)
	if err := os.MkdirAll(filepath.Dir(resolved), 0o700); err != nil {
		return err
	}
	body, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(resolved, append(body, '\n'), 0o600); err != nil {
		return err
	}
	return os.Chmod(resolved, 0o600)
}

func ResolveBaseURL(opts Options, cfg Config, env Env) (string, error) {
	for _, candidate := range []string{opts.URL, opts.APIBaseURL, env("BFT_URL")} {
		if strings.TrimSpace(candidate) != "" {
			return normalizeURL(candidate), nil
		}
	}

	envName := firstNonEmpty(opts.EnvName, env("BFT_ENV"))
	if strings.TrimSpace(envName) != "" {
		normalized := strings.ToLower(strings.TrimSpace(envName))
		if base, ok := environmentURLs[normalized]; ok {
			return base, nil
		}
		return "", UnknownEnvironmentError{Env: envName}
	}

	for _, candidate := range []string{env("BFT_API_BASE_URL"), cfg.APIBaseURL, DefaultAPIBaseURL} {
		if strings.TrimSpace(candidate) != "" {
			return normalizeURL(candidate), nil
		}
	}
	return DefaultAPIBaseURL, nil
}

func ResolveToken(opts Options, cfg Config, env Env) (token string, tokenEnv string) {
	tokenEnv = firstNonEmpty(opts.TokenEnv, "BFT_CLI_TOKEN")
	return firstNonEmpty(env(tokenEnv), env("BFT_API_TOKEN"), cfg.Token), tokenEnv
}

type UnknownEnvironmentError struct {
	Env string
}

func (e UnknownEnvironmentError) Error() string {
	return "unknown BFT environment: " + e.Env
}

func SupportedEnvs() []string {
	return []string{"prod", "staging", "local"}
}

func normalizeURL(value string) string {
	return strings.TrimRight(strings.TrimSpace(value), "/")
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func expandHome(path string) string {
	if path == "$HOME" {
		if home, err := os.UserHomeDir(); err == nil && home != "" {
			return home
		}
	}
	if strings.HasPrefix(path, "$HOME/") {
		if home, err := os.UserHomeDir(); err == nil && home != "" {
			return filepath.Join(home, strings.TrimPrefix(path, "$HOME/"))
		}
	}
	if strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil && home != "" {
			return filepath.Join(home, strings.TrimPrefix(path, "~/"))
		}
	}
	return path
}
