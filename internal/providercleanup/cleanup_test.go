package providercleanup

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestDigitalOceanSweepDeletesOnlyExactRunResources(t *testing.T) {
	t.Parallel()
	api := newFakeProviderAPI(t, DigitalOcean, "do-secret", map[resourceKind][]fakeResource{
		kindFirewalls: {
			{ID: "fw-owned", Name: "cc-do-isle-123456789-a1b2c3-cloud-compose"},
			{ID: "fw-other-run", Name: "cc-do-isle-123456780-a1b2c3-cloud-compose"},
			{ID: "fw-wrong-shape", Name: "cc-do-isle-123456789-cloud-compose"},
		},
		kindDroplets: {
			{ID: "101", Tags: []string{"cloud-compose-smoke", "digitalocean-isle", "gha-run-123456789"}},
			{ID: "102", Tags: []string{"cloud-compose-smoke", "digitalocean-isle", "gha-run-123456780"}},
			{ID: "103", Tags: []string{"digitalocean-isle", "gha-run-123456789"}},
		},
		kindVolumes: {
			{ID: "vol-owned", Tags: []string{"cloud-compose-smoke", "digitalocean-isle", "gha-run-123456789"}},
			{ID: "vol-other-target", Tags: []string{"cloud-compose-smoke", "digitalocean-wp", "gha-run-123456789"}},
		},
	})

	runner := Runner{Client: api.Client(t), Sleep: noSleep}
	err := runner.Sweep(context.Background(), fastConfig(Config{
		Provider: DigitalOcean,
		Target:   "digitalocean-isle",
		RunID:    "123456789",
	}))
	if err != nil {
		t.Fatalf("Sweep() error = %v", err)
	}

	want := []string{"firewalls/fw-owned", "droplets/101", "volumes/vol-owned"}
	if got := api.Deletions(); !slices.Equal(got, want) {
		t.Fatalf("deletions = %q; want %q", got, want)
	}
	api.AssertTokenNeverAppearedInPath(t)
}

func TestLinodeSweepSharesExactOwnershipAcrossApplicationAndConfigManagement(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name       string
		config     Config
		tags       []string
		wrongTags  []string
		wantDelete []string
	}{
		{
			name: "application",
			config: Config{
				Provider: Linode,
				Target:   "linode-wp",
				RunID:    "123456789",
			},
			tags:       []string{"cloud-compose-smoke", "linode-wp", "gha-run-123456789"},
			wrongTags:  []string{"cloud-compose-smoke", "linode-wp", "gha-run-123456780"},
			wantDelete: []string{"firewalls/201", "instances/301", "volumes/401"},
		},
		{
			name: "config management",
			config: Config{
				Provider: Linode,
				Scope:    ConfigManagementScope,
				Target:   "ansible-drupal",
				RunID:    "123456789",
			},
			tags:       []string{"cloud-compose-smoke", "config-management-smoke", "config-management-ansible-drupal", "gha-run-123456789"},
			wrongTags:  []string{"cloud-compose-smoke", "config-management-smoke", "config-management-salt-drupal", "gha-run-123456789"},
			wantDelete: []string{"firewalls/201", "instances/301", "volumes/401"},
		},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			api := newFakeProviderAPI(t, Linode, "linode-secret", map[resourceKind][]fakeResource{
				kindFirewalls: {
					{ID: "201", Tags: test.tags},
					{ID: "202", Tags: test.wrongTags},
				},
				kindInstances: {
					{ID: "301", Tags: test.tags},
					{ID: "302", Tags: test.wrongTags},
				},
				kindVolumes: {
					{ID: "401", Tags: test.tags},
					{ID: "402", Tags: test.wrongTags},
				},
			})

			runner := Runner{Client: api.Client(t), Sleep: noSleep}
			if err := runner.Sweep(context.Background(), fastConfig(test.config)); err != nil {
				t.Fatalf("Sweep() error = %v", err)
			}
			if got := api.Deletions(); !slices.Equal(got, test.wantDelete) {
				t.Fatalf("deletions = %q; want %q", got, test.wantDelete)
			}
		})
	}
}

