package freemyip

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/cert-manager/cert-manager/pkg/acme/webhook/apis/acme/v1alpha1"
)

// freemyip writes the TXT at exactly the name passed in the domain parameter.
// Publishing at the certificate's domain instead of the challenge FQDN puts
// the record one label too high, which freemyip accepts and answers OK to —
// so the only symptom is that validation never succeeds.
func TestRecordName(t *testing.T) {
	for _, tc := range []struct {
		name string
		ch   v1alpha1.ChallengeRequest
		want string
	}{
		{
			name: "plain certificate",
			ch: v1alpha1.ChallengeRequest{
				DNSName:      "this.freemyip.com",
				ResolvedFQDN: "_acme-challenge.this.freemyip.com.",
			},
			want: "_acme-challenge.this.freemyip.com",
		},
		{
			name: "wildcard resolves to the same record",
			ch: v1alpha1.ChallengeRequest{
				DNSName:      "*.this.freemyip.com",
				ResolvedFQDN: "_acme-challenge.this.freemyip.com.",
			},
			want: "_acme-challenge.this.freemyip.com",
		},
		{
			name: "falls back when ResolvedFQDN is absent",
			ch: v1alpha1.ChallengeRequest{
				DNSName: "this.freemyip.com",
			},
			want: "_acme-challenge.this.freemyip.com",
		},
		{
			name: "fallback strips the wildcard label",
			ch: v1alpha1.ChallengeRequest{
				DNSName: "*.this.freemyip.com",
			},
			want: "_acme-challenge.this.freemyip.com",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := recordName(&tc.ch); got != tc.want {
				t.Errorf("recordName() = %q, want %q", got, tc.want)
			}
		})
	}
}

// The bug this guards against: sending the certificate domain, so the record
// lands at this.freemyip.com instead of _acme-challenge.this.freemyip.com.
func TestRecordNameIsNotTheBareDomain(t *testing.T) {
	ch := v1alpha1.ChallengeRequest{
		DNSName:      "this.freemyip.com",
		ResolvedFQDN: "_acme-challenge.this.freemyip.com.",
	}
	if got := recordName(&ch); got == ch.DNSName {
		t.Fatalf("recordName() returned the bare domain %q; the TXT would be published "+
			"one label above where ACME validation reads it", got)
	}
}

// freemyip refuses calls made close together with "Requested token doesn't
// exist" — throttling reported as an authentication failure. cert-manager
// calls Present then CleanUp back to back, so without a retry the solver
// fails on nearly every challenge, and the error blames the credential.
func TestCallAPIRetriesThrottling(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if atomic.AddInt32(&calls, 1) == 1 {
			fmt.Fprint(w, "ERROR Requested token doesn't exist: abc123\n")
			return
		}
		fmt.Fprint(w, "OK\nUpdated TXT for domain example.freemyip.com\n")
	}))
	defer srv.Close()

	restore := freemyipAPIBase
	freemyipAPIBase = srv.URL
	defer func() { freemyipAPIBase = restore }()

	if err := callAPI("abc123", "_acme-challenge.example.freemyip.com", "value"); err != nil {
		t.Fatalf("callAPI should have recovered on the second attempt, got: %v", err)
	}
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Errorf("expected 2 attempts, got %d", got)
	}
}

// A genuinely bad token never starts working, so the error has to surface
// rather than being retried away silently.
func TestCallAPIGivesUp(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&calls, 1)
		fmt.Fprint(w, "ERROR something is permanently wrong\n")
	}))
	defer srv.Close()

	restore := freemyipAPIBase
	freemyipAPIBase = srv.URL
	defer func() { freemyipAPIBase = restore }()

	err := callAPI("abc123", "_acme-challenge.example.freemyip.com", "value")
	if err == nil {
		t.Fatal("expected an error after exhausting attempts")
	}
	if !strings.Contains(err.Error(), "permanently wrong") {
		t.Errorf("the underlying response should survive in the error, got: %v", err)
	}
	if got := atomic.LoadInt32(&calls); got != apiAttempts {
		t.Errorf("expected %d attempts, got %d", apiAttempts, got)
	}
}
