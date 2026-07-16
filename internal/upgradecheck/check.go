// Package upgradecheck validates the Terraform plan and state transition used
// by the hosted GCP upgrade smoke test.
package upgradecheck

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"slices"
	"strings"
)

const resourcePrefix = "module.app.module.gcp[0]"

var (
	dataDiskAddress   = resourcePrefix + ".google_compute_disk.data"
	dockerDiskAddress = resourcePrefix + ".google_compute_disk.docker-volumes"
	bootDiskAddress   = resourcePrefix + ".google_compute_disk.boot"
	vmAddress         = resourcePrefix + ".google_compute_instance.cloud-compose"

	legacyStartAddress           = resourcePrefix + ".google_project_iam_member.gce-start[0]"
	legacySuspendAddress         = resourcePrefix + ".google_project_iam_member.gce-suspend"
	legacyGSAUserAddress         = resourcePrefix + ".google_service_account_iam_member.gsa-user"
	legacyVMTokenCreatorAddress  = resourcePrefix + ".google_service_account_iam_member.token-creator"
	legacyAppTokenCreatorAddress = resourcePrefix + ".google_service_account_iam_member.self_jwt_signer_policy"
	conditionalAppTokenAddress   = resourcePrefix + ".google_service_account_iam_member.vault_agent_jwt_signer_policy[0]"
	scopedStartAddress           = resourcePrefix + ".google_compute_instance_iam_member.gce-start[0]"
	scopedSuspendAddress         = resourcePrefix + ".google_compute_instance_iam_member.gce-suspend[0]"
)

type addressMove struct {
	previous string
	current  string
}

var preservedMoves = []addressMove{
	{
		previous: resourcePrefix + ".google_service_account.internal-services",
		current:  resourcePrefix + ".google_service_account.internal-services[0]",
	},
	{
		previous: resourcePrefix + ".google_service_account_iam_member.internal-services-keys",
		current:  resourcePrefix + ".google_service_account_iam_member.internal-services-keys[0]",
	},
	{
		previous: resourcePrefix + ".google_project_iam_member.stackdriver",
		current:  resourcePrefix + ".google_project_iam_member.stackdriver[0]",
	},
	{
		previous: resourcePrefix + ".google_service_account_iam_member.app-keys",
		current:  resourcePrefix + ".google_service_account_iam_member.app-keys[0]",
	},
}

var removedLegacyBindings = []addressMove{
	{previous: legacyStartAddress, current: legacyStartAddress},
	{previous: legacySuspendAddress, current: legacySuspendAddress},
	{previous: legacyGSAUserAddress, current: legacyGSAUserAddress},
	{previous: legacyVMTokenCreatorAddress, current: legacyVMTokenCreatorAddress},
	{previous: legacyAppTokenCreatorAddress, current: conditionalAppTokenAddress},
}

type plan struct {
	FormatVersion   json.RawMessage `json:"format_version"`
	ResourceChanges json.RawMessage `json:"resource_changes"`
}

type resourceChange struct {
	Address         string `json:"address"`
	PreviousAddress string `json:"previous_address"`
	Mode            string `json:"mode"`
	Change          struct {
		Actions []string `json:"actions"`
	} `json:"change"`
}

type stateDocument struct {
	Values struct {
		RootModule stateModule `json:"root_module"`
	} `json:"values"`
}

type stateModule struct {
	Resources    []stateResource `json:"resources"`
	ChildModules []stateModule   `json:"child_modules"`
}

type stateResource struct {
	Address string                     `json:"address"`
	Values  map[string]json.RawMessage `json:"values"`
}

type identitySource struct {
	key       string
	address   string
	attribute string
}