func TestSweepDeletesOwnedResourceFoundOnlyOnSecondPage(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name     string
		provider Provider
		kind     resourceKind
		target   string
	}{
		{name: "DigitalOcean", provider: DigitalOcean, kind: kindDroplets, target: "digitalocean-isle"},
		{name: "Linode", provider: Linode, kind: kindInstances, target: "linode-wp"},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			const ownedID = "owned-page-2"
			var mu sync.Mutex
			deleted := false
			pageTwoRequests := 0
			deletions := []string{}
			var server *httptest.Server

			server = httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				mu.Lock()
				defer mu.Unlock()
				if got := request.Header.Get("Authorization"); got != "Bearer token" {
					t.Errorf("Authorization header = %q", got)
				}

				prefix := "/v2/"
				if test.provider == Linode {
					prefix = "/v4/"
				}
				list, _ := listPath(test.provider, test.kind)
				list = strings.Split(list, "?")[0]
				deletePath, _ := deletePrefix(test.provider, test.kind)
				if request.Method == http.MethodDelete && request.URL.Path == prefix+deletePath+ownedID {
					deleted = true
					deletions = append(deletions, string(test.kind)+"/"+ownedID)
					writer.WriteHeader(http.StatusNoContent)
					return
				}
				if request.Method != http.MethodGet {
					http.NotFound(writer, request)
					return
				}

				kind, _, ok := paginatedTestRoute(test.provider, request.URL.Path)
				if !ok {
					http.NotFound(writer, request)
					return
				}
				if request.URL.Path != prefix+list {
					writeEmptyProviderPage(writer, test.provider, kind)
					return
				}

				page := request.URL.Query().Get("page")
				if page == "2" {
					pageTwoRequests++
					writeProviderPage(writer, test.provider, kind, 2, 2, 2, []fakeResource{{
						ID:   ownedID,
						Tags: []string{"cloud-compose-smoke", test.target, "gha-run-123456789"},
					}}, "")
					return
				}
				foreign := []fakeResource{{ID: "foreign-page-1", Tags: []string{"cloud-compose-smoke", test.target, "gha-run-999999999"}}}
				if deleted {
					writeProviderPage(writer, test.provider, kind, 1, 1, 1, foreign, "")
					return
				}
				next := ""
				if test.provider == DigitalOcean {
					next = server.URL + request.URL.Path + "?" + request.URL.Query().Encode() + "&page=2"
				}
				writeProviderPage(writer, test.provider, kind, 1, 2, 2, foreign, next)
			}))
			t.Cleanup(server.Close)

			version := "/v2/"
			if test.provider == Linode {
				version = "/v4/"
			}
			runner := Runner{Client: testClient(t, test.provider, "token", server.URL+version), Sleep: noSleep}
			if err := runner.Sweep(context.Background(), fastConfig(Config{
				Provider: test.provider,
				Target:   test.target,
				RunID:    "123456789",
			})); err != nil {
				t.Fatalf("Sweep() error = %v", err)
			}

			mu.Lock()
			defer mu.Unlock()
			if !slices.Equal(deletions, []string{string(test.kind) + "/" + ownedID}) {
				t.Fatalf("deletions = %q", deletions)
			}
			if pageTwoRequests == 0 {
				t.Fatal("Sweep() never requested the page containing its owned resource")
			}
		})
	}
}

func TestSweepFailsClosedBeforeDeletingFromPartialPageSet(t *testing.T) {
	t.Parallel()
	var deleteRequests atomic.Int32
	attacker := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Header.Get("Authorization") != "" {
			t.Error("unsafe pagination target received provider authorization")
		}
		writer.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(attacker.Close)

	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method == http.MethodDelete {
			deleteRequests.Add(1)
			writer.WriteHeader(http.StatusNoContent)
			return
		}
		kind, _, ok := paginatedTestRoute(DigitalOcean, request.URL.Path)
		if !ok {
			http.NotFound(writer, request)
			return
		}
		if kind != kindDroplets {
			writeEmptyProviderPage(writer, DigitalOcean, kind)
			return
		}
		writeProviderPage(writer, DigitalOcean, kind, 1, 2, 2, []fakeResource{{
			ID:   "owned-page-1",
			Tags: []string{"cloud-compose-smoke", "digitalocean-isle", "gha-run-123456789"},
		}}, attacker.URL+"/v2/droplets?tag_name=cloud-compose-smoke&per_page=200&page=2")
	}))
	t.Cleanup(server.Close)

	runner := Runner{Client: testClient(t, DigitalOcean, "token", server.URL+"/v2/"), Sleep: noSleep}
	err := runner.Sweep(context.Background(), fastConfig(Config{
		Provider: DigitalOcean,
		Target:   "digitalocean-isle",
		RunID:    "123456789",
	}))
	if err == nil {
		t.Fatal("Sweep() silently accepted a partial provider listing")
	}
	if got := deleteRequests.Load(); got != 0 {
		t.Fatalf("Sweep() issued %d deletes from a partial provider listing", got)
	}
}

