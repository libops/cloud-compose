// Package providercleanup removes DigitalOcean and Linode resources owned by
// a cloud-compose smoke run.
package providercleanup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	defaultRequestTimeout = 45 * time.Second
	maxResponseBytes      = 4 << 20
	maximumListPages      = 100
)

var validResourceID = regexp.MustCompile(`^[A-Za-z0-9-]+$`)

// Provider identifies a supported hosted infrastructure API.
type Provider string

const (
	// DigitalOcean identifies the DigitalOcean v2 API.
	DigitalOcean Provider = "digitalocean"
	// Linode identifies the Linode v4 API.
	Linode Provider = "linode"
)

// ParseProvider validates a provider name.
func ParseProvider(value string) (Provider, error) {
	provider := Provider(strings.ToLower(strings.TrimSpace(value)))
	switch provider {
	case DigitalOcean, Linode:
		return provider, nil
	default:
		return "", fmt.Errorf("unsupported cleanup provider %q", value)
	}
}

// TokenEnvironment returns the environment variable used for a provider API
// token.
func TokenEnvironment(provider Provider) (string, error) {
	switch provider {
	case DigitalOcean:
		return "DIGITALOCEAN_TOKEN", nil
	case Linode:
		return "LINODE_TOKEN", nil
	default:
		return "", fmt.Errorf("unsupported cleanup provider %q", provider)
	}
}

type resourceKind string

const (
	kindFirewalls resourceKind = "firewalls"
	kindDroplets  resourceKind = "droplets"
	kindInstances resourceKind = "instances"
	kindVolumes   resourceKind = "volumes"
)

type resource struct {
	ID   string
	Name string
	Tags []string
}

type resourceID string

func (id *resourceID) UnmarshalJSON(data []byte) error {
	var value string
	if len(data) > 0 && data[0] == '"' {
		if err := json.Unmarshal(data, &value); err != nil {
			return fmt.Errorf("decode resource ID: %w", err)
		}
	} else {
		value = string(data)
	}
	if !validResourceID.MatchString(value) {
		return errors.New("provider returned an invalid resource ID")
	}
	*id = resourceID(value)
	return nil
}

type apiResource struct {
	ID    resourceID `json:"id"`
	Name  string     `json:"name"`
	Label string     `json:"label"`
	Tags  []string   `json:"tags"`
}

type digitalOceanFirewallsResponse struct {
	Firewalls *[]apiResource     `json:"firewalls"`
	Links     *digitalOceanLinks `json:"links"`
	Meta      *digitalOceanMeta  `json:"meta"`
}

type digitalOceanDropletsResponse struct {
	Droplets *[]apiResource     `json:"droplets"`
	Links    *digitalOceanLinks `json:"links"`
	Meta     *digitalOceanMeta  `json:"meta"`
}

type digitalOceanVolumesResponse struct {
	Volumes *[]apiResource     `json:"volumes"`
	Links   *digitalOceanLinks `json:"links"`
	Meta    *digitalOceanMeta  `json:"meta"`
}

type linodeResponse struct {
	Data    *[]apiResource `json:"data"`
	Page    *int           `json:"page"`
	Pages   *int           `json:"pages"`
	Results *int           `json:"results"`
}

type digitalOceanMeta struct {
	Total *int `json:"total"`
}

type digitalOceanLinks struct {
	Pages *digitalOceanPageLinks `json:"pages"`
}

type digitalOceanPageLinks struct {
	Next *string `json:"next"`
}

type resourcePage struct {
	resources        []resource
	digitalOceanNext *string
	linodePage       int
	linodePages      int
	declaredTotal    int
}

// Client performs authenticated provider API requests. Tokens are held only
// in memory and are sent in request headers, never command arguments.
type Client struct {
	provider       Provider
	token          string
	baseURL        *url.URL
	httpClient     *http.Client
	requestTimeout time.Duration
}

// NewClient constructs a provider API client with bounded connect and request
// deadlines.
func NewClient(provider Provider, token string) (*Client, error) {
	var endpoint string
	switch provider {
	case DigitalOcean:
		endpoint = "https://api.digitalocean.com/v2/"
	case Linode:
		endpoint = "https://api.linode.com/v4/"
	default:
		return nil, fmt.Errorf("unsupported cleanup provider %q", provider)
	}
	if strings.TrimSpace(token) == "" {
		name, _ := TokenEnvironment(provider)
		return nil, fmt.Errorf("%s is required", name)
	}

	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.DialContext = (&net.Dialer{
		Timeout:   10 * time.Second,
		KeepAlive: 30 * time.Second,
	}).DialContext
	transport.TLSHandshakeTimeout = 10 * time.Second
	transport.ResponseHeaderTimeout = 30 * time.Second

	return newClient(provider, token, endpoint, &http.Client{
		Transport: transport,
		Timeout:   defaultRequestTimeout,
	})
}

