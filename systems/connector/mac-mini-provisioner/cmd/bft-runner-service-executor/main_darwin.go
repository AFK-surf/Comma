//go:build darwin

// bft-runner-service-executor is an administrator-invoked, one-shot launchd
// adapter. It never executes the service programs and accepts no paths,
// templates, environment variables, labels, or numeric identities.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"golang.org/x/sys/unix"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	configPath  = "/Library/Application Support/BridgeForTeams/runner-service-owner.json"
	runnerLabel = "com.bridgeforteams.runner"
)

type ownerConfig struct {
	User  string `json:"user"`
	Group string `json:"group"`
	UID   int    `json:"uid"`
	GID   int    `json:"gid"`
	Home  string `json:"home"`
}
type fixedJob struct {
	name                                  string
	label, program, plist, stdout, stderr string
	arguments                             []string
}

type executor struct{ system runnerSystem }

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error { return (executor{system: defaultRunnerSystem()}).run(args) }

func (owner executor) run(args []string) error {
	if os.Geteuid() != 0 {
		return errors.New("administrator access is required")
	}
	if len(args) == 0 {
		return errors.New("usage: bft-runner-service-executor configure --service-user USER | install|start|stop|remove|status")
	}
	if err := validateProtectedExecutable(os.Executable); err != nil {
		return err
	}
	if args[0] == "configure" {
		return configure(args[1:])
	}
	config, err := readConfig(configPath)
	if err != nil {
		return err
	}
	if err := parseAction(args[0], args[1:]); err != nil {
		return err
	}
	job := resolveRunnerJob(config)

	switch args[0] {
	case "install":
		return owner.installJob(config, job)
	case "start":
		return owner.startConfiguredJob(config, job)
	case "stop":
		return owner.stopJob(config, job)
	case "remove":
		if err := owner.stopJob(config, job); err != nil {
			return err
		}
		err := os.Remove(job.plist)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	case "status":
		return owner.system.Launchctl(context.Background(), "print", "system/"+job.label)
	default:
		return errors.New("action must be install, start, stop, remove, or status")
	}
}

