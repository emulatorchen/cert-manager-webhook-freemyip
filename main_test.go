package main

import (
	"os"
	"testing"

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
	// and testdata/freemyip/config.json + testdata/freemyip/api-key.yml to be present.
	fixture := acme.NewFixture(freemyip.NewSolver(),
		acme.SetResolvedZone(zone),
		acme.SetDNSName(dnsName),
		acme.SetAllowAmbientCredentials(false),
		acme.SetManifestPath("testdata/freemyip"),
	)

	fixture.RunConformance(t)
}