func newClient(provider Provider, token, endpoint string, httpClient *http.Client) (*Client, error) {
	baseURL, err := url.Parse(endpoint)
	if err != nil {
		return nil, fmt.Errorf("parse provider endpoint: %w", err)
	}
	if baseURL.Scheme != "http" && baseURL.Scheme != "https" {
		return nil, errors.New("provider endpoint must use HTTP or HTTPS")
	}
	if baseURL.Host == "" {
		return nil, errors.New("provider endpoint must include a host")
	}
	if baseURL.Opaque != "" || baseURL.User != nil || baseURL.RawQuery != "" || baseURL.Fragment != "" || baseURL.RawPath != "" {
		return nil, errors.New("provider endpoint must be a plain API base URL")
	}
	if !strings.HasSuffix(baseURL.Path, "/") {
		baseURL.Path += "/"
	}
	if httpClient == nil {
		return nil, errors.New("provider HTTP client is required")
	}
	client := *httpClient
	// Provider API calls are expected to be direct. Refusing redirects prevents
	// an upstream response from forwarding the authorization header to a target
	// that was not validated against the configured API origin.
	client.CheckRedirect = func(_ *http.Request, _ []*http.Request) error {
		return http.ErrUseLastResponse
	}
	return &Client{
		provider:       provider,
		token:          token,
		baseURL:        baseURL,
		httpClient:     &client,
		requestTimeout: defaultRequestTimeout,
	}, nil
}

func (c *Client) list(ctx context.Context, kind resourceKind) ([]resource, error) {
	initialPath, err := listPath(c.provider, kind)
	if err != nil {
		return nil, err
	}
	initialEndpoint, err := c.resolveEndpoint(initialPath)
	if err != nil {
		return nil, err
	}

	nextEndpoint := initialEndpoint
	seenPages := make(map[string]struct{}, maximumListPages)
	seenResources := make(map[string]struct{})
	resources := make([]resource, 0)
	declaredLinodePages := 0
	declaredTotal := -1

	for pageNumber := 1; pageNumber <= maximumListPages; pageNumber++ {
		canonical := canonicalEndpoint(nextEndpoint)
		if _, seen := seenPages[canonical]; seen {
			return nil, fmt.Errorf("%s %s pagination contained a cycle", c.provider, kind)
		}
		seenPages[canonical] = struct{}{}

		body, requestErr := c.requestEndpoint(ctx, http.MethodGet, nextEndpoint)
		if requestErr != nil {
			return nil, requestErr
		}
		page, decodeErr := decodeResourcePage(c.provider, kind, body)
		if decodeErr != nil {
			return nil, decodeErr
		}
		if declaredTotal == -1 {
			declaredTotal = page.declaredTotal
		} else if page.declaredTotal != declaredTotal {
			return nil, fmt.Errorf("%s %s pagination changed its declared result count", c.provider, kind)
		}
		for _, candidate := range page.resources {
			if _, duplicate := seenResources[candidate.ID]; duplicate {
				return nil, fmt.Errorf("%s %s pagination repeated a resource ID", c.provider, kind)
			}
			seenResources[candidate.ID] = struct{}{}
			resources = append(resources, candidate)
		}
		if len(resources) > declaredTotal {
			return nil, fmt.Errorf("%s %s pagination returned more resources than its declared result count", c.provider, kind)
		}

		switch c.provider {
		case DigitalOcean:
			if page.digitalOceanNext == nil {
				if len(resources) != declaredTotal {
					return nil, fmt.Errorf("%s %s pagination ended after %d of %d declared resources", c.provider, kind, len(resources), declaredTotal)
				}
				return resources, nil
			}
			if len(resources) == declaredTotal {
				return nil, fmt.Errorf("%s %s pagination continued after returning its declared result count", c.provider, kind)
			}
			if pageNumber == maximumListPages {
				return nil, fmt.Errorf("%s %s pagination exceeded the %d-page safety limit", c.provider, kind, maximumListPages)
			}
			nextEndpoint, err = c.digitalOceanNextEndpoint(*page.digitalOceanNext, initialEndpoint, pageNumber+1)
			if err != nil {
				return nil, err
			}
		case Linode:
			if page.linodePage != pageNumber {
				return nil, fmt.Errorf("%s %s pagination returned page %d while page %d was requested", c.provider, kind, page.linodePage, pageNumber)
			}
			if declaredLinodePages == 0 {
				declaredLinodePages = page.linodePages
				if declaredLinodePages > maximumListPages {
					return nil, fmt.Errorf("%s %s pagination exceeds the %d-page safety limit", c.provider, kind, maximumListPages)
				}
			} else if page.linodePages != declaredLinodePages {
				return nil, fmt.Errorf("%s %s pagination changed its declared page count", c.provider, kind)
			}
			if pageNumber == declaredLinodePages {
				if len(resources) != declaredTotal {
					return nil, fmt.Errorf("%s %s pagination ended after %d of %d declared resources", c.provider, kind, len(resources), declaredTotal)
				}
				return resources, nil
			}
			nextEndpoint = linodeNextEndpoint(initialEndpoint, pageNumber+1)
		default:
			return nil, fmt.Errorf("unsupported cleanup provider %q", c.provider)
		}
	}
	return nil, fmt.Errorf("%s %s pagination exceeded the %d-page safety limit", c.provider, kind, maximumListPages)
}