func TestSweepFailsClosedBeforeDeletingFromTruncatedTerminalList(t *testing.T) {
	t.Parallel()
	var deleteRequests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method == http.MethodDelete {
			deleteRequests.Add(1)
			writer.WriteHeader(http.StatusNoContent)
			return
		}
		kind, _, ok := paginatedTestRoute(DigitalOcean, request.URL.Path)
		if !ok {
			http.NotFound(writer, request)
			return
		}
		if kind != kindDroplets {
			writeEmptyProviderPage(writer, DigitalOcean, kind)
			return
		}
		writeProviderPage(writer, DigitalOcean, kind, 1, 1, 2, []fakeResource{{
			ID:   "owned-visible-resource",
			Tags: []string{"cloud-compose-smoke", "digitalocean-isle", "gha-run-123456789"},
		}}, "")
	}))
	t.Cleanup(server.Close)

	runner := Runner{Client: testClient(t, DigitalOcean, "token", server.URL+"/v2/"), Sleep: noSleep}
	err := runner.Sweep(context.Background(), fastConfig(Config{
		Provider: DigitalOcean,
		Target:   "digitalocean-isle",
		RunID:    "123456789",
	}))
	if err == nil {
		t.Fatal("Sweep() silently accepted a truncated terminal listing")
	}
	if got := deleteRequests.Load(); got != 0 {
		t.Fatalf("Sweep() issued %d deletes from a truncated terminal listing", got)
	}
}

func TestSweepIsIdempotentWhenDeleteReportsNotFound(t *testing.T) {
	t.Parallel()
	api := newFakeProviderAPI(t, Linode, "token", map[resourceKind][]fakeResource{
		kindInstances: {
			{ID: "301", Tags: []string{"cloud-compose-smoke", "linode-wp", "gha-run-123456789"}, DeleteStatus: http.StatusNotFound},
		},
	})

	runner := Runner{Client: api.Client(t), Sleep: noSleep}
	if err := runner.Sweep(context.Background(), fastConfig(Config{
		Provider: Linode,
		Target:   "linode-wp",
		RunID:    "123456789",
	})); err != nil {
		t.Fatalf("Sweep() error = %v", err)
	}
	if got := api.Deletions(); !slices.Equal(got, []string{"instances/301"}) {
		t.Fatalf("deletions = %q", got)
	}
}

func TestSweepRetriesTransientResponsesWithoutLoggingSecrets(t *testing.T) {
	t.Parallel()
	const token = "never-log-this-token"
	api := newFakeProviderAPI(t, Linode, token, map[resourceKind][]fakeResource{})
	api.FailLists(kindFirewalls, 1)
	var logs bytes.Buffer
	runner := Runner{
		Client: api.Client(t),
		Logger: slog.New(slog.NewTextHandler(&logs, nil)),
		Sleep:  noSleep,
	}
	if err := runner.Sweep(context.Background(), fastConfig(Config{
		Provider: Linode,
		Target:   "linode-wp",
		RunID:    "123456789",
	})); err != nil {
		t.Fatalf("Sweep() error = %v", err)
	}
	if strings.Contains(logs.String(), token) {
		t.Fatalf("logs leaked provider token: %s", logs.String())
	}
	if api.ListCalls(kindFirewalls) < 2 {
		t.Fatal("Sweep() did not retry transient list failure")
	}
}

