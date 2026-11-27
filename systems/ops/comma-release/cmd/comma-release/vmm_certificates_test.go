package main

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"log"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"testing/synctest"
	"time"
)

// fixtureNow is when the fixture's certificates are issued and checked. It is
// what time.Now() returns when a synctest bubble starts, so a check made in a
// bubble agrees with it.
var fixtureNow = time.Date(2000, time.January, 1, 0, 0, 0, 0, time.UTC)

// fixtureTime is the clock of the TLS endpoints that check the fixture.
func fixtureTime() time.Time { return fixtureNow }

type vmmFixture struct {
	directory string
	roots     map[string][]byte
	keys      map[string]crypto.Signer
	bundle    vmmTLSBundle
}

func makeVMMFixture(t *testing.T) vmmFixture {
	t.Helper()
	fixture := vmmFixture{directory: t.TempDir(), roots: map[string][]byte{}, keys: map[string]crypto.Signer{}}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "server root"}, NotBefore: fixtureNow.Add(-time.Hour), NotAfter: fixtureNow.Add(10 * 365 * 24 * time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	der, err := x509.CreateCertificate(rand.Reader, template, template, key.Public(), key)
	if err != nil {
		t.Fatal(err)
	}
	root := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	fixture.roots["server"] = root
	fixture.keys["server"] = key
	if err = os.WriteFile(filepath.Join(fixture.directory, "server.crt"), root, 0600); err != nil {
		t.Fatal(err)
	}
	config := map[string]vmmIssuer{
		"server": {
			Key:     "projects/cueboard-gamma-staging/locations/us-west1/keyRings/vmm-certificates/cryptoKeys/server-ca/cryptoKeyVersions/1",
			Subject: "gateway.test",
			SANs:    []string{"gateway.test"},
		},
	}
	body, _ := json.Marshal(config)
	if err := os.WriteFile(filepath.Join(fixture.directory, "issuers.json"), body, 0600); err != nil {
		t.Fatal(err)
	}
	factory := func(name string) (crypto.Signer, error) {
		return fixture.keys["server"], nil
	}
	bundle, err := issueVMMBundle("staging", fixture.directory, factory, fixtureNow)
	if err != nil {
		t.Fatal(err)
	}
	fixture.bundle = bundle
	return fixture
}
func vmmTLSKeyPair(t *testing.T, payload vmmSecretPayload) tls.Certificate {
	t.Helper()
	cert, _ := base64.StdEncoding.DecodeString(payload.Data["tls.crt"])
	key, _ := base64.StdEncoding.DecodeString(payload.Data["tls.key"])
	pair, err := tls.X509KeyPair(cert, key)
	if err != nil {
		t.Fatal(err)
	}
	return pair
}
func TestVMMIssuedBundleEnforcesTLSBoundaries(t *testing.T) {
	fixture := makeVMMFixture(t)
	if len(fixture.bundle.Secrets) != 1 {
		t.Fatalf("bundle secrets = %d, want 1", len(fixture.bundle.Secrets))
	}
	serverPair := vmmTLSKeyPair(t, fixture.bundle.Secrets[vmmTLSBundleName])
	serverRoots := x509.NewCertPool()
	serverRoot, _ := base64.StdEncoding.DecodeString(fixture.bundle.Secrets[vmmTLSBundleName].Data["ca.crt"])
	serverRoots.AppendCertsFromPEM(serverRoot)
	foreign := makeVMMFixture(t)
	foreignRoots := x509.NewCertPool()
	foreignRoot, _ := base64.StdEncoding.DecodeString(foreign.bundle.Secrets[vmmTLSBundleName].Data["ca.crt"])
	foreignRoots.AppendCertsFromPEM(foreignRoot)
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "authorized") }))
	server.Config.ErrorLog = log.New(io.Discard, "", 0)
	server.TLS = &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{serverPair}, Time: fixtureTime}
	server.StartTLS()
	defer server.Close()
	for _, test := range []struct {
		name, hostname string
		roots          *x509.CertPool
		allowed        bool
	}{
		{"authorized", "gateway.test", serverRoots, true},
		{"wrong hostname", "wrong.test", serverRoots, false},
		{"foreign server issuer", "gateway.test", foreignRoots, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			transport := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: test.roots, ServerName: test.hostname, Time: fixtureTime}}
			defer transport.CloseIdleConnections()
			response, err := (&http.Client{Transport: transport}).Get(server.URL)
			if !test.allowed {
				if err == nil {
					response.Body.Close()
					t.Fatal("unauthorized TLS server accepted")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			body, _ := io.ReadAll(response.Body)
			if string(body) != "authorized" {
				t.Fatal("authorized request failed")
			}
		})
	}
}
func TestVMMRenewalPreservesRootsAndRejectsWrongIssuerTarget(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		fixture := makeVMMFixture(t)
		due, err := vmmRenewalDue(fixture.bundle, time.Now())
		if err != nil || due {
			t.Fatalf("new bundle due=%v err=%v", due, err)
		}
		due, err = vmmRenewalDue(fixture.bundle, time.Now().Add(310*24*time.Hour))
		if err != nil || !due {
			t.Fatalf("expiring bundle due=%v err=%v", due, err)
		}
		if fixture.bundle.Secrets[vmmTLSBundleName].Data["ca.crt"] != base64.StdEncoding.EncodeToString(fixture.roots["server"]) {
			t.Fatal("server trust missing from next release input")
		}
		factory := func(string) (crypto.Signer, error) { return fixture.keys["server"], nil }
		if _, err = issueVMMBundle("prod", fixture.directory, factory, time.Now()); err == nil {
			t.Fatal("staging issuer accepted in production")
		}
		wrongKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		wrongFactory := func(string) (crypto.Signer, error) { return wrongKey, nil }
		if _, err = issueVMMBundle("staging", fixture.directory, wrongFactory, time.Now()); err == nil {
			t.Fatal("wrong server signing key accepted")
		}
	})
}
func TestVMMCertificateCommandDoesNotEnterReleaseLifecycle(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		// Certificate checks do not require a release record, chart or database.
		t.Setenv("COMMA_RELEASE_ENV_SPEC", "/does-not-exist")
		if err := run(context.Background(), []string{"vmm-certificates", "check", "--environment", "staging", "--force"}, nil, io.Discard); err != nil {
			t.Fatal(err)
		}
	})
}
