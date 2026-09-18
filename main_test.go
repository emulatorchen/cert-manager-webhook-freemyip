package main

import (
	"os"
	"testing"
	"time"

	acme "github.com/cert-manager/cert-manager/test/acme"
	"github.com/emulatorchen/cert-manager-webhook-freemyip/freemyip"
)

var (
	zone    = os.Getenv("TEST_ZONE_NAME") // e.g. "example.freemyip.com."
	dnsName = os.Getenv("DNS_NAME")       // e.g. "example.freemyip.com"
)

func TestRunsSuite(t *testing.T) {
	// Conformance suite requires:
	//   TEST_ZONE_NAME=example.freemyip.com.
	//   DNS_NAME=example.freemyip.com
	// and testdata/freemyip/config.json + testdata/freemyip/api-key.yml to be
	// present. The token must own DNS_NAME: freemyip ignores the domain it is
	// asked to update and writes under the token's own domain instead, so a
	// mismatched token makes every check here fail while Present reports
	// success.
	fixture := acme.NewFixture(freemyip.NewSolver(),
		acme.SetResolvedZone(zone),

		// freemyip publishes at _acme-challenge.<domain> and nowhere else, so
		// the suite's default of cert-manager-dns01-tests.<zone> never exists.
		acme.SetResolvedFQDN("_acme-challenge."+dnsName+"."),

		acme.SetDNSName(dnsName),
		acme.SetAllowAmbientCredentials(false),
		acme.SetManifestPath("testdata/freemyip"),

		// Observed propagation is around ten seconds; this is slack, not an
		// expectation.
		acme.SetPropagationLimit(2*time.Minute),
	)

	fixture.RunConformance(t)
}