func TestSweepRetriesTransientDeleteConflict(t *testing.T) {
	t.Parallel()
	api := newFakeProviderAPI(t, Linode, "token", map[resourceKind][]fakeResource{
		kindInstances: {
			{ID: "301", Tags: []string{"cloud-compose-smoke", "linode-wp", "gha-run-123456789"}},
		},
	})
	api.FailDeletes(kindInstances, "301", 1)
	runner := Runner{Client: api.Client(t), Sleep: noSleep}
	if err := runner.Sweep(context.Background(), fastConfig(Config{
		Provider: Linode,
		Target:   "linode-wp",
		RunID:    "123456789",
	})); err != nil {
		t.Fatalf("Sweep() error = %v", err)
	}
	if got := api.Deletions(); !slices.Equal(got, []string{"instances/301", "instances/301"}) {
		t.Fatalf("delete attempts = %q", got)
	}
}

func TestListRetryPolicyUsesActualHTTPResponses(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name         string
		statuses     []int
		attempts     int
		wantErr      bool
		wantRequests int
		wantDelays   []time.Duration
	}{
		{
			name:         "transient statuses recover with capped exponential backoff",
			statuses:     []int{http.StatusRequestTimeout, http.StatusTooEarly, http.StatusTooManyRequests, http.StatusInternalServerError, http.StatusServiceUnavailable, http.StatusOK},
			attempts:     6,
			wantRequests: 6,
			wantDelays:   []time.Duration{2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second, 30 * time.Second},
		},
		{
			name:         "persistent transient status is bounded",
			statuses:     []int{http.StatusServiceUnavailable},
			attempts:     3,
			wantErr:      true,
			wantRequests: 3,
			wantDelays:   []time.Duration{2 * time.Second, 4 * time.Second},
		},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			server, requests := newStatusSequenceServer(t, test.statuses, `{"data":[],"page":1,"pages":1,"results":0}`)
			client := testClient(t, Linode, "token", server.URL+"/v4/")
			delays := []time.Duration{}
			runner := Runner{
				Client: client,
				Logger: slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil)),
				Sleep: func(ctx context.Context, delay time.Duration) error {
					delays = append(delays, delay)
					return context.Cause(ctx)
				},
			}
			_, err := runner.listWithRetry(context.Background(), Config{
				Provider:       Linode,
				ListAttempts:   test.attempts,
				ListRetryDelay: 2 * time.Second,
			}, kindInstances)
			if (err != nil) != test.wantErr {
				t.Fatalf("listWithRetry() error = %v; wantErr %t", err, test.wantErr)
			}
			if got := int(requests.Load()); got != test.wantRequests {
				t.Fatalf("requests = %d; want %d", got, test.wantRequests)
			}
			if !slices.Equal(delays, test.wantDelays) {
				t.Fatalf("backoff delays = %v; want %v", delays, test.wantDelays)
			}
		})
	}
}

func TestPermanentListHTTPResponsesAreNotRetryable(t *testing.T) {
	for _, status := range []int{
		http.StatusBadRequest,
		http.StatusUnauthorized,
		http.StatusForbidden,
		http.StatusNotFound,
		http.StatusGone,
		http.StatusConflict,
		http.StatusLocked,
		http.StatusFound,
	} {
		if retryableStatus(http.MethodGet, status) {
			t.Errorf("GET HTTP %d is unexpectedly retryable", status)
		}
	}
}

func TestListRetryPolicyRecoversFromNetworkFailure(t *testing.T) {
	t.Parallel()
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		if requests.Add(1) == 1 {
			hijacker, ok := writer.(http.Hijacker)
			if !ok {
				t.Error("httptest response writer does not support connection hijacking")
				return
			}
			connection, _, err := hijacker.Hijack()
			if err != nil {
				t.Errorf("hijack connection: %v", err)
				return
			}
			_ = connection.Close()
			return
		}
		_, _ = writer.Write([]byte(`{"data":[],"page":1,"pages":1,"results":0}`))
	}))
	t.Cleanup(server.Close)

	delays := []time.Duration{}
	runner := Runner{
		Client: testClient(t, Linode, "token", server.URL+"/v4/"),
		Logger: slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil)),
		Sleep: func(ctx context.Context, delay time.Duration) error {
			delays = append(delays, delay)
			return context.Cause(ctx)
		},
	}
	if _, err := runner.listWithRetry(context.Background(), Config{
		Provider:       Linode,
		ListAttempts:   2,
		ListRetryDelay: 3 * time.Second,
	}, kindInstances); err != nil {
		t.Fatalf("listWithRetry() error = %v", err)
	}
	if requests.Load() != 2 || !slices.Equal(delays, []time.Duration{3 * time.Second}) {
		t.Fatalf("network retry requests = %d, delays = %v", requests.Load(), delays)
	}
}

