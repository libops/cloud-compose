package providercleanup

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestClientUsesHeaderAuthenticationAndBoundedRequest(t *testing.T) {
	t.Parallel()
	const token = "provider-secret-token"
	requestCanceled := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if got := request.Header.Get("Authorization"); got != "Bearer "+token {
			t.Errorf("Authorization header = %q", got)
		}
		<-request.Context().Done()
		close(requestCanceled)
	}))
	t.Cleanup(server.Close)

	client := testClient(t, DigitalOcean, token, server.URL+"/v2/")
	client.requestTimeout = 25 * time.Millisecond
	_, err := client.list(context.Background(), kindFirewalls)
	if err == nil {
		t.Fatal("list() unexpectedly succeeded")
	}
	if strings.Contains(err.Error(), token) {
		t.Fatalf("list() error leaked token: %v", err)
	}
	select {
	case <-requestCanceled:
	case <-time.After(time.Second):
		t.Fatal("provider request context did not honor its deadline")
	}
}

func TestClientTreatsMissingDeleteAsSuccess(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(server.Close)

	client := testClient(t, Linode, "token", server.URL+"/v4/")
	if err := client.delete(context.Background(), kindInstances, "12345"); err != nil {
		t.Fatalf("delete() error = %v", err)
	}
}

func TestClientDoesNotExposeProviderResponseOrToken(t *testing.T) {
	t.Parallel()
	const token = "top-secret-token"
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.WriteHeader(http.StatusInternalServerError)
		_, _ = writer.Write([]byte("upstream diagnostic includes " + token))
	}))
	t.Cleanup(server.Close)

	client := testClient(t, Linode, token, server.URL+"/v4/")
	_, err := client.list(context.Background(), kindInstances)
	if err == nil {
		t.Fatal("list() unexpectedly succeeded")
	}
	for _, forbidden := range []string{token, "upstream diagnostic"} {
		if strings.Contains(err.Error(), forbidden) {
			t.Fatalf("list() error leaked %q: %v", forbidden, err)
		}
	}
	if !retryable(err) {
		t.Fatalf("HTTP 500 error was not retryable: %v", err)
	}
}

func TestClientRefusesCrossOriginRedirects(t *testing.T) {
	t.Parallel()
	const token = "redirect-secret"
	var redirectedRequests atomic.Int32
	redirectTarget := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		redirectedRequests.Add(1)
		if request.Header.Get("Authorization") != "" {
			t.Error("redirect target received provider authorization")
		}
		writer.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(redirectTarget.Close)

	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Location", redirectTarget.URL+"/v4/linode/instances")
		writer.WriteHeader(http.StatusFound)
	}))
	t.Cleanup(server.Close)

	client := testClient(t, Linode, token, server.URL+"/v4/")
	if _, err := client.list(context.Background(), kindInstances); err == nil {
		t.Fatal("list() unexpectedly followed a provider redirect")
	} else if strings.Contains(err.Error(), token) || strings.Contains(err.Error(), redirectTarget.URL) {
		t.Fatalf("redirect error exposed a token or redirect target: %v", err)
	}
	if got := redirectedRequests.Load(); got != 0 {
		t.Fatalf("redirect target received %d requests", got)
	}
}

func TestClientRequiresHTTP200ForLists(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(http.StatusPartialContent)
		_, _ = writer.Write([]byte(`{"droplets":[],"meta":{"total":0}}`))
	}))
	t.Cleanup(server.Close)

	client := testClient(t, DigitalOcean, "token", server.URL+"/v2/")
	resources, err := client.list(context.Background(), kindDroplets)
	if err == nil || resources != nil {
		t.Fatalf("list() = (%+v, %v); want HTTP 206 refusal", resources, err)
	}
}

func TestDecodeResourcesRejectsMissingArrayAndUnsafeID(t *testing.T) {
	t.Parallel()
	for name, body := range map[string]string{
		"missing array": `{}`,
		"unsafe id":     `{"data":[{"id":"../../instance","tags":[]}],"page":1,"pages":1,"results":1}`,
	} {
		name, body := name, body
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			_, err := decodeResources(Linode, kindInstances, []byte(body))
			if err == nil {
				t.Fatal("decodeResources() unexpectedly succeeded")
			}
		})
	}
}