func (c *Client) delete(ctx context.Context, kind resourceKind, id string) error {
	if !validResourceID.MatchString(id) {
		return errors.New("refusing to delete an invalid provider resource ID")
	}
	prefix, err := deletePrefix(c.provider, kind)
	if err != nil {
		return err
	}
	_, err = c.request(ctx, http.MethodDelete, prefix+url.PathEscape(id))
	return err
}

func (c *Client) resolveEndpoint(reference string) (*url.URL, error) {
	parsed, err := url.Parse(reference)
	if err != nil || parsed.Opaque != "" || parsed.User != nil || parsed.Fragment != "" {
		return nil, errors.New("construct provider API request")
	}
	endpoint := c.baseURL.ResolveReference(parsed)
	if !strings.EqualFold(endpoint.Scheme, c.baseURL.Scheme) ||
		!strings.EqualFold(endpoint.Host, c.baseURL.Host) ||
		endpoint.User != nil || endpoint.Fragment != "" || endpoint.RawPath != "" {
		return nil, errors.New("provider API request target escaped the configured origin")
	}
	if !strings.HasPrefix(endpoint.Path, c.baseURL.Path) || endpoint.Path == c.baseURL.Path {
		return nil, errors.New("provider API request target escaped the configured base path")
	}
	return endpoint, nil
}

func (c *Client) digitalOceanNextEndpoint(next string, initial *url.URL, expectedPage int) (*url.URL, error) {
	if next == "" || strings.TrimSpace(next) != next {
		return nil, fmt.Errorf("%s pagination returned an invalid next link", c.provider)
	}
	reference, err := url.Parse(next)
	if err != nil || !reference.IsAbs() {
		return nil, fmt.Errorf("%s pagination returned an invalid next link", c.provider)
	}
	endpoint, err := c.resolveEndpoint(next)
	if err != nil {
		return nil, fmt.Errorf("%s pagination returned an unsafe next link", c.provider)
	}
	if endpoint.Path != initial.Path {
		return nil, fmt.Errorf("%s pagination changed the list endpoint", c.provider)
	}
	query, err := url.ParseQuery(endpoint.RawQuery)
	if err != nil {
		return nil, fmt.Errorf("%s pagination next link contained an invalid query", c.provider)
	}
	pages, found := query["page"]
	if !found || len(pages) != 1 {
		return nil, fmt.Errorf("%s pagination next link omitted a single page number", c.provider)
	}
	page, err := strconv.Atoi(pages[0])
	if err != nil || page != expectedPage || pages[0] != strconv.Itoa(expectedPage) {
		return nil, fmt.Errorf("%s pagination next link did not advance to page %d", c.provider, expectedPage)
	}
	initialQuery, err := url.ParseQuery(initial.RawQuery)
	if err != nil {
		return nil, errors.New("construct provider API pagination request")
	}
	expectedQuery := cloneQuery(initialQuery)
	expectedQuery.Set("page", strconv.Itoa(expectedPage))
	if !equalQuerySets(query, expectedQuery) {
		return nil, fmt.Errorf("%s pagination next link changed the exact list query", c.provider)
	}
	return endpoint, nil
}

func cloneQuery(values url.Values) url.Values {
	cloned := make(url.Values, len(values))
	for key, entries := range values {
		cloned[key] = append([]string(nil), entries...)
	}
	return cloned
}