func configure(args []string) error {
	flags := flag.NewFlagSet("configure", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	name := flags.String("service-user", "", "non-root service user")
	if flags.Parse(args) != nil || flags.NArg() != 0 || *name == "" {
		return errors.New("configure requires --service-user USER")
	}
	account, err := user.Lookup(*name)
	if err != nil {
		return errors.New("service user does not exist")
	}
	uid, e1 := strconv.Atoi(account.Uid)
	gid, e2 := strconv.Atoi(account.Gid)
	if e1 != nil || e2 != nil || uid <= 0 || gid <= 0 || !filepath.IsAbs(account.HomeDir) {
		return errors.New("service user must have non-root numeric identity and absolute home")
	}
	group, err := user.LookupGroupId(account.Gid)
	if err != nil || group.Name == "" {
		return errors.New("service group does not exist")
	}
	config := ownerConfig{User: account.Username, Group: group.Name, UID: uid, GID: gid, Home: filepath.Clean(account.HomeDir)}
	if err := validateServiceHome(config); err != nil {
		return err
	}
	configDirectory := filepath.Dir(configPath)
	if err := ensureProtectedConfigDirectory(configDirectory); err != nil {
		return err
	}
	data, _ := json.Marshal(config)
	data = append(data, '\n')
	if err := replaceFile(configPath, data, 0600); err != nil {
		return err
	}

	return validateProtectedPath(configPath, false)
}

func parseAction(action string, args []string) error {
	switch action {
	case "install", "start", "stop", "remove", "status":
	default:
		return errors.New("unknown action")
	}
	if len(args) != 0 {
		return errors.New(action + " accepts no arguments")
	}
	return nil
}

func readConfig(path string) (ownerConfig, error) {
	if err := validateProtectedPath(path, false); err != nil {
		return ownerConfig{}, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return ownerConfig{}, err
	}
	var value ownerConfig
	if json.Unmarshal(data, &value) != nil || value.UID <= 0 || value.GID <= 0 || value.User == "" || value.Group == "" || !filepath.IsAbs(value.Home) {
		return ownerConfig{}, errors.New("service owner config is invalid")
	}
	account, err := user.Lookup(value.User)
	if err != nil || account.Uid != strconv.Itoa(value.UID) || account.Gid != strconv.Itoa(value.GID) || filepath.Clean(account.HomeDir) != value.Home {
		return ownerConfig{}, errors.New("service owner config no longer matches the OS account")
	}
	group, err := user.LookupGroupId(strconv.Itoa(value.GID))
	if err != nil || group.Name != value.Group {
		return ownerConfig{}, errors.New("service owner group no longer matches the OS account")
	}
	return value, nil
}

func resolveRunnerJob(config ownerConfig) fixedJob {
	return fixedJob{name: "runner", label: runnerLabel, program: filepath.Join(config.Home, ".bridge-for-teams", "bin", "bft-runner"), plist: "/Library/LaunchDaemons/" + runnerLabel + ".plist", stdout: "/Library/Logs/BridgeForTeams/runner.out.log", stderr: "/Library/Logs/BridgeForTeams/runner.err.log"}
}

func (owner executor) installJob(config ownerConfig, job fixedJob) error {
	if err := validateServiceProgram(config, job.program); err != nil {
		return err
	}
	if err := validateProtectedPath(filepath.Dir(job.plist), false); err != nil {
		return errors.New("launchd definition directory is not protected")
	}
	logs := filepath.Dir(job.stdout)
	if err := os.MkdirAll(logs, 0o750); err != nil {
		return err
	}
	if err := validateProtectedPath(logs, false); err != nil {
		return err
	}
	if err := os.Chown(logs, 0, config.GID); err != nil {
		return err
	}
	if err := os.Chmod(logs, 0o750); err != nil {
		return err
	}
	definition := renderPlist(config, job)
	loaded := owner.system.Launchctl(context.Background(), "print", "system/"+job.label)
	if loaded == nil {
		return errors.New("fixed job must be stopped before its definition is replaced")
	}
	if !errors.Is(loaded, errJobNotFound) {
		return errors.New("fixed job state could not be read")
	}
	if err := replaceFile(job.plist, definition, 0o644); err != nil {
		return err
	}
	return owner.system.Launchctl(context.Background(), "bootstrap", "system", job.plist)
}

func renderPlist(config ownerConfig, job fixedJob) []byte {
	values := append([]string{job.program}, job.arguments...)
	var arguments strings.Builder
	for _, value := range values {
		arguments.WriteString("<string>" + xmlEscape(value) + "</string>")
	}
	path := fixedRunnerPath(config.Home)
	working := filepath.Join(config.Home, ".bridge-for-teams")
	return []byte(fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>%s</string><key>EnvironmentVariables</key><dict><key>HOME</key><string>%s</string><key>PATH</key><string>%s</string></dict><key>ProgramArguments</key><array>%s</array><key>UserName</key><string>%s</string><key>GroupName</key><string>%s</string><key>WorkingDirectory</key><string>%s</string><key>StandardOutPath</key><string>%s</string><key>StandardErrorPath</key><string>%s</string><key>SoftResourceLimits</key><dict><key>NumberOfFiles</key><integer>65536</integer></dict><key>HardResourceLimits</key><dict><key>NumberOfFiles</key><integer>524288</integer></dict><key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>`, job.label, xmlEscape(config.Home), xmlEscape(path), arguments.String(), xmlEscape(config.User), xmlEscape(config.Group), xmlEscape(working), xmlEscape(job.stdout), xmlEscape(job.stderr)))
}

func fixedRunnerPath(home string) string {
	parts := []string{filepath.Join(home, ".bridge-for-teams", "bin"), filepath.Join(home, ".local", "bin"), filepath.Join(home, ".npm-global", "bin"), filepath.Join(home, ".yarn", "bin"), filepath.Join(home, ".bun", "bin"), filepath.Join(home, ".volta", "bin"), filepath.Join(home, ".asdf", "shims"), "/opt/homebrew/bin", "/Applications/LibreOffice.app/Contents/MacOS", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"}
	return strings.Join(parts, ":")
}

func xmlEscape(value string) string {
	replacer := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "\"", "&quot;", "'", "&apos;")
	return replacer.Replace(value)
}

func validateServiceProgram(config ownerConfig, program string) error {
	relative, err := filepath.Rel(config.Home, program)
	if err != nil || relative == "." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) || filepath.IsAbs(relative) {
		return errors.New("fixed service program is outside the configured home")
	}
	current := filepath.Clean(config.Home)
	parts := append([]string{"."}, strings.Split(relative, string(filepath.Separator))...)
	for index, part := range parts {
		if part != "." {
			current = filepath.Join(current, part)
		}
		info, statErr := os.Lstat(current)
		if statErr != nil {
			return errors.New("fixed service program path is unavailable")
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != 0 && int(stat.Uid) != config.UID || info.Mode()&0o022 != 0 || info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("fixed service program path is controlled by another identity (component=%s owner=%d mode=%s expected=%d)", current, stat.Uid, info.Mode(), config.UID)
		}
		if index == len(parts)-1 && (!info.Mode().IsRegular() || info.Mode()&0o111 == 0 || int(stat.Uid) != config.UID) {
			return errors.New("fixed service program is not an executable owned by the configured service user")
		}
	}
	return nil
}

func validateServiceHome(config ownerConfig) error {
	for current := filepath.Clean(config.Home); ; current = filepath.Dir(current) {
		info, err := os.Lstat(current)
		if err != nil {
			return errors.New("service home path is unavailable")
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != 0 && int(stat.Uid) != config.UID || info.Mode()&0o022 != 0 || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("service home path is controlled by another identity")
		}
		if current == "/" {
			break
		}
	}
	return nil
}

func (owner executor) startJob(job fixedJob) error {
	ctx := context.Background()
	if err := owner.system.Launchctl(ctx, "print", "system/"+job.label); err != nil {
		return errors.New("fixed job is not loaded; install it before start")
	}
	pid, err := owner.system.ServicePID(ctx, "system/"+job.label)
	if err != nil {
		return err
	}
	if pid > 0 && owner.system.ProcessRunning(pid) {
		return nil
	}
	return owner.system.Launchctl(ctx, "kickstart", "system/"+job.label)
}

func (owner executor) startConfiguredJob(config ownerConfig, job fixedJob) error {
	if err := validateServiceProgram(config, job.program); err != nil {
		return err
	}
	return owner.startJob(job)
}

func (owner executor) stopJob(config ownerConfig, job fixedJob) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := owner.system.Launchctl(ctx, "print", "system/"+job.label); errors.Is(err, errJobNotFound) {
		return nil
	} else if err != nil {
		return errors.New("fixed job state could not be read")
	}
	pid, err := owner.system.ServicePID(ctx, "system/"+job.label)
	if err != nil {
		return err
	}

	if err := owner.system.Launchctl(ctx, "bootout", "system/"+job.label); err != nil {
		return err
	}
	for pid > 0 && owner.system.ProcessRunning(pid) {
		select {
		case <-ctx.Done():
			return errors.New("fixed service process did not exit")
		case <-time.After(50 * time.Millisecond):
		}
	}
	return nil
}

func validateProtectedExecutable(resolve func() (string, error)) error {
	path, err := resolve()
	if err != nil {
		return err
	}
	return validateProtectedPath(path, true)
}

func ensureProtectedConfigDirectory(path string) error {
	if err := validateProtectedPath(filepath.Dir(path), false); err != nil {
		return errors.New("service owner config parent is not protected")
	}
	if err := os.Mkdir(path, 0o755); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	if err := validateProtectedPath(path, false); err != nil {
		return errors.New("service owner config directory is not protected")
	}
	return nil
}
func validateProtectedPath(path string, executable bool) error {
	clean := filepath.Clean(path)
	info, err := os.Lstat(clean)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != 0 || info.Mode()&0o022 != 0 || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("root-owned path is replaceable")
	}
	if executable && info.Mode()&0o111 == 0 {
		return errors.New("executor is not executable")
	}
	for parent := filepath.Dir(clean); parent != "/"; parent = filepath.Dir(parent) {
		info, err = os.Lstat(parent)
		if err != nil {
			return err
		}
		stat, ok = info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != 0 || info.Mode()&0o022 != 0 || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("root-owned parent is replaceable")
		}
	}
	return nil
}

var errJobNotFound = errors.New("fixed runner job is not loaded")

type runnerSystem struct {
	Launchctl      func(context.Context, ...string) error
	ServicePID     func(context.Context, string) (int, error)
	ProcessRunning func(int) bool
}

func defaultRunnerSystem() runnerSystem {
	return runnerSystem{Launchctl: runLaunchctl, ServicePID: servicePID, ProcessRunning: processRunning}
}
func runLaunchctl(ctx context.Context, args ...string) error {
	output, err := exec.CommandContext(ctx, "/bin/launchctl", args...).CombinedOutput()
	if err == nil {
		return nil
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	message := strings.TrimSpace(string(output))
	if strings.Contains(message, "Could not find service") || strings.Contains(message, "Could not find domain") {
		return fmt.Errorf("%w: %s", errJobNotFound, message)
	}
	return fmt.Errorf("launchctl %s: %w: %s", args[0], err, message)
}
func servicePID(ctx context.Context, target string) (int, error) {
	output, err := exec.CommandContext(ctx, "/bin/launchctl", "print", target).Output()
	if err != nil {
		return 0, err
	}
	for _, line := range strings.Split(string(output), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if ok && strings.TrimSpace(key) == "pid" {
			return strconv.Atoi(strings.TrimSpace(value))
		}
	}
	return 0, nil
}
func processRunning(pid int) bool {
	err := unix.Kill(pid, 0)
	return err == nil || errors.Is(err, unix.EPERM)
}
func replaceFile(path string, data []byte, mode os.FileMode) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".runner-service-*")
	if err != nil {
		return err
	}
	temporary := file.Name()
	defer os.Remove(temporary)
	if err := file.Chmod(mode); err != nil {
		file.Close()
		return err
	}
	count, err := file.Write(data)
	if err == nil && count != len(data) {
		err = io.ErrShortWrite
	}
	if err == nil {
		err = file.Sync()
	}
	if err = errors.Join(err, file.Close()); err != nil {
		return err
	}
	if err := os.Rename(temporary, path); err != nil {
		return err
	}
	directory, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	return errors.Join(directory.Sync(), directory.Close())
}
