package freemyip

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"github.com/cert-manager/cert-manager/pkg/acme/webhook"
	"github.com/cert-manager/cert-manager/pkg/acme/webhook/apis/acme/v1alpha1"
	"github.com/pkg/errors"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/klog/v2"
)

const (
	freemyipAPIBase = "https://freemyip.com/update"
)

// NewSolver returns a new freemyip DNS-01 solver.
func NewSolver() webhook.Solver {
	return &freemyipSolver{}
}

// freemyipSolver implements the cert-manager webhook.Solver interface for
// freemyip.com DNS-01 ACME challenges.
//
// freemyip exposes a single HTTP endpoint for both A-record updates and
// TXT-record management:
//
// GET https://freemyip.com/update with three query parameters: the API token,
// a domain, and txt. The record is written at exactly the name given as the
// domain — freemyip does not prepend _acme-challenge itself — so the full
// challenge FQDN goes there, e.g. _acme-challenge.example.freemyip.com.
// An empty txt clears the record.
type freemyipSolver struct {
	client *kubernetes.Clientset
}

// Name returns the solver name used to match ClusterIssuer webhook stanzas.
func (s *freemyipSolver) Name() string {
	return "freemyip"
}

// Present sets the DNS-01 TXT record required by Let's Encrypt.
func (s *freemyipSolver) Present(ch *v1alpha1.ChallengeRequest) error {
	klog.Infof("Present: fqdn=%s zone=%s", ch.ResolvedFQDN, ch.ResolvedZone)

	token, domain, err := s.credentialsFromChallenge(ch)
	if err != nil {
		return err
	}

	klog.Infof("Present: setting TXT record for domain=%q value=%q", domain, ch.Key)
	if err := callAPI(token, domain, ch.Key); err != nil {
		return fmt.Errorf("present TXT for %q: %w", ch.ResolvedFQDN, err)
	}

	klog.Infof("Present: TXT record set for %s", ch.ResolvedFQDN)
	return nil
}

// CleanUp removes the DNS-01 TXT record after the challenge has been verified.
func (s *freemyipSolver) CleanUp(ch *v1alpha1.ChallengeRequest) error {
	klog.Infof("CleanUp: fqdn=%s zone=%s", ch.ResolvedFQDN, ch.ResolvedZone)

	token, domain, err := s.credentialsFromChallenge(ch)
	if err != nil {
		return err
	}

	klog.Infof("CleanUp: clearing TXT record for domain=%q", domain)
	if err := callAPI(token, domain, ""); err != nil {
		return fmt.Errorf("cleanup TXT for %q: %w", ch.ResolvedFQDN, err)
	}

	klog.Infof("CleanUp: TXT record cleared for %s", ch.ResolvedFQDN)
	return nil
}

// Initialize builds the Kubernetes client used to fetch token Secrets.
func (s *freemyipSolver) Initialize(kubeClientConfig *rest.Config, _ <-chan struct{}) error {
	cl, err := kubernetes.NewForConfig(kubeClientConfig)
	if err != nil {
		return err
	}
	s.client = cl
	return nil
}

// credentialsFromChallenge loads config, reads the API token Secret, and
// extracts the registered freemyip domain from the challenge.
func (s *freemyipSolver) credentialsFromChallenge(ch *v1alpha1.ChallengeRequest) (token, domain string, err error) {
	cfg, err := loadConfig(ch.Config)
	if err != nil {
		return "", "", err
	}
	if cfg.APITokenSecretRef.LocalObjectReference.Name == "" {
		return "", "", errors.New("apiTokenSecretRef.name must not be empty in freemyip solver config")
	}

	secretName := cfg.APITokenSecretRef.LocalObjectReference.Name
	secret, err := s.client.CoreV1().Secrets(ch.ResourceNamespace).Get(
		context.Background(), secretName, metav1.GetOptions{},
	)
	if err != nil {
		return "", "", errors.Wrapf(err, "loading secret %q/%q", ch.ResourceNamespace, secretName)
	}

	raw, ok := secret.Data[cfg.APITokenSecretRef.Key]
	if !ok {
		return "", "", fmt.Errorf("key %q not found in secret %q/%q",
			cfg.APITokenSecretRef.Key, ch.ResourceNamespace, secretName)
	}
	token = strings.TrimSpace(string(raw))

	return token, recordName(ch), nil
}

// recordName returns the name sent as the domain parameter.
//
// Note that freemyip ignores it. The update endpoint applies the change to
// whichever domain the token owns, publishing at _acme-challenge.<that
// domain> regardless of what is asked for — verified against the live API,
// where the certificate's domain and the full challenge FQDN both landed in
// the same place within about ten seconds.
//
// A consequence worth knowing: pointing the solver at a domain the token does
// not own fails silently. freemyip answers OK and writes the record under its
// own domain instead, so Present succeeds, the record never appears where
// validation reads, and nothing in the response says so.
//
// The full challenge FQDN is sent anyway, since it is what lego's provider
// sends and it states the intent plainly. ResolvedFQDN is already
// _acme-challenge.<domain>. for plain and wildcard certificates alike — which
// is also why a wildcard and its apex collide here, sharing one TXT slot.
func recordName(ch *v1alpha1.ChallengeRequest) string {
	if fqdn := strings.TrimSuffix(ch.ResolvedFQDN, "."); fqdn != "" {
		return fqdn
	}
	// ResolvedFQDN is always set by cert-manager; fall back rather than send
	// an empty domain, which freemyip would reject.
	return "_acme-challenge." + strings.TrimPrefix(ch.DNSName, "*.")
}

// callAPI calls the freemyip update endpoint.  Pass an empty txt to clear the
// TXT record (CleanUp); pass the challenge key to set it (Present).
func callAPI(token, domain, txt string) error {
	params := url.Values{}
	params.Set("token", token)
	params.Set("domain", domain)
	params.Set("txt", txt)

	reqURL := freemyipAPIBase + "?" + params.Encode()

	resp, err := http.Get(reqURL) //nolint:noctx // simple single-call, no deadline needed
	if err != nil {
		return fmt.Errorf("HTTP GET %s: %w", freemyipAPIBase, err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	bodyStr := strings.TrimSpace(string(body))
	klog.V(4).Infof("freemyip API response (status=%d): %s", resp.StatusCode, bodyStr)

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("freemyip API returned HTTP %d: %s", resp.StatusCode, bodyStr)
	}
	// freemyip responds with "OK\n..." on success
	if !strings.HasPrefix(bodyStr, "OK") {
		return fmt.Errorf("unexpected freemyip API response: %s", bodyStr)
	}
	return nil
}
