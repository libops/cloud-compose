// Package runnamespace encodes GitHub Actions run IDs into fixed-width GCP
// resource-name namespaces.
package runnamespace

import (
	"errors"
	"strconv"
	"strings"
)

const (
	// Width is the number of base36 characters reserved in GCP smoke names.
	Width   = 9
	maxBits = 44
)

// Encode converts a canonical decimal GitHub Actions run ID into a
// fixed-width, lowercase base36 namespace. The 44-bit limit guarantees that
// the result fits Width characters.
func Encode(runID string) (string, error) {
	value, err := strconv.ParseUint(runID, 10, maxBits)
	if err != nil || strconv.FormatUint(value, 10) != runID {
		return "", errors.New("run ID must be a canonical decimal value no larger than 44 bits")
	}

	encoded := strconv.FormatUint(value, 36)
	return strings.Repeat("0", Width-len(encoded)) + encoded, nil
}