// ValidatePlan verifies that an upgrade plan preserves durable resources,
// performs only the expected replacements and removes the legacy IAM grants.
func ValidatePlan(reader io.Reader) error {
	if reader == nil {
		return errors.New("plan reader is required")
	}

	decoder := json.NewDecoder(reader)
	var document plan
	if err := decoder.Decode(&document); err != nil {
		return fmt.Errorf("decode Terraform plan JSON: %w", err)
	}
	if err := requireEOF(decoder); err != nil {
		return err
	}
	if len(document.FormatVersion) == 0 || string(document.FormatVersion) == "null" {
		return errors.New("Terraform plan JSON is missing format_version")
	}

	var formatVersion string
	if err := json.Unmarshal(document.FormatVersion, &formatVersion); err != nil || strings.TrimSpace(formatVersion) == "" {
		return errors.New("Terraform plan JSON has an invalid format_version")
	}
	if len(document.ResourceChanges) == 0 || string(document.ResourceChanges) == "null" {
		return errors.New("Terraform plan JSON is missing resource_changes")
	}

	var changes []resourceChange
	if err := json.Unmarshal(document.ResourceChanges, &changes); err != nil {
		return fmt.Errorf("decode Terraform resource_changes: %w", err)
	}

	for _, move := range preservedMoves {
		if !anyChange(changes, func(change resourceChange) bool {
			return change.Address == move.current &&
				change.PreviousAddress == move.previous &&
				!slices.Contains(change.Change.Actions, "delete")
		}) {
			return fmt.Errorf("plan did not preserve moved resource %s -> %s", move.previous, move.current)
		}
	}

	for _, address := range []string{dataDiskAddress, dockerDiskAddress} {
		if !anyChange(changes, func(change resourceChange) bool {
			return change.Address == address && slices.Equal(change.Change.Actions, []string{"no-op"})
		}) {
			return fmt.Errorf("persistent disk was not a no-op in the upgrade plan: %s", address)
		}
	}

	for _, removal := range removedLegacyBindings {
		if !anyChange(changes, func(change resourceChange) bool {
			return change.Address == removal.current && slices.Equal(change.Change.Actions, []string{"delete"})
		}) {
			return fmt.Errorf("upgrade plan did not remove the legacy over-broad IAM binding: %s", removal.current)
		}
		if removal.previous != removal.current && !anyChange(changes, func(change resourceChange) bool {
			return change.Address == removal.current && change.PreviousAddress == removal.previous
		}) {
			return fmt.Errorf("plan did not preserve moved-resource provenance before removing %s", removal.previous)
		}
	}

	for _, address := range []string{scopedStartAddress, scopedSuspendAddress} {
		if !anyChange(changes, func(change resourceChange) bool {
			return change.Address == address && slices.Equal(change.Change.Actions, []string{"create"})
		}) {
			return fmt.Errorf("upgrade plan did not create the instance-scoped power binding: %s", address)
		}
	}

	expectedManagedDeletions := []string{
		bootDiskAddress,
		vmAddress,
		legacyStartAddress,
		legacySuspendAddress,
		legacyGSAUserAddress,
		legacyVMTokenCreatorAddress,
		conditionalAppTokenAddress,
	}
	slices.Sort(expectedManagedDeletions)
	var actualManagedDeletions []string

	for _, change := range changes {
		if change.Mode == "data" {
			continue
		}
		if slices.Contains(change.Change.Actions, "delete") {
			actualManagedDeletions = append(actualManagedDeletions, change.Address)
		}

		switch change.Address {
		case bootDiskAddress, vmAddress:
			if !isReplacement(change.Change.Actions) {
				return fmt.Errorf("expected replacement action for %s", change.Address)
			}
		case legacyStartAddress,
			legacySuspendAddress,
			legacyGSAUserAddress,
			legacyVMTokenCreatorAddress,
			conditionalAppTokenAddress:
			if !slices.Equal(change.Change.Actions, []string{"delete"}) {
				return fmt.Errorf("expected delete-only action for %s", change.Address)
			}
		default:
			if slices.Contains(change.Change.Actions, "delete") {
				return fmt.Errorf("upgrade plan contained an unexpected managed-resource deletion: %s", change.Address)
			}
		}
	}

	slices.Sort(actualManagedDeletions)
	if !slices.Equal(actualManagedDeletions, expectedManagedDeletions) {
		return fmt.Errorf(
			"upgrade plan managed-resource deletions differ: got %v, want %v",
			actualManagedDeletions,
			expectedManagedDeletions,
		)
	}
	return nil
}