func equalQuerySets(left, right url.Values) bool {
	if len(left) != len(right) {
		return false
	}
	for key, leftValues := range left {
		rightValues, found := right[key]
		if !found || len(leftValues) != len(rightValues) {
			return false
		}
		for index := range leftValues {
			if leftValues[index] != rightValues[index] {
				return false
			}
		}
	}
	return true
}

func linodeNextEndpoint(initial *url.URL, page int) *url.URL {
	next := *initial
	query := next.Query()
	query.Set("page", strconv.Itoa(page))
	next.RawQuery = query.Encode()
	return &next
}

func canonicalEndpoint(endpoint *url.URL) string {
	canonical := *endpoint
	canonical.RawQuery = canonical.Query().Encode()
	canonical.ForceQuery = false
	return canonical.String()
}

func (c *Client) request(ctx context.Context, method, path string) ([]byte, error) {
	endpoint, err := c.resolveEndpoint(path)
	if err != nil {
		return nil, err
	}
	return c.requestEndpoint(ctx, method, endpoint)
}

func (c *Client) requestEndpoint(ctx context.Context, method string, endpoint *url.URL) ([]byte, error) {
	requestTimeout := c.requestTimeout
	if requestTimeout <= 0 {
		requestTimeout = defaultRequestTimeout
	}
	requestContext, cancel := context.WithTimeout(ctx, requestTimeout)
	defer cancel()

	request, err := http.NewRequestWithContext(requestContext, method, endpoint.String(), nil)
	if err != nil {
		return nil, errors.New("construct provider API request")
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Authorization", "Bearer "+c.token)
	request.Header.Set("User-Agent", "libops-cloud-compose-ci")

	response, err := c.httpClient.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, &requestError{
			provider:  c.provider,
			method:    method,
			path:      endpoint.EscapedPath(),
			retryable: true,
			message:   "network request failed or timed out",
		}
	}
	defer response.Body.Close()

	if method == http.MethodDelete && (response.StatusCode == http.StatusNotFound || response.StatusCode == http.StatusGone) {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, maxResponseBytes))
		return nil, nil
	}
	if method == http.MethodGet && response.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, maxResponseBytes))
		return nil, &requestError{
			provider:   c.provider,
			method:     method,
			path:       endpoint.EscapedPath(),
			statusCode: response.StatusCode,
			retryable:  retryableStatus(method, response.StatusCode),
			message:    "unexpected response status",
		}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, maxResponseBytes))
		return nil, &requestError{
			provider:   c.provider,
			method:     method,
			path:       endpoint.EscapedPath(),
			statusCode: response.StatusCode,
			retryable:  retryableStatus(method, response.StatusCode),
			message:    "request rejected",
		}
	}

	body, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes+1))
	if err != nil {
		return nil, &requestError{
			provider:  c.provider,
			method:    method,
			path:      endpoint.EscapedPath(),
			retryable: true,
			message:   "read response failed",
		}
	}
	if len(body) > maxResponseBytes {
		return nil, &requestError{
			provider:  c.provider,
			method:    method,
			path:      endpoint.EscapedPath(),
			retryable: false,
			message:   "response exceeded size limit",
		}
	}
	return body, nil
}

type requestError struct {
	provider   Provider
	method     string
	path       string
	statusCode int
	retryable  bool
	message    string
}

func (e *requestError) Error() string {
	if e.statusCode != 0 {
		return fmt.Sprintf("%s API %s %s returned HTTP %d: %s", e.provider, e.method, e.path, e.statusCode, e.message)
	}
	return fmt.Sprintf("%s API %s %s: %s", e.provider, e.method, e.path, e.message)
}

func retryable(err error) bool {
	var apiError *requestError
	return errors.As(err, &apiError) && apiError.retryable
}

func retryableStatus(method string, status int) bool {
	if status == http.StatusRequestTimeout || status == http.StatusTooEarly || status == http.StatusTooManyRequests || status >= 500 {
		return true
	}
	return method == http.MethodDelete && (status == http.StatusConflict || status == http.StatusLocked)
}

func listPath(provider Provider, kind resourceKind) (string, error) {
	switch provider {
	case DigitalOcean:
		switch kind {
		case kindFirewalls:
			return "firewalls?per_page=200", nil
		case kindDroplets:
			return "droplets?tag_name=cloud-compose-smoke&per_page=200", nil
		case kindVolumes:
			return "volumes?tag_name=cloud-compose-smoke&per_page=200", nil
		}
	case Linode:
		switch kind {
		case kindFirewalls:
			return "networking/firewalls?page_size=500", nil
		case kindInstances:
			return "linode/instances?page_size=500", nil
		case kindVolumes:
			return "volumes?page_size=500", nil
		}
	}
	return "", fmt.Errorf("unsupported %s resource kind %q", provider, kind)
}

