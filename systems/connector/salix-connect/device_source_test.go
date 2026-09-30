package main

import "testing"

func TestDeviceSystemInfoReportsClientSource(t *testing.T) {
	for _, tc := range []struct{ namespace, want string }{{"@comma-dev", "comma_dev"}, {"@comma-staging", "comma_staging"}, {"@comma", "comma"}, {"", "connector"}, {"private-profile", "connector"}} {
		c := &connector{cfg: config{runtimeNamespace: tc.namespace}}
		info := c.deviceSystemInfo()
		if info["client_source"] != tc.want {
			t.Fatalf("namespace %q: source = %v", tc.namespace, info["client_source"])
		}
		if info["hostname"] == nil {
			t.Fatal("host information missing")
		}
	}
}
