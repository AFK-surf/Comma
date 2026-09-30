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
	"time"
)

type vmmFixture struct {
	directory string
	roots     map[string][]byte
	keys      map[string]crypto.Signer
	bundle    vmmTLSBundle
}

func makeVMMFixture(t *testing.T) vmmFixture {
	t.Helper()
	fixture := vmmFixture{directory: t.TempDir(), roots: map[string][]byte{}, keys: map[string]crypto.Signer{}}
	config := map[string]vmmIssuer{}
	for _, purpose := range []string{"server", "client"} {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		var root []byte
		if purpose == "client" {
			root, err = createVMMClientRoot(key, "staging", time.Now())
		} else {
			template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "server root"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(10 * 365 * 24 * time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
			var der []byte
			der, err = x509.CreateCertificate(rand.Reader, template, template, key.Public(), key)
			root = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
		}
		if err != nil {
			t.Fatal(err)
		}
		fixture.roots[purpose] = root
		fixture.keys[purpose] = key
		if err = os.WriteFile(filepath.Join(fixture.directory, purpose+".crt"), root, 0600); err != nil {
			t.Fatal(err)
		}
		issuer := vmmIssuer{Key: "projects/cueboard-gamma-staging/locations/us-west1/keyRings/vmm-certificates/cryptoKeys/" + purpose + "-ca/cryptoKeyVersions/1", Subject: "Comma"}
		if purpose == "server" {
			issuer.Subject = "gateway.test"
			issuer.SANs = []string{"gateway.test"}
		}
		config[purpose] = issuer
	}
	body, _ := json.Marshal(config)
	if err := os.WriteFile(filepath.Join(fixture.directory, "issuers.json"), body, 0600); err != nil {
		t.Fatal(err)
	}
	factory := func(name string) (crypto.Signer, error) {
		if name == config["server"].Key {
			return fixture.keys["server"], nil
		}
		return fixture.keys["client"], nil
	}
	bundle, err := issueVMMBundle("staging", fixture.directory, factory, time.Now())
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
	serverPair := vmmTLSKeyPair(t, fixture.bundle.Secrets[vmmTLSBundleName])
	clientPair := vmmTLSKeyPair(t, fixture.bundle.Secrets[vmmTLSNames[1]])
	clientRoots := x509.NewCertPool()
	clientRoot, _ := base64.StdEncoding.DecodeString(fixture.bundle.Secrets[vmmTLSNames[2]].Data["ca.crt"])
	clientRoots.AppendCertsFromPEM(clientRoot)
	serverRoots := x509.NewCertPool()
	serverRoot, _ := base64.StdEncoding.DecodeString(fixture.bundle.Secrets[vmmTLSNames[1]].Data["ca.crt"])
	serverRoots.AppendCertsFromPEM(serverRoot)
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "authorized") }))
	server.Config.ErrorLog = log.New(io.Discard, "", 0)
	server.TLS = &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{serverPair}, ClientCAs: clientRoots, ClientAuth: tls.RequireAndVerifyClientCert}
	server.StartTLS()
	defer server.Close()
	foreign := makeVMMFixture(t)
	foreignPair := vmmTLSKeyPair(t, foreign.bundle.Secrets[vmmTLSNames[1]])
	// Same authorized issuer, wrong leaf usage: issuer mismatch cannot hide this check.
	block, _ := pem.Decode(fixture.roots["client"])
	root, _ := x509.ParseCertificate(block.Bytes)
	template := &x509.Certificate{SerialNumber: big.NewInt(44), Subject: pkix.Name{CommonName: "wrong usage"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	leafKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, err := x509.CreateCertificate(rand.Reader, template, root, leafKey.Public(), fixture.keys["client"])
	if err != nil {
		t.Fatal(err)
	}
	wrongUsage := tls.Certificate{Certificate: [][]byte{der}, PrivateKey: leafKey}
	for _, test := range []struct {
		name, hostname string
		certificates   []tls.Certificate
		allowed        bool
	}{
		{"authorized", "gateway.test", []tls.Certificate{clientPair}, true},
		{"wrong hostname", "wrong.test", []tls.Certificate{clientPair}, false},
		{"foreign client issuer", "gateway.test", []tls.Certificate{foreignPair}, false},
		{"missing client", "gateway.test", nil, false},
		{"wrong client usage", "gateway.test", []tls.Certificate{wrongUsage}, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			transport := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: serverRoots, ServerName: test.hostname, Certificates: test.certificates}}
			defer transport.CloseIdleConnections()
			response, err := (&http.Client{Transport: transport, Timeout: 3 * time.Second}).Get(server.URL)
			if !test.allowed {
				if err == nil {
					response.Body.Close()
					t.Fatal("unauthorized TLS client admitted")
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
	fixture := makeVMMFixture(t)
	due, err := vmmRenewalDue(fixture.bundle, time.Now())
	if err != nil || due {
		t.Fatalf("new bundle due=%v err=%v", due, err)
	}
	due, err = vmmRenewalDue(fixture.bundle, time.Now().Add(310*24*time.Hour))
	if err != nil || !due {
		t.Fatalf("expiring bundle due=%v err=%v", due, err)
	}
	for _, name := range vmmTLSNames[:2] {
		if fixture.bundle.Secrets[name].Data["ca.crt"] != base64.StdEncoding.EncodeToString(fixture.roots["server"]) {
			t.Fatal("server trust missing from next release input")
		}
	}
	factory := func(string) (crypto.Signer, error) { return fixture.keys["server"], nil }
	if _, err = issueVMMBundle("prod", fixture.directory, factory, time.Now()); err == nil {
		t.Fatal("staging issuer accepted in production")
	}
	if _, err = issueVMMBundle("staging", fixture.directory, factory, time.Now()); err == nil {
		t.Fatal("wrong client signing key accepted")
	}
}
func TestVMMCertificateCommandDoesNotEnterReleaseLifecycle(t *testing.T) {
	// Certificate checks do not require a release record, chart or database.
	t.Setenv("COMMA_RELEASE_ENV_SPEC", "/does-not-exist")
	if err := run(context.Background(), []string{"vmm-certificates", "check", "--environment", "staging", "--force"}, nil, io.Discard); err != nil {
		t.Fatal(err)
	}
}