func TestDeleteRetryPolicyUsesActualHTTPResponses(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name         string
		statuses     []int
		attempts     int
		wantErr      bool
		wantRequests int
		wantSleeps   int
	}{
		{name: "transient statuses", statuses: []int{408, 425, 429, 500, 204}, attempts: 5, wantRequests: 5, wantSleeps: 4},
		{name: "dependency conflicts", statuses: []int{409, 423, 204}, attempts: 3, wantRequests: 3, wantSleeps: 2},
		{name: "not found is idempotent", statuses: []int{404}, attempts: 3, wantRequests: 1},
		{name: "gone is idempotent", statuses: []int{410}, attempts: 3, wantRequests: 1},
		{name: "bad request fails fast", statuses: []int{400}, attempts: 3, wantErr: true, wantRequests: 1},
		{name: "unauthorized fails fast", statuses: []int{401}, attempts: 3, wantErr: true, wantRequests: 1},
		{name: "forbidden fails fast", statuses: []int{403}, attempts: 3, wantErr: true, wantRequests: 1},
		{name: "persistent transient is bounded", statuses: []int{503}, attempts: 3, wantErr: true, wantRequests: 3, wantSleeps: 2},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			server, requests := newStatusSequenceServer(t, test.statuses, "")
			sleeps := 0
			runner := Runner{
				Client: testClient(t, Linode, "token", server.URL+"/v4/"),
				Logger: slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil)),
				Sleep: func(ctx context.Context, delay time.Duration) error {
					if delay != 7*time.Second {
						t.Errorf("delete retry delay = %s; want 7s", delay)
					}
					sleeps++
					return context.Cause(ctx)
				},
			}
			err := runner.deleteWithRetry(context.Background(), Config{
				Provider:         Linode,
				DeleteAttempts:   test.attempts,
				DeleteRetryDelay: 7 * time.Second,
			}, kindInstances, "301")
			if (err != nil) != test.wantErr {
				t.Fatalf("deleteWithRetry() error = %v; wantErr %t", err, test.wantErr)
			}
			if got := int(requests.Load()); got != test.wantRequests {
				t.Fatalf("requests = %d; want %d", got, test.wantRequests)
			}
			if sleeps != test.wantSleeps {
				t.Fatalf("retry sleeps = %d; want %d", sleeps, test.wantSleeps)
			}
		})
	}
}

func TestDeleteRetryPolicyRecoversFromNetworkFailure(t *testing.T) {
	t.Parallel()
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		if requests.Add(1) == 1 {
			hijacker, ok := writer.(http.Hijacker)
			if !ok {
				t.Error("httptest response writer does not support connection hijacking")
				return
			}
			connection, _, err := hijacker.Hijack()
			if err != nil {
				t.Errorf("hijack connection: %v", err)
				return
			}
			_ = connection.Close()
			return
		}
		writer.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(server.Close)

	sleeps := 0
	runner := Runner{
		Client: testClient(t, Linode, "token", server.URL+"/v4/"),
		Logger: slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil)),
		Sleep: func(ctx context.Context, delay time.Duration) error {
			if delay != 5*time.Second {
				t.Errorf("delete retry delay = %s; want 5s", delay)
			}
			sleeps++
			return context.Cause(ctx)
		},
	}
	if err := runner.deleteWithRetry(context.Background(), Config{
		Provider:         Linode,
		DeleteAttempts:   2,
		DeleteRetryDelay: 5 * time.Second,
	}, kindInstances, "301"); err != nil {
		t.Fatalf("deleteWithRetry() error = %v", err)
	}
	if requests.Load() != 2 || sleeps != 1 {
		t.Fatalf("network retry requests = %d, sleeps = %d", requests.Load(), sleeps)
	}
}