func deletePrefix(provider Provider, kind resourceKind) (string, error) {
	switch provider {
	case DigitalOcean:
		switch kind {
		case kindFirewalls:
			return "firewalls/", nil
		case kindDroplets:
			return "droplets/", nil
		case kindVolumes:
			return "volumes/", nil
		}
	case Linode:
		switch kind {
		case kindFirewalls:
			return "networking/firewalls/", nil
		case kindInstances:
			return "linode/instances/", nil
		case kindVolumes:
			return "volumes/", nil
		}
	}
	return "", fmt.Errorf("unsupported %s resource kind %q", provider, kind)
}

func decodeResources(provider Provider, kind resourceKind, body []byte) ([]resource, error) {
	page, err := decodeResourcePage(provider, kind, body)
	if err != nil {
		return nil, err
	}
	return page.resources, nil
}

func decodeResourcePage(provider Provider, kind resourceKind, body []byte) (resourcePage, error) {
	var values *[]apiResource
	page := resourcePage{}
	switch provider {
	case DigitalOcean:
		switch kind {
		case kindFirewalls:
			response := digitalOceanFirewallsResponse{}
			if err := decodeJSON(body, &response); err != nil {
				return resourcePage{}, fmt.Errorf("decode DigitalOcean firewalls response: %w", err)
			}
			values = response.Firewalls
			page.digitalOceanNext = digitalOceanNext(response.Links)
			page.declaredTotal = digitalOceanTotal(response.Meta)
		case kindDroplets:
			response := digitalOceanDropletsResponse{}
			if err := decodeJSON(body, &response); err != nil {
				return resourcePage{}, fmt.Errorf("decode DigitalOcean droplets response: %w", err)
			}
			values = response.Droplets
			page.digitalOceanNext = digitalOceanNext(response.Links)
			page.declaredTotal = digitalOceanTotal(response.Meta)
		case kindVolumes:
			response := digitalOceanVolumesResponse{}
			if err := decodeJSON(body, &response); err != nil {
				return resourcePage{}, fmt.Errorf("decode DigitalOcean volumes response: %w", err)
			}
			values = response.Volumes
			page.digitalOceanNext = digitalOceanNext(response.Links)
			page.declaredTotal = digitalOceanTotal(response.Meta)
		default:
			return resourcePage{}, fmt.Errorf("unsupported %s resource kind %q", provider, kind)
		}
	case Linode:
		response := linodeResponse{}
		if err := decodeJSON(body, &response); err != nil {
			return resourcePage{}, fmt.Errorf("decode Linode %s response: %w", kind, err)
		}
		values = response.Data
		if response.Page == nil || response.Pages == nil || response.Results == nil || *response.Page < 1 || *response.Pages < 1 || *response.Page > *response.Pages || *response.Results < 0 {
			return resourcePage{}, fmt.Errorf("Linode %s response included invalid pagination metadata", kind)
		}
		page.linodePage = *response.Page
		page.linodePages = *response.Pages
		page.declaredTotal = *response.Results
	default:
		return resourcePage{}, fmt.Errorf("unsupported cleanup provider %q", provider)
	}
	if values == nil {
		return resourcePage{}, fmt.Errorf("%s %s response omitted the resource array", provider, kind)
	}
	if page.declaredTotal < 0 {
		return resourcePage{}, fmt.Errorf("%s %s response omitted a valid collection total", provider, kind)
	}

	resources := make([]resource, 0, len(*values))
	for _, value := range *values {
		if !validResourceID.MatchString(string(value.ID)) {
			return resourcePage{}, fmt.Errorf("%s %s response included a missing or invalid resource ID", provider, kind)
		}
		name := value.Name
		if name == "" {
			name = value.Label
		}
		resources = append(resources, resource{
			ID:   string(value.ID),
			Name: name,
			Tags: append([]string(nil), value.Tags...),
		})
	}
	page.resources = resources
	return page, nil
}

func digitalOceanTotal(meta *digitalOceanMeta) int {
	if meta == nil || meta.Total == nil {
		return -1
	}
	return *meta.Total
}

func digitalOceanNext(links *digitalOceanLinks) *string {
	if links == nil || links.Pages == nil {
		return nil
	}
	return links.Pages.Next
}

func decodeJSON(body []byte, destination any) error {
	decoder := json.NewDecoder(bytes.NewReader(body))
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("response contained multiple JSON values")
		}
		return err
	}
	return nil
}