// CaptureIDs extracts the immutable resource identities needed to compare the
// baseline ("old") and upgraded ("new") Terraform states.
func CaptureIDs(reader io.Reader, phase string) (map[string]string, error) {
	if reader == nil {
		return nil, errors.New("Terraform state reader is required")
	}

	var phaseSources []identitySource
	switch strings.ToLower(strings.TrimSpace(phase)) {
	case "old":
		phaseSources = []identitySource{
			{key: "internal_service_account", address: preservedMoves[0].previous, attribute: "id"},
			{key: "internal_service_keys", address: preservedMoves[1].previous, attribute: "id"},
			{key: "stackdriver", address: preservedMoves[2].previous, attribute: "id"},
			{key: "app_key_admin", address: preservedMoves[3].previous, attribute: "id"},
			{key: "legacy_start", address: legacyStartAddress, attribute: "id"},
			{key: "legacy_suspend", address: legacySuspendAddress, attribute: "id"},
		}
	case "new":
		phaseSources = []identitySource{
			{key: "internal_service_account", address: preservedMoves[0].current, attribute: "id"},
			{key: "internal_service_keys", address: preservedMoves[1].current, attribute: "id"},
			{key: "stackdriver", address: preservedMoves[2].current, attribute: "id"},
			{key: "app_key_admin", address: preservedMoves[3].current, attribute: "id"},
			{key: "scoped_start", address: scopedStartAddress, attribute: "id"},
			{key: "scoped_suspend", address: scopedSuspendAddress, attribute: "id"},
		}
	default:
		return nil, fmt.Errorf("unsupported state-capture phase %q", phase)
	}

	decoder := json.NewDecoder(reader)
	var document stateDocument
	if err := decoder.Decode(&document); err != nil {
		return nil, fmt.Errorf("decode Terraform state JSON: %w", err)
	}
	if err := requireEOF(decoder); err != nil {
		return nil, err
	}

	resources := make(map[string]stateResource)
	if err := indexStateModule(document.Values.RootModule, resources); err != nil {
		return nil, err
	}
	sources := append([]identitySource{
		{key: "data_disk", address: dataDiskAddress, attribute: "id"},
		{key: "docker_disk", address: dockerDiskAddress, attribute: "id"},
		{key: "boot_disk", address: bootDiskAddress, attribute: "disk_id"},
		{key: "vm", address: vmAddress, attribute: "instance_id"},
	}, phaseSources...)

	identities := make(map[string]string, len(sources))
	for _, source := range sources {
		resource, ok := resources[source.address]
		if !ok {
			return nil, fmt.Errorf("state did not contain resource %s", source.address)
		}
		raw, ok := resource.Values[source.attribute]
		if !ok {
			return nil, fmt.Errorf("state did not expose %s for %s", source.attribute, source.address)
		}
		var value string
		if err := json.Unmarshal(raw, &value); err != nil || strings.TrimSpace(value) == "" {
			return nil, fmt.Errorf("state did not expose a non-empty string %s for %s", source.attribute, source.address)
		}
		identities[source.key] = value
	}
	return identities, nil
}