func TestSweepFailsClosedWithoutExactOwnership(t *testing.T) {
	t.Parallel()
	client := &Client{provider: Linode}
	runner := Runner{Client: client, Sleep: noSleep}
	tests := []struct {
		name   string
		config Config
	}{
		{name: "missing run", config: Config{Provider: Linode, Target: "linode-wp"}},
		{name: "malformed run", config: Config{Provider: Linode, Target: "linode-wp", RunID: "run-123"}},
		{name: "conflicting scope", config: Config{Provider: Linode, Target: "linode-wp", RunID: "123", AllowAllRuns: true}},
		{name: "wrong provider target", config: Config{Provider: Linode, Target: "digitalocean-isle", RunID: "123"}},
		{name: "wrong config provider", config: Config{Provider: DigitalOcean, Scope: ConfigManagementScope, Target: "ansible-drupal", RunID: "123"}},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if err := runner.Sweep(context.Background(), test.config); err == nil {
				t.Fatal("Sweep() accepted unsafe ownership")
			}
		})
	}
}

func TestExplicitAllRunsSweepRemainsTargetScoped(t *testing.T) {
	t.Parallel()
	api := newFakeProviderAPI(t, Linode, "token", map[resourceKind][]fakeResource{
		kindInstances: {
			{ID: "301", Tags: []string{"cloud-compose-smoke", "linode-wp", "gha-run-111"}},
			{ID: "302", Tags: []string{"cloud-compose-smoke", "linode-wp", "gha-run-222"}},
			{ID: "303", Tags: []string{"cloud-compose-smoke", "linode-drupal", "gha-run-111"}},
		},
	})
	runner := Runner{Client: api.Client(t), Sleep: noSleep}
	if err := runner.Sweep(context.Background(), fastConfig(Config{
		Provider:     Linode,
		Target:       "linode-wp",
		AllowAllRuns: true,
	})); err != nil {
		t.Fatalf("Sweep() error = %v", err)
	}
	if got := api.Deletions(); !slices.Equal(got, []string{"instances/301", "instances/302"}) {
		t.Fatalf("deletions = %q", got)
	}
}

func TestSweepResidualVerificationIsRetriedAndBounded(t *testing.T) {
	t.Parallel()
	owned := fakeResource{ID: "201", Name: "cc-do-isle-123456789-a1b2c3-cloud-compose"}
	tests := []struct {
		name             string
		retainedListings int
		verifyAttempts   int
		wantErr          bool
		wantSleeps       int
	}{
		{name: "eventual consistency clears", retainedListings: 2, verifyAttempts: 3, wantSleeps: 2},
		{name: "persistent residual fails", retainedListings: 20, verifyAttempts: 3, wantErr: true, wantSleeps: 2},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			api := newFakeProviderAPI(t, DigitalOcean, "token", map[resourceKind][]fakeResource{
				kindFirewalls: {owned},
			})
			api.RetainAfterDelete(kindFirewalls, owned.ID, test.retainedListings)
			delays := []time.Duration{}
			runner := Runner{
				Client: api.Client(t),
				Logger: slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil)),
				Sleep: func(ctx context.Context, delay time.Duration) error {
					delays = append(delays, delay)
					return context.Cause(ctx)
				},
			}
			config := fastConfig(Config{
				Provider: DigitalOcean,
				Target:   "digitalocean-isle",
				RunID:    "123456789",
			})
			config.VerifyAttempts = test.verifyAttempts
			config.VerifyRetryDelay = 9 * time.Second
			err := runner.Sweep(context.Background(), config)
			if (err != nil) != test.wantErr {
				t.Fatalf("Sweep() error = %v; wantErr %t", err, test.wantErr)
			}
			if got := api.Deletions(); !slices.Equal(got, []string{"firewalls/201"}) {
				t.Fatalf("deletions = %q", got)
			}
			if len(delays) != test.wantSleeps {
				t.Fatalf("verification sleeps = %v; want %d", delays, test.wantSleeps)
			}
			for _, delay := range delays {
				if delay != 9*time.Second {
					t.Errorf("verification delay = %s; want 9s", delay)
				}
			}
		})
	}
}

func fastConfig(config Config) Config {
	config.DeleteAttempts = 2
	config.DeleteRetryDelay = time.Nanosecond
	config.ListAttempts = 2
	config.ListRetryDelay = time.Nanosecond
	config.VerifyAttempts = 2
	config.VerifyRetryDelay = time.Nanosecond
	config.ComputeSettleDelay = time.Nanosecond
	return config
}

