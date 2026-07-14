package runnamespace

import "testing"

func TestEncode(t *testing.T) {
	t.Parallel()

	for _, test := range []struct {
		name  string
		runID string
		want  string
	}{
		{name: "workflow run", runID: "123456789", want: "00021i3v9"},
		{name: "zero", runID: "0", want: "000000000"},
		{name: "largest 44 bit value", runID: "17592186044415", want: "68hqlcqv3"},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got, err := Encode(test.runID)
			if err != nil {
				t.Fatalf("Encode(%q) error = %v", test.runID, err)
			}
			if got != test.want {
				t.Errorf("Encode(%q) = %q; want %q", test.runID, got, test.want)
			}
		})
	}
}

func TestEncodeRejectsNoncanonicalOrOversizedRunID(t *testing.T) {
	t.Parallel()

	for _, runID := range []string{
		"",
		"00",
		"0123456789",
		"+123",
		"-123",
		"123 ",
		"123_456",
		"contract-run",
		"17592186044416",
	} {
		t.Run(runID, func(t *testing.T) {
			t.Parallel()
			if namespace, err := Encode(runID); err == nil {
				t.Fatalf("Encode(%q) = %q; want an error", runID, namespace)
			}
		})
	}
}
