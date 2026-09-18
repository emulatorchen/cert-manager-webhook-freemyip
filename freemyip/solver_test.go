package freemyip

import (
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