func paginatedTestRoute(provider Provider, requestPath string) (resourceKind, string, bool) {
	prefix := "/v2/"
	if provider == Linode {
		prefix = "/v4/"
	}
	path := strings.TrimPrefix(requestPath, prefix)
	for _, kind := range resourceKinds(provider) {
		list, _ := listPath(provider, kind)
		list = strings.Split(list, "?")[0]
		if path == list {
			return kind, "", true
		}
		deletePath, _ := deletePrefix(provider, kind)
		if strings.HasPrefix(path, deletePath) && !strings.Contains(strings.TrimPrefix(path, deletePath), "/") {
			return kind, strings.TrimPrefix(path, deletePath), true
		}
	}
	return "", "", false
}

func writeEmptyProviderPage(writer http.ResponseWriter, provider Provider, kind resourceKind) {
	writeProviderPage(writer, provider, kind, 1, 1, 0, nil, "")
}

func writeProviderPage(writer http.ResponseWriter, provider Provider, kind resourceKind, page, pages, total int, resources []fakeResource, next string) {
	items := make([]string, 0, len(resources))
	for _, candidate := range resources {
		tags := make([]string, 0, len(candidate.Tags))
		for _, tag := range candidate.Tags {
			tags = append(tags, fmt.Sprintf("%q", tag))
		}
		nameField := "name"
		if provider == Linode {
			nameField = "label"
		}
		items = append(items, fmt.Sprintf(`{"id":%q,%q:%q,"tags":[%s]}`, candidate.ID, nameField, candidate.Name, strings.Join(tags, ",")))
	}
	key := string(kind)
	if provider == Linode {
		key = "data"
		_, _ = fmt.Fprintf(writer, `{"%s":[%s],"page":%d,"pages":%d,"results":%d}`, key, strings.Join(items, ","), page, pages, total)
		return
	}
	if next == "" {
		_, _ = fmt.Fprintf(writer, `{"%s":[%s],"meta":{"total":%d}}`, key, strings.Join(items, ","), total)
		return
	}
	_, _ = fmt.Fprintf(writer, `{"%s":[%s],"links":{"pages":{"next":%q}},"meta":{"total":%d}}`, key, strings.Join(items, ","), next, total)
}

func newStatusSequenceServer(t testing.TB, statuses []int, successBody string) (*httptest.Server, *atomic.Int32) {
	t.Helper()
	if len(statuses) == 0 {
		t.Fatal("status sequence must not be empty")
	}
	requests := &atomic.Int32{}
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if got := request.Header.Get("Authorization"); got != "Bearer token" {
			t.Errorf("Authorization header = %q", got)
		}
		index := int(requests.Add(1)) - 1
		if index >= len(statuses) {
			index = len(statuses) - 1
		}
		status := statuses[index]
		writer.WriteHeader(status)
		if status >= http.StatusOK && status < http.StatusMultipleChoices && successBody != "" {
			_, _ = writer.Write([]byte(successBody))
		}
	}))
	t.Cleanup(server.Close)
	return server, requests
}

type fakeResource struct {
	ID           string
	Name         string
	Tags         []string
	DeleteStatus int
}

type fakeProviderAPI struct {
	testing        testing.TB
	provider       Provider
	token          string
	server         *httptest.Server
	mu             sync.Mutex
	resources      map[resourceKind][]fakeResource
	deleted        map[string]bool
	deletions      []string
	listCalls      map[resourceKind]int
	failingLists   map[resourceKind]int
	failingDeletes map[string]int
	retainDeleted  map[string]int
	paths          []string
}

func newFakeProviderAPI(t testing.TB, provider Provider, token string, resources map[resourceKind][]fakeResource) *fakeProviderAPI {
	t.Helper()
	api := &fakeProviderAPI{
		testing:        t,
		provider:       provider,
		token:          token,
		resources:      resources,
		deleted:        map[string]bool{},
		listCalls:      map[resourceKind]int{},
		failingLists:   map[resourceKind]int{},
		failingDeletes: map[string]int{},
		retainDeleted:  map[string]int{},
	}
	api.server = httptest.NewServer(http.HandlerFunc(api.ServeHTTP))
	t.Cleanup(api.server.Close)
	return api
}

func (a *fakeProviderAPI) Client(t testing.TB) *Client {
	t.Helper()
	version := "/v2/"
	if a.provider == Linode {
		version = "/v4/"
	}
	return testClient(t, a.provider, a.token, a.server.URL+version)
}