func TestDecodeResourcesAcceptsProviderStringAndNumericIDs(t *testing.T) {
	t.Parallel()
	tests := []struct {
		provider Provider
		kind     resourceKind
		body     string
		wantID   string
	}{
		{provider: DigitalOcean, kind: kindVolumes, body: `{"volumes":[{"id":"volume-123","tags":[]}],"meta":{"total":1}}`, wantID: "volume-123"},
		{provider: Linode, kind: kindInstances, body: `{"data":[{"id":12345,"tags":[]}],"page":1,"pages":1,"results":1}`, wantID: "12345"},
	}
	for _, test := range tests {
		resources, err := decodeResources(test.provider, test.kind, []byte(test.body))
		if err != nil {
			t.Fatalf("decodeResources() error = %v", err)
		}
		if len(resources) != 1 || resources[0].ID != test.wantID {
			t.Fatalf("resources = %+v; want ID %q", resources, test.wantID)
		}
	}
}

func TestNewClientValidation(t *testing.T) {
	t.Parallel()
	if _, err := NewClient(DigitalOcean, ""); err == nil || !strings.Contains(err.Error(), "DIGITALOCEAN_TOKEN") {
		t.Fatalf("NewClient() missing-token error = %v", err)
	}
	if _, err := NewClient(Provider("unknown"), "token"); err == nil {
		t.Fatal("NewClient() accepted unknown provider")
	}
	if _, err := newClient(Linode, "token", "file:///tmp/provider", http.DefaultClient); err == nil {
		t.Fatal("newClient() accepted non-HTTP endpoint")
	}
}

func TestDigitalOceanPaginationRejectsUnsafeNextLinks(t *testing.T) {
	t.Parallel()
	const token = "pagination-secret"
	tests := []struct {
		name string
		next func(baseURL, attackerURL string) string
	}{
		{
			name: "malformed URL",
			next: func(_, _ string) string { return "https://[::1" },
		},
		{
			name: "relative URL",
			next: func(_, _ string) string { return "/v2/droplets?tag_name=cloud-compose-smoke&per_page=200&page=2" },
		},
		{
			name: "cross origin",
			next: func(_, attackerURL string) string {
				return attackerURL + "/v2/droplets?tag_name=cloud-compose-smoke&per_page=200&page=2"
			},
		},
		{
			name: "different API path",
			next: func(baseURL, _ string) string {
				return baseURL + "/v2/volumes?tag_name=cloud-compose-smoke&per_page=200&page=2"
			},
		},
		{
			name: "changed filter",
			next: func(baseURL, _ string) string {
				return baseURL + "/v2/droplets?per_page=200&page=2"
			},
		},
		{
			name: "added filter value",
			next: func(baseURL, _ string) string {
				return baseURL + "/v2/droplets?tag_name=cloud-compose-smoke&tag_name=foreign&per_page=200&page=2"
			},
		},
		{
			name: "unknown query key",
			next: func(baseURL, _ string) string {
				return baseURL + "/v2/droplets?tag_name=cloud-compose-smoke&per_page=200&page=2&cursor=unexpected"
			},
		},
		{
			name: "malformed query encoding",
			next: func(baseURL, _ string) string {
				return baseURL + "/v2/droplets?tag_name=cloud-compose-smoke&per_page=200&page=2;cursor=unexpected"
			},
		},
		{
			name: "cycle",
			next: func(baseURL, _ string) string {
				return baseURL + "/v2/droplets?tag_name=cloud-compose-smoke&per_page=200&page=1"
			},
		},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			var attackerRequests atomic.Int32
			attacker := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				attackerRequests.Add(1)
				if request.Header.Get("Authorization") != "" {
					t.Error("cross-origin pagination request exposed authorization header")
				}
				writer.WriteHeader(http.StatusNoContent)
			}))
			t.Cleanup(attacker.Close)

			var server *httptest.Server
			server = httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
				next := test.next(server.URL, attacker.URL)
				_, _ = fmt.Fprintf(writer, `{"droplets":[{"id":101,"tags":[]}],"links":{"pages":{"next":%q}},"meta":{"total":2}}`, next)
			}))
			t.Cleanup(server.Close)

			client := testClient(t, DigitalOcean, token, server.URL+"/v2/")
			resources, err := client.list(context.Background(), kindDroplets)
			if err == nil {
				t.Fatal("list() unexpectedly accepted unsafe pagination")
			}
			if resources != nil {
				t.Fatalf("list() returned partial resources: %+v", resources)
			}
			if strings.Contains(err.Error(), token) || strings.Contains(err.Error(), attacker.URL) {
				t.Fatalf("pagination error exposed a token or untrusted URL: %v", err)
			}
			if got := attackerRequests.Load(); got != 0 {
				t.Fatalf("unsafe next-link origin received %d requests", got)
			}
		})
	}
}

