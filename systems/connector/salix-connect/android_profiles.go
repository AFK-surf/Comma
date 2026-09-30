package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
)

const androidMaxProfiles = 8

var androidProfileIDPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)
var androidAVDNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

type androidProfileSpec struct {
	ID          string `json:"id"`
	APILevel    int    `json:"api_level"`
	ABI         string `json:"abi"`
	ImageFlavor string `json:"image_flavor"`
	AVDName     string `json:"avd_name"`
}

type androidProfilesConfig struct {
	DefaultProfile string               `json:"default_profile"`
	Profiles       []androidProfileSpec `json:"profiles"`
}

func loadAndroidProfiles(path string) (androidProfilesConfig, error) {
	var config androidProfilesConfig
	f, err := os.Open(path)
	if err != nil {
		return config, errors.New("Android profile manifest is unavailable")
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return config, errors.New("Android profile manifest must be a regular file at most 64 KiB")
	}
	data, err := io.ReadAll(io.LimitReader(f, (64<<10)+1))
	if err != nil || len(data) > 64<<10 {
		return config, errors.New("Android profile manifest must be a regular file at most 64 KiB")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&config); err != nil {
		return config, fmt.Errorf("invalid Android profile manifest: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return config, errors.New("Android profile manifest must contain one JSON object")
	}
	if len(config.Profiles) == 0 || len(config.Profiles) > androidMaxProfiles {
		return config, errors.New("Android profile manifest requires 1 through 8 profiles")
	}
	ids, avds := map[string]bool{}, map[string]bool{}
	for _, profile := range config.Profiles {
		if !androidProfileIDPattern.MatchString(profile.ID) || !androidAVDNamePattern.MatchString(profile.AVDName) ||
			profile.APILevel < 1 || profile.APILevel > 99 || profile.ABI != "x86_64" {
			return config, errors.New("Android profiles require a stable id, AVD name, API level and x86_64 ABI")
		}
		switch profile.ImageFlavor {
		case "default", "google_apis", "google_apis_playstore":
		default:
			return config, errors.New("unsupported Android image flavor")
		}
		if ids[profile.ID] || avds[profile.AVDName] {
			return config, errors.New("Android profile ids and AVD names must be unique")
		}
		ids[profile.ID], avds[profile.AVDName] = true, true
	}
	if !ids[config.DefaultProfile] {
		return config, errors.New("Android default_profile must name a configured profile")
	}
	return config, nil
}

func (p *androidProvider) findProfile(id string) (androidProfileSpec, bool) {
	for _, profile := range p.profiles.Profiles {
		if profile.ID == id {
			return profile, true
		}
	}
	return androidProfileSpec{}, false
}

func (p *androidProvider) profileDetails() []map[string]any {
	details := make([]map[string]any, 0, len(p.profiles.Profiles))
	for _, profile := range p.profiles.Profiles {
		item := map[string]any{
			"id": profile.ID, "api_level": profile.APILevel,
			"abi": profile.ABI, "image_flavor": profile.ImageFlavor, "status": "installed",
		}
		if info, err := os.Stat(filepath.Join(p.cfg.androidAVDHome, profile.AVDName+".avd", "config.ini")); err != nil || !info.Mode().IsRegular() {
			item["status"] = "unavailable"
			item["issue"] = "avd_missing"
		}
		details = append(details, item)
	}
	return details
}
