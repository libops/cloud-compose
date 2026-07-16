package upgradecheck

import (
	"bytes"
	"encoding/json"
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidatePlan(t *testing.T) {
	t.Parallel()

	good := readFixture(t, "good-plan.json")
	tests := []struct {
		name    string
		mutate  func(t *testing.T, plan map[string]any)
		wantErr string
	}{
		{name: "expected upgrade"},
		{
			name: "moved resource loses provenance",
			mutate: func(t *testing.T, plan map[string]any) {
				change := planChange(t, plan, resourcePrefix+".google_project_iam_member.stackdriver[0]")
				delete(change, "previous_address")
			},
			wantErr: "did not preserve moved resource",
		},
		{
			name: "durable disk is replaced",
			mutate: func(t *testing.T, plan map[string]any) {
				setActions(t, planChange(t, plan, dockerDiskAddress), "delete", "create")
			},
			wantErr: "persistent disk was not a no-op",
		},
		{
			name: "unexpected managed resource is deleted",
			mutate: func(_ *testing.T, plan map[string]any) {
				changes := plan["resource_changes"].([]any)
				plan["resource_changes"] = append(changes, map[string]any{
					"address": "module.app.google_compute_disk.unexpected",
					"change":  map[string]any{"actions": []any{"delete"}},
				})
			},
			wantErr: "unexpected managed-resource deletion",
		},
		{
			name: "legacy binding is retained",
			mutate: func(t *testing.T, plan map[string]any) {
				setActions(t, planChange(t, plan, legacyStartAddress), "no-op")
			},
			wantErr: "did not remove the legacy over-broad IAM binding",
		},
		{
			name: "renamed legacy binding loses provenance",
			mutate: func(t *testing.T, plan map[string]any) {
				change := planChange(t, plan, conditionalAppTokenAddress)
				delete(change, "previous_address")
			},
			wantErr: "did not preserve moved-resource provenance",
		},
		{
			name: "scoped binding is missing",
			mutate: func(t *testing.T, plan map[string]any) {
				changes := plan["resource_changes"].([]any)
				filtered := changes[:0]
				for _, raw := range changes {
					change := raw.(map[string]any)
					if change["address"] != scopedSuspendAddress {
						filtered = append(filtered, raw)
					}
				}
				plan["resource_changes"] = filtered
			},
			wantErr: "did not create the instance-scoped power binding",
		},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			var document map[string]any
			if err := json.Unmarshal(good, &document); err != nil {
				t.Fatalf("decode fixture: %v", err)
			}
			if test.mutate != nil {
				test.mutate(t, document)
			}
			encoded, err := json.Marshal(document)
			if err != nil {
				t.Fatalf("encode test plan: %v", err)
			}

			err = ValidatePlan(bytes.NewReader(encoded))
			if test.wantErr == "" {
				if err != nil {
					t.Fatalf("ValidatePlan(): %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), test.wantErr) {
				t.Fatalf("ValidatePlan() error = %v; want %q", err, test.wantErr)
			}
		})
	}
}

func TestValidatePlanRejectsMalformedDocuments(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		input   string
		wantErr string
	}{
		{name: "invalid JSON", input: `{`, wantErr: "decode Terraform plan JSON"},
		{name: "missing format", input: `{"resource_changes":[]}`, wantErr: "missing format_version"},
		{name: "missing changes", input: `{"format_version":"1.2"}`, wantErr: "missing resource_changes"},
		{name: "wrong changes type", input: `{"format_version":"1.2","resource_changes":{}}`, wantErr: "decode Terraform resource_changes"},
		{name: "trailing value", input: `{"format_version":"1.2","resource_changes":[]} {}`, wantErr: "more than one value"},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			err := ValidatePlan(strings.NewReader(test.input))
			if err == nil || !strings.Contains(err.Error(), test.wantErr) {
				t.Fatalf("ValidatePlan() error = %v; want %q", err, test.wantErr)
			}
		})
	}
}

func TestCaptureIDs(t *testing.T) {
	t.Parallel()

	for _, test := range []struct {
		phase         string
		stateFixture  string
		expectFixture string
	}{
		{phase: "old", stateFixture: "old-state.json", expectFixture: "old-ids.json"},
		{phase: "new", stateFixture: "new-state.json", expectFixture: "new-ids.json"},
	} {
		test := test
		t.Run(test.phase, func(t *testing.T) {
			t.Parallel()
			got, err := CaptureIDs(bytes.NewReader(readFixture(t, test.stateFixture)), test.phase)
			if err != nil {
				t.Fatalf("CaptureIDs(): %v", err)
			}

			var want map[string]string
			if err := json.Unmarshal(readFixture(t, test.expectFixture), &want); err != nil {
				t.Fatalf("decode expected identities: %v", err)
			}
			if !maps.Equal(got, want) {
				t.Fatalf("CaptureIDs() = %#v; want %#v", got, want)
			}
		})
	}
}