func TestDigitalOceanPaginationRejectsMalformedMetadata(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		_, _ = writer.Write([]byte(`{"droplets":[],"links":{"pages":{"next":42}},"meta":{"total":1}}`))
	}))
	t.Cleanup(server.Close)

	client := testClient(t, DigitalOcean, "token", server.URL+"/v2/")
	if resources, err := client.list(context.Background(), kindDroplets); err == nil || resources != nil {
		t.Fatalf("list() = (%+v, %v); want malformed-metadata failure", resources, err)
	}
}

func TestDigitalOceanPaginationHasSafePageBound(t *testing.T) {
	t.Parallel()
	var requests atomic.Int32
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requests.Add(1)
		page := 1
		if value := request.URL.Query().Get("page"); value != "" {
			parsed, err := strconv.Atoi(value)
			if err != nil {
				t.Errorf("page query = %q", value)
			}
			page = parsed
		}
		next := fmt.Sprintf("%s/v2/droplets?tag_name=cloud-compose-smoke&per_page=200&page=%d", server.URL, page+1)
		_, _ = fmt.Fprintf(writer, `{"droplets":[],"links":{"pages":{"next":%q}},"meta":{"total":1}}`, next)
	}))
	t.Cleanup(server.Close)

	client := testClient(t, DigitalOcean, "token", server.URL+"/v2/")
	resources, err := client.list(context.Background(), kindDroplets)
	if err == nil || !strings.Contains(err.Error(), "safety limit") {
		t.Fatalf("list() error = %v; want safety-limit failure", err)
	}
	if resources != nil {
		t.Fatalf("list() returned a partial listing: %+v", resources)
	}
	if got := requests.Load(); got != maximumListPages {
		t.Fatalf("pagination requests = %d; want %d", got, maximumListPages)
	}
}

func TestLinodePaginationRejectsMalformedOrUnboundedMetadata(t *testing.T) {
	t.Parallel()
	tests := map[string]string{
		"missing page":     `{"data":[],"pages":1,"results":0}`,
		"missing pages":    `{"data":[],"page":1,"results":0}`,
		"missing results":  `{"data":[],"page":1,"pages":1}`,
		"negative results": `{"data":[],"page":1,"pages":1,"results":-1}`,
		"zero page":        `{"data":[],"page":0,"pages":1,"results":0}`,
		"zero pages":       `{"data":[],"page":1,"pages":0,"results":0}`,
		"page past end":    `{"data":[],"page":2,"pages":1,"results":0}`,
		"over bound":       fmt.Sprintf(`{"data":[],"page":1,"pages":%d,"results":0}`, maximumListPages+1),
	}
	for name, response := range tests {
		name, response := name, response
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
				_, _ = writer.Write([]byte(response))
			}))
			t.Cleanup(server.Close)

			client := testClient(t, Linode, "token", server.URL+"/v4/")
			resources, err := client.list(context.Background(), kindInstances)
			if err == nil || resources != nil {
				t.Fatalf("list() = (%+v, %v); want strict metadata failure", resources, err)
			}
		})
	}
}

