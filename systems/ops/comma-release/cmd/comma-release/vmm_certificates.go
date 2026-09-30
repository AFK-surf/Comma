package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/big"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	kms "cloud.google.com/go/kms/apiv1"
	secretmanager "cloud.google.com/go/secretmanager/apiv1"
	"cloud.google.com/go/secretmanager/apiv1/secretmanagerpb"
	"github.com/AFK-surf/comma/systems/ops/comma-release/release"
	"go.step.sm/crypto/kms/cloudkms"
)

const vmmTLSBundleName = "salix-vmm-gateway-tls"

var vmmTLSNames = []string{vmmTLSBundleName, "salix-vmm-gateway-client-tls", "salix-vmm-gateway-client-ca"}
var vmmRuntimeNames = []string{"salix-vmm-gateway-runtime", "salix-compute-runtime"}

type vmmSecretPayload struct {
	Type string            `json:"type"`
	Data map[string]string `json:"data"`
}
type vmmTLSBundle struct {
	Secrets map[string]vmmSecretPayload `json:"secrets"`
}
type vmmIssuer struct {
	Key     string   `json:"key"`
	Subject string   `json:"subject"`
	SANs    []string `json:"sans"`
}
type vmmSignerFactory func(string) (crypto.Signer, error)

func runVMMCertificates(ctx context.Context, args []string, stdin io.Reader, stdout io.Writer) error {
	if len(args) == 0 {
		return errors.New("usage: comma-release vmm-certificates <check|snapshot|capture|publish|bootstrap-root|issue> --environment staging|prod")
	}
	operation := args[0]
	flags := flag.NewFlagSet("vmm-certificates", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	environment := flags.String("environment", "", "Selected environment")
	contextName := flags.String("context", "", "Kubernetes context for capture")
	output := flags.String("output", "", "Public root output file")
	force := flags.Bool("force", false, "Renew before expiry lead time")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if flags.NArg() != 0 || (*environment != "staging" && *environment != "prod") {
		return errors.New("select staging or prod and valid command options")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	project := "cueboard-gamma-" + *environment
	secretName := func(name, version string) string {
		return fmt.Sprintf("projects/%s/secrets/%s-%s/versions/%s", project, name, *environment, version)
	}
	if operation == "capture" {
		if *contextName == "" {
			return errors.New("capture requires --context")
		}
		bundle := vmmTLSBundle{Secrets: map[string]vmmSecretPayload{}}
		for _, name := range vmmTLSNames {
			body, err := (release.ExecRunner{Name: "kubectl"}).Run(ctx, nil, "--context", *contextName, "-n", "comma", "get", "secret", name, "-o", "json")
			if err != nil {
				return fmt.Errorf("could not capture %s; no payload published", name)
			}
			var payload vmmSecretPayload
			if err = json.Unmarshal(body, &payload); err != nil {
				return fmt.Errorf("invalid native TLS Secret %s", name)
			}
			bundle.Secrets[name] = payload
		}
		return writeJSON(stdout, bundle)
	}
	if operation == "issue" || operation == "bootstrap-root" {
		client, err := kms.NewKeyManagementClient(ctx)
		if err != nil {
			return fmt.Errorf("KMS client: %w", err)
		}
		defer client.Close()
		factory := func(key string) (crypto.Signer, error) { return cloudkms.NewSigner(client, key) }
		if operation == "bootstrap-root" {
			if *output == "" {
				return errors.New("bootstrap-root requires --output for its public certificate")
			}
			signer, err := factory(fmt.Sprintf("projects/%s/locations/us-west1/keyRings/vmm-certificates/cryptoKeys/client-ca/cryptoKeyVersions/1", project))
			if err != nil {
				return fmt.Errorf("client issuer: %w", err)
			}
			root, err := createVMMClientRoot(signer, *environment, time.Now())
			if err != nil {
				return err
			}
			return os.WriteFile(*output, root, 0644)
		}
		root := os.Getenv("COMMA_REPO_ROOT")
		if root == "" {
			root, err = os.Getwd()
			if err != nil {
				return err
			}
		}
		bundle, err := issueVMMBundle(*environment, filepath.Join(root, "k8s/salix-vmm-gateway/issuers", *environment), factory, time.Now())
		if err != nil {
			return err
		}
		body, err := json.Marshal(bundle)
		if err != nil {
			return err
		}
		return publishVMMBundle(ctx, project, *environment, body, stdout)
	}
	switch operation {
	case "check", "snapshot":
		if operation == "check" && *force {
			_, err := fmt.Fprintln(stdout, "true")
			return err
		}
		client, err := secretmanager.NewClient(ctx)
		if err != nil {
			return fmt.Errorf("GSM client: %w", err)
		}
		defer client.Close()
		if operation == "snapshot" {
			versions := map[string]string{}
			for _, name := range vmmRuntimeNames {
				response, err := client.AccessSecretVersion(ctx, &secretmanagerpb.AccessSecretVersionRequest{Name: secretName(name, "latest")})
				if err != nil {
					return fmt.Errorf("read %s metadata: %w", name, err)
				}
				version, err := vmmNumericVersion(response.Name)
				if err != nil {
					return err
				}
				versions[name] = version
			}
			return writeJSON(stdout, versions)
		}
		response, err := client.AccessSecretVersion(ctx, &secretmanagerpb.AccessSecretVersionRequest{Name: secretName(vmmTLSBundleName, "latest")})
		if err != nil {
			return fmt.Errorf("read TLS bundle: %w", err)
		}
		var bundle vmmTLSBundle
		if err = json.Unmarshal(response.Payload.Data, &bundle); err != nil {
			return errors.New("invalid TLS bundle")
		}
		due, err := vmmRenewalDue(bundle, time.Now())
		if err != nil {
			return err
		}
		_, err = fmt.Fprintln(stdout, due)
		return err
	case "publish":
		body, err := io.ReadAll(io.LimitReader(stdin, 65537))
		if err != nil {
			return err
		}
		if len(body) > 65536 {
			return errors.New("TLS bundle exceeds GSM payload limit")
		}
		var bundle vmmTLSBundle
		if err = json.Unmarshal(body, &bundle); err != nil {
			return errors.New("invalid TLS bundle")
		}
		if len(bundle.Secrets) != len(vmmTLSNames) {
			return errors.New("TLS bundle must contain the three native TLS Secrets")
		}
		for _, name := range vmmTLSNames {
			if _, ok := bundle.Secrets[name]; !ok {
				return errors.New("TLS bundle is incomplete")
			}
		}
		return publishVMMBundle(ctx, project, *environment, body, stdout)
	default:
		return fmt.Errorf("unknown VMM certificate operation %q", operation)
	}
}

func publishVMMBundle(ctx context.Context, project, environment string, body []byte, stdout io.Writer) error {
	client, err := secretmanager.NewClient(ctx)
	if err != nil {
		return fmt.Errorf("GSM client: %w", err)
	}
	defer client.Close()
	response, err := client.AddSecretVersion(ctx, &secretmanagerpb.AddSecretVersionRequest{
		Parent:  fmt.Sprintf("projects/%s/secrets/%s-%s", project, vmmTLSBundleName, environment),
		Payload: &secretmanagerpb.SecretPayload{Data: body},
	})
	if err != nil {
		return fmt.Errorf("publish TLS bundle: %w", err)
	}
	version, err := vmmNumericVersion(response.Name)
	if err != nil {
		return err
	}
	return writeJSON(stdout, map[string]string{vmmTLSBundleName: version})
}
func vmmNumericVersion(name string) (string, error) {
	version := name[strings.LastIndex(name, "/")+1:]
	number, err := strconv.ParseUint(version, 10, 64)
	if err != nil || number == 0 {
		return "", errors.New("GSM did not return a numeric Secret version")
	}
	return version, nil
}
func vmmRenewalDue(bundle vmmTLSBundle, now time.Time) (bool, error) {
	for _, name := range vmmTLSNames[:2] {
		body, err := base64.StdEncoding.DecodeString(bundle.Secrets[name].Data["tls.crt"])
		if err != nil {
			return false, fmt.Errorf("invalid %s certificate encoding", name)
		}
		certificate, err := parseVMMCertificate(body)
		if err != nil {
			return false, fmt.Errorf("invalid %s certificate", name)
		}
		if !certificate.NotAfter.After(now.Add(60 * 24 * time.Hour)) {
			return true, nil
		}
	}
	return false, nil
}
func parseVMMCertificate(body []byte) (*x509.Certificate, error) {
	block, rest := pem.Decode(body)
	if block == nil || block.Type != "CERTIFICATE" || len(bytes.TrimSpace(rest)) != 0 {
		return nil, errors.New("expected exactly one PEM certificate")
	}
	return x509.ParseCertificate(block.Bytes)
}
func vmmSerial() (*big.Int, error) {
	return rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
}
func vmmAlgorithm(signer crypto.Signer) x509.SignatureAlgorithm {
	if s, ok := signer.(interface {
		SignatureAlgorithm() x509.SignatureAlgorithm
	}); ok {
		return s.SignatureAlgorithm()
	}
	return x509.UnknownSignatureAlgorithm
}
func createVMMClientRoot(signer crypto.Signer, environment string, now time.Time) ([]byte, error) {
	serial, err := vmmSerial()
	if err != nil {
		return nil, err
	}
	template := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "Comma " + environment + " VMM client CA"},
		NotBefore: now.Add(-5 * time.Minute), NotAfter: now.Add(3650 * 24 * time.Hour), IsCA: true, BasicConstraintsValid: true, MaxPathLen: 0, MaxPathLenZero: true,
		KeyUsage: x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}, SignatureAlgorithm: vmmAlgorithm(signer)}
	der, err := x509.CreateCertificate(rand.Reader, template, template, signer.Public(), signer)
	if err != nil {
		return nil, fmt.Errorf("create client root: %w", err)
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	if err = certificate.CheckSignatureFrom(certificate); err != nil {
		return nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), nil
}
func issueVMMLeaf(issuer vmmIssuer, rootPEM []byte, signer crypto.Signer, purpose string, now time.Time) (map[string][]byte, error) {
	root, err := parseVMMCertificate(rootPEM)
	if err != nil {
		return nil, err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := vmmSerial()
	if err != nil {
		return nil, err
	}
	usage := x509.ExtKeyUsageServerAuth
	if purpose == "client" {
		usage = x509.ExtKeyUsageClientAuth
	}
	notAfter := now.Add(365 * 24 * time.Hour)
	if root.NotAfter.Before(notAfter) {
		notAfter = root.NotAfter
	}
	template := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: issuer.Subject}, DNSNames: issuer.SANs,
		NotBefore: now.Add(-5 * time.Minute), NotAfter: notAfter, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{usage}, SignatureAlgorithm: vmmAlgorithm(signer)}
	der, err := x509.CreateCertificate(rand.Reader, template, root, key.Public(), signer)
	if err != nil {
		return nil, fmt.Errorf("issue %s leaf: %w", purpose, err)
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	roots := x509.NewCertPool()
	roots.AddCert(root)
	if _, err = leaf.Verify(x509.VerifyOptions{Roots: roots, KeyUsages: []x509.ExtKeyUsage{usage}, CurrentTime: now}); err != nil {
		return nil, fmt.Errorf("verify %s leaf: %w", purpose, err)
	}
	for _, name := range issuer.SANs {
		if err = leaf.VerifyHostname(name); err != nil {
			return nil, err
		}
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}
	return map[string][]byte{"tls.crt": pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), "tls.key": pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})}, nil
}
func issueVMMBundle(environment, directory string, factory vmmSignerFactory, now time.Time) (vmmTLSBundle, error) {
	bundle := vmmTLSBundle{Secrets: map[string]vmmSecretPayload{}}
	body, err := os.ReadFile(filepath.Join(directory, "issuers.json"))
	if err != nil {
		return bundle, err
	}
	var config map[string]vmmIssuer
	if err = json.Unmarshal(body, &config); err != nil {
		return bundle, errors.New("invalid issuer configuration")
	}
	roots := map[string][]byte{}
	leaves := map[string]map[string][]byte{}
	for _, purpose := range []string{"server", "client"} {
		issuer := config[purpose]
		prefix := fmt.Sprintf("projects/cueboard-gamma-%s/locations/us-west1/keyRings/vmm-certificates/cryptoKeys/%s-ca/cryptoKeyVersions/", environment, purpose)
		if !strings.HasPrefix(issuer.Key, prefix) {
			return bundle, errors.New("issuer key must belong to selected environment and purpose")
		}
		if _, err = vmmNumericVersion(issuer.Key); err != nil {
			return bundle, err
		}
		root, err := os.ReadFile(filepath.Join(directory, purpose+".crt"))
		if err != nil {
			return bundle, err
		}
		signer, err := factory(issuer.Key)
		if err != nil {
			return bundle, fmt.Errorf("%s issuer: %w", purpose, err)
		}
		leaf, err := issueVMMLeaf(issuer, root, signer, purpose, now)
		if err != nil {
			return bundle, err
		}
		roots[purpose] = root
		leaves[purpose] = leaf
	}
	for _, purpose := range []string{"server", "client"} {
		name := vmmTLSBundleName
		if purpose == "client" {
			name = vmmTLSNames[1]
		}
		values := leaves[purpose]
		values["ca.crt"] = roots["server"]
		bundle.Secrets[name] = encodeVMMSecret(values)
	}
	bundle.Secrets[vmmTLSNames[2]] = encodeVMMSecret(map[string][]byte{"ca.crt": roots["client"]})
	return bundle, nil
}
func encodeVMMSecret(values map[string][]byte) vmmSecretPayload {
	data := map[string]string{}
	for name, value := range values {
		data[name] = base64.StdEncoding.EncodeToString(value)
	}
	return vmmSecretPayload{Type: "Opaque", Data: data}
}