// ValidateTransition verifies immutable resource identities and Terraform state
// addresses before and after the hosted GCP upgrade.
func ValidateTransition(oldIDsReader, newIDsReader, oldStateReader, newStateReader io.Reader) error {
	oldIDs, err := decodeIDs(oldIDsReader)
	if err != nil {
		return fmt.Errorf("decode baseline resource identities: %w", err)
	}
	newIDs, err := decodeIDs(newIDsReader)
	if err != nil {
		return fmt.Errorf("decode upgraded resource identities: %w", err)
	}

	for _, key := range []string{
		"data_disk",
		"docker_disk",
		"internal_service_account",
		"internal_service_keys",
		"stackdriver",
		"app_key_admin",
	} {
		oldValue, err := requiredID(oldIDs, key)
		if err != nil {
			return fmt.Errorf("baseline resource identity %s: %w", key, err)
		}
		newValue, err := requiredID(newIDs, key)
		if err != nil {
			return fmt.Errorf("upgraded resource identity %s: %w", key, err)
		}
		if oldValue != newValue {
			return fmt.Errorf("resource identity changed across the upgrade: %s", key)
		}
	}

	for _, key := range []string{"boot_disk", "vm"} {
		oldValue, err := requiredID(oldIDs, key)
		if err != nil {
			return fmt.Errorf("baseline resource identity %s: %w", key, err)
		}
		newValue, err := requiredID(newIDs, key)
		if err != nil {
			return fmt.Errorf("upgraded resource identity %s: %w", key, err)
		}
		if oldValue == newValue {
			return fmt.Errorf("expected replacement did not change resource identity: %s", key)
		}
	}

	for _, key := range []string{"legacy_start", "legacy_suspend"} {
		if _, err := requiredID(oldIDs, key); err != nil {
			return fmt.Errorf("baseline state did not capture the legacy project-wide power binding %s: %w", key, err)
		}
	}
	for _, key := range []string{"scoped_start", "scoped_suspend"} {
		if _, err := requiredID(newIDs, key); err != nil {
			return fmt.Errorf("upgraded state did not capture the instance-scoped power binding %s: %w", key, err)
		}
	}

	oldState, err := decodeStateList(oldStateReader)
	if err != nil {
		return fmt.Errorf("decode baseline state list: %w", err)
	}
	newState, err := decodeStateList(newStateReader)
	if err != nil {
		return fmt.Errorf("decode upgraded state list: %w", err)
	}

	for _, move := range preservedMoves {
		if !oldState[move.previous] {
			return fmt.Errorf("baseline state did not contain expected legacy address: %s", move.previous)
		}
		if newState[move.previous] {
			return fmt.Errorf("upgraded state retained legacy address: %s", move.previous)
		}
		if !newState[move.current] {
			return fmt.Errorf("upgraded state did not contain moved address: %s", move.current)
		}
	}

	for _, removal := range removedLegacyBindings {
		if !oldState[removal.previous] {
			return fmt.Errorf("baseline state did not contain expected legacy IAM binding: %s", removal.previous)
		}
		if newState[removal.previous] || newState[removal.current] {
			return fmt.Errorf("upgraded state retained legacy IAM binding: %s", removal.previous)
		}
	}

	for _, address := range []string{scopedStartAddress, scopedSuspendAddress} {
		if oldState[address] {
			return fmt.Errorf("baseline state unexpectedly contained current instance-scoped power binding: %s", address)
		}
		if !newState[address] {
			return fmt.Errorf("upgraded state did not contain instance-scoped power binding: %s", address)
		}
	}
	return nil
}

func decodeIDs(reader io.Reader) (map[string]json.RawMessage, error) {
	if reader == nil {
		return nil, errors.New("resource identity reader is required")
	}
	decoder := json.NewDecoder(reader)
	var values map[string]json.RawMessage
	if err := decoder.Decode(&values); err != nil {
		return nil, err
	}
	if err := requireEOF(decoder); err != nil {
		return nil, err
	}
	if values == nil {
		return nil, errors.New("resource identities must be a JSON object")
	}
	return values, nil
}

func requiredID(values map[string]json.RawMessage, key string) (string, error) {
	raw, ok := values[key]
	if !ok {
		return "", errors.New("value is missing")
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", errors.New("value must be a string")
	}
	if strings.TrimSpace(value) == "" {
		return "", errors.New("value must not be empty")
	}
	return value, nil
}

func decodeStateList(reader io.Reader) (map[string]bool, error) {
	if reader == nil {
		return nil, errors.New("state list reader is required")
	}
	addresses := make(map[string]bool)
	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		address := strings.TrimSpace(scanner.Text())
		if address != "" {
			addresses[address] = true
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return addresses, nil
}

func indexStateModule(module stateModule, resources map[string]stateResource) error {
	for _, resource := range module.Resources {
		if strings.TrimSpace(resource.Address) == "" {
			return errors.New("Terraform state contains a resource without an address")
		}
		if _, exists := resources[resource.Address]; exists {
			return fmt.Errorf("Terraform state contains duplicate resource address %s", resource.Address)
		}
		resources[resource.Address] = resource
	}
	for _, child := range module.ChildModules {
		if err := indexStateModule(child, resources); err != nil {
			return err
		}
	}
	return nil
}

func anyChange(changes []resourceChange, predicate func(resourceChange) bool) bool {
	for _, change := range changes {
		if predicate(change) {
			return true
		}
	}
	return false
}

func isReplacement(actions []string) bool {
	return slices.Equal(actions, []string{"delete", "create"}) ||
		slices.Equal(actions, []string{"create", "delete"})
}

func requireEOF(decoder *json.Decoder) error {
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("JSON input contains more than one value")
		}
		return fmt.Errorf("decode trailing JSON: %w", err)
	}
	return nil
}