func TestLinodePaginationRejectsChangingPageCount(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Query().Get("page") == "2" {
			_, _ = writer.Write([]byte(`{"data":[],"page":2,"pages":3,"results":1}`))
			return
		}
		_, _ = writer.Write([]byte(`{"data":[{"id":101,"tags":[]}],"page":1,"pages":2,"results":1}`))
	}))
	t.Cleanup(server.Close)

	client := testClient(t, Linode, "token", server.URL+"/v4/")
	resources, err := client.list(context.Background(), kindInstances)
	if err == nil || !strings.Contains(err.Error(), "changed its declared page count") {
		t.Fatalf("list() error = %v; want changing-page-count failure", err)
	}
	if resources != nil {
		t.Fatalf("list() returned a partial listing: %+v", resources)
	}
}

func TestPaginationRejectsMissingOrMismatchedResultCount(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name     string
		provider Provider
		kind     resourceKind
		version  string
		body     string
	}{
		{name: "DigitalOcean missing total", provider: DigitalOcean, kind: kindDroplets, version: "/v2/", body: `{"droplets":[]}`},
		{name: "DigitalOcean negative total", provider: DigitalOcean, kind: kindDroplets, version: "/v2/", body: `{"droplets":[],"meta":{"total":-1}}`},
		{name: "DigitalOcean truncated terminal page", provider: DigitalOcean, kind: kindDroplets, version: "/v2/", body: `{"droplets":[{"id":101,"tags":[]}],"meta":{"total":2}}`},
		{name: "Linode missing results", provider: Linode, kind: kindInstances, version: "/v4/", body: `{"data":[],"page":1,"pages":1}`},
		{name: "Linode truncated terminal page", provider: Linode, kind: kindInstances, version: "/v4/", body: `{"data":[{"id":101,"tags":[]}],"page":1,"pages":1,"results":2}`},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
				_, _ = writer.Write([]byte(test.body))
			}))
			t.Cleanup(server.Close)

			client := testClient(t, test.provider, "token", server.URL+test.version)
			resources, err := client.list(context.Background(), test.kind)
			if err == nil || resources != nil {
				t.Fatalf("list() = (%+v, %v); want declared-count failure", resources, err)
			}
		})
	}
}

func TestPaginationRejectsChangingResultCount(t *testing.T) {
	t.Parallel()
	for _, provider := range []Provider{DigitalOcean, Linode} {
		provider := provider
		t.Run(string(provider), func(t *testing.T) {
			t.Parallel()
			var server *httptest.Server
			server = httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				if provider == Linode {
					if request.URL.Query().Get("page") == "2" {
						_, _ = writer.Write([]byte(`{"data":[{"id":102,"tags":[]}],"page":2,"pages":2,"results":3}`))
						return
					}
					_, _ = writer.Write([]byte(`{"data":[{"id":101,"tags":[]}],"page":1,"pages":2,"results":2}`))
					return
				}
				if request.URL.Query().Get("page") == "2" {
					_, _ = writer.Write([]byte(`{"droplets":[{"id":102,"tags":[]}],"meta":{"total":3}}`))
					return
				}
				next := server.URL + "/v2/droplets?tag_name=cloud-compose-smoke&per_page=200&page=2"
				_, _ = fmt.Fprintf(writer, `{"droplets":[{"id":101,"tags":[]}],"links":{"pages":{"next":%q}},"meta":{"total":2}}`, next)
			}))
			t.Cleanup(server.Close)

			kind := kindDroplets
			version := "/v2/"
			if provider == Linode {
				kind = kindInstances
				version = "/v4/"
			}
			client := testClient(t, provider, "token", server.URL+version)
			resources, err := client.list(context.Background(), kind)
			if err == nil || !strings.Contains(err.Error(), "changed its declared result count") {
				t.Fatalf("list() error = %v; want changing-result-count failure", err)
			}
			if resources != nil {
				t.Fatalf("list() returned a partial listing: %+v", resources)
			}
		})
	}
}

func testClient(t testing.TB, provider Provider, token, endpoint string) *Client {
	t.Helper()
	client, err := newClient(provider, token, endpoint, &http.Client{Timeout: time.Second})
	if err != nil {
		t.Fatalf("newClient() error = %v", err)
	}
	return client
}

func noSleep(ctx context.Context, _ time.Duration) error {
	return context.Cause(ctx)
}