func TestCaptureIDsRejectsInvalidState(t *testing.T) {
	t.Parallel()

	oldState := readFixture(t, "old-state.json")
	var missingAttribute map[string]any
	if err := json.Unmarshal(oldState, &missingAttribute); err != nil {
		t.Fatalf("decode state fixture: %v", err)
	}
	root := missingAttribute["values"].(map[string]any)["root_module"].(map[string]any)
	resources := root["child_modules"].([]any)[0].(map[string]any)["resources"].([]any)
	for _, raw := range resources {
		resource := raw.(map[string]any)
		if resource["address"] == bootDiskAddress {
			delete(resource["values"].(map[string]any), "disk_id")
		}
	}
	encodedMissingAttribute, err := json.Marshal(missingAttribute)
	if err != nil {
		t.Fatalf("encode invalid state: %v", err)
	}

	tests := []struct {
		name    string
		phase   string
		input   []byte
		wantErr string
	}{
		{name: "unknown phase", phase: "future", input: oldState, wantErr: "unsupported state-capture phase"},
		{name: "malformed state", phase: "old", input: []byte(`{`), wantErr: "decode Terraform state JSON"},
		{name: "missing immutable attribute", phase: "old", input: encodedMissingAttribute, wantErr: "did not expose disk_id"},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			_, err := CaptureIDs(bytes.NewReader(test.input), test.phase)
			if err == nil || !strings.Contains(err.Error(), test.wantErr) {
				t.Fatalf("CaptureIDs() error = %v; want %q", err, test.wantErr)
			}
		})
	}
}

func TestValidateTransition(t *testing.T) {
	t.Parallel()

	oldIDs := readFixture(t, "old-ids.json")
	newIDs := readFixture(t, "new-ids.json")
	oldState := readFixture(t, "old-state.txt")
	newState := readFixture(t, "new-state.txt")

	tests := []struct {
		name           string
		mutateOldIDs   func(map[string]any)
		mutateNewIDs   func(map[string]any)
		mutateOldState func(string) string
		mutateNewState func(string) string
		wantErr        string
	}{
		{name: "expected transition"},
		{
			name: "durable disk identity changes",
			mutateNewIDs: func(values map[string]any) {
				values["docker_disk"] = "docker-replaced"
			},
			wantErr: "resource identity changed",
		},
		{
			name: "boot disk is not replaced",
			mutateNewIDs: func(values map[string]any) {
				values["boot_disk"] = "boot-old"
			},
			wantErr: "expected replacement did not change",
		},
		{
			name: "legacy address remains",
			mutateNewState: func(value string) string {
				return value + resourcePrefix + ".google_service_account.internal-services\n"
			},
			wantErr: "retained legacy address",
		},
		{
			name: "legacy power binding remains",
			mutateNewState: func(value string) string {
				return value + legacyStartAddress + "\n"
			},
			wantErr: "retained legacy IAM binding",
		},
		{
			name: "scoped power binding is missing",
			mutateNewState: func(value string) string {
				return strings.ReplaceAll(value, scopedSuspendAddress+"\n", "")
			},
			wantErr: "did not contain instance-scoped power binding",
		},
		{
			name: "baseline legacy binding is missing",
			mutateOldState: func(value string) string {
				return strings.ReplaceAll(value, legacySuspendAddress+"\n", "")
			},
			wantErr: "did not contain expected legacy IAM binding",
		},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			oldDocument := decodeObject(t, oldIDs)
			newDocument := decodeObject(t, newIDs)
			if test.mutateOldIDs != nil {
				test.mutateOldIDs(oldDocument)
			}
			if test.mutateNewIDs != nil {
				test.mutateNewIDs(newDocument)
			}
			oldStateValue := string(oldState)
			newStateValue := string(newState)
			if test.mutateOldState != nil {
				oldStateValue = test.mutateOldState(oldStateValue)
			}
			if test.mutateNewState != nil {
				newStateValue = test.mutateNewState(newStateValue)
			}

			err := ValidateTransition(
				bytes.NewReader(encodeObject(t, oldDocument)),
				bytes.NewReader(encodeObject(t, newDocument)),
				strings.NewReader(oldStateValue),
				strings.NewReader(newStateValue),
			)
			if test.wantErr == "" {
				if err != nil {
					t.Fatalf("ValidateTransition(): %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), test.wantErr) {
				t.Fatalf("ValidateTransition() error = %v; want %q", err, test.wantErr)
			}
		})
	}
}

func readFixture(t testing.TB, name string) []byte {
	t.Helper()
	content, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return content
}

func decodeObject(t testing.TB, content []byte) map[string]any {
	t.Helper()
	var value map[string]any
	if err := json.Unmarshal(content, &value); err != nil {
		t.Fatalf("decode JSON object: %v", err)
	}
	return value
}

func encodeObject(t testing.TB, value map[string]any) []byte {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("encode JSON object: %v", err)
	}
	return encoded
}

func planChange(t testing.TB, plan map[string]any, address string) map[string]any {
	t.Helper()
	changes, ok := plan["resource_changes"].([]any)
	if !ok {
		t.Fatal("resource_changes fixture is not an array")
	}
	for _, raw := range changes {
		change, ok := raw.(map[string]any)
		if ok && change["address"] == address {
			return change
		}
	}
	t.Fatalf("plan fixture does not contain %s", address)
	return nil
}

func setActions(t testing.TB, change map[string]any, actions ...string) {
	t.Helper()
	changeBlock, ok := change["change"].(map[string]any)
	if !ok {
		t.Fatal("plan fixture change block is not an object")
	}
	values := make([]any, len(actions))
	for index, action := range actions {
		values[index] = action
	}
	changeBlock["actions"] = values
}