func (a *fakeProviderAPI) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.paths = append(a.paths, request.URL.RequestURI())
	if got := request.Header.Get("Authorization"); got != "Bearer "+a.token {
		a.testing.Errorf("Authorization header = %q", got)
	}

	kind, id, ok := a.route(request.URL.Path)
	if !ok {
		http.NotFound(writer, request)
		return
	}
	if request.Method == http.MethodDelete {
		for _, candidate := range a.resources[kind] {
			if candidate.ID != id {
				continue
			}
			key := string(kind) + "/" + id
			a.deletions = append(a.deletions, key)
			if a.failingDeletes[key] > 0 {
				a.failingDeletes[key]--
				writer.WriteHeader(http.StatusConflict)
				return
			}
			a.deleted[key] = true
			status := candidate.DeleteStatus
			if status == 0 {
				status = http.StatusNoContent
			}
			writer.WriteHeader(status)
			return
		}
		http.NotFound(writer, request)
		return
	}
	if request.Method != http.MethodGet {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	a.listCalls[kind]++
	if a.failingLists[kind] > 0 {
		a.failingLists[kind]--
		writer.WriteHeader(http.StatusInternalServerError)
		_, _ = writer.Write([]byte("provider failure containing " + a.token))
		return
	}

	visible := make([]fakeResource, 0, len(a.resources[kind]))
	for _, candidate := range a.resources[kind] {
		key := string(kind) + "/" + candidate.ID
		if a.deleted[key] {
			if a.retainDeleted[key] <= 0 {
				continue
			}
			a.retainDeleted[key]--
		}
		visible = append(visible, candidate)
	}
	writer.Header().Set("Content-Type", "application/json")
	_, _ = fmt.Fprint(writer, a.response(kind, visible))
}

func (a *fakeProviderAPI) route(path string) (resourceKind, string, bool) {
	prefix := "/v2/"
	if a.provider == Linode {
		prefix = "/v4/"
	}
	path = strings.TrimPrefix(path, prefix)
	for _, kind := range resourceKinds(a.provider) {
		list, _ := listPath(a.provider, kind)
		list = strings.Split(list, "?")[0]
		if path == list {
			return kind, "", true
		}
		deletePath, _ := deletePrefix(a.provider, kind)
		if strings.HasPrefix(path, deletePath) && !strings.Contains(strings.TrimPrefix(path, deletePath), "/") {
			return kind, strings.TrimPrefix(path, deletePath), true
		}
	}
	return "", "", false
}

func (a *fakeProviderAPI) response(kind resourceKind, resources []fakeResource) string {
	items := make([]string, 0, len(resources))
	for _, candidate := range resources {
		tags := make([]string, 0, len(candidate.Tags))
		for _, tag := range candidate.Tags {
			tags = append(tags, fmt.Sprintf("%q", tag))
		}
		nameField := "name"
		if a.provider == Linode {
			nameField = "label"
		}
		items = append(items, fmt.Sprintf(`{"id":%q,%q:%q,"tags":[%s]}`, candidate.ID, nameField, candidate.Name, strings.Join(tags, ",")))
	}
	key := string(kind)
	if a.provider == Linode {
		key = "data"
		return fmt.Sprintf(`{"%s":[%s],"page":1,"pages":1,"results":%d}`, key, strings.Join(items, ","), len(items))
	}
	return fmt.Sprintf(`{"%s":[%s],"meta":{"total":%d}}`, key, strings.Join(items, ","), len(items))
}

func (a *fakeProviderAPI) Deletions() []string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return slices.Clone(a.deletions)
}

func (a *fakeProviderAPI) FailLists(kind resourceKind, count int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.failingLists[kind] = count
}

func (a *fakeProviderAPI) FailDeletes(kind resourceKind, id string, count int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.failingDeletes[string(kind)+"/"+id] = count
}

func (a *fakeProviderAPI) RetainAfterDelete(kind resourceKind, id string, listCount int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.retainDeleted[string(kind)+"/"+id] = listCount
}

func (a *fakeProviderAPI) ListCalls(kind resourceKind) int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.listCalls[kind]
}

func (a *fakeProviderAPI) AssertTokenNeverAppearedInPath(t testing.TB) {
	t.Helper()
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, path := range a.paths {
		if strings.Contains(path, a.token) {
			t.Fatalf("provider token appeared in request path %q", path)
		}
	}
}
