package flutter

import (
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// PubspecLock represents the structure of a pubspec.lock file.
type PubspecLock struct {
	Packages map[string]LockPackage `yaml:"packages"`
	SDKs     map[string]string      `yaml:"sdks"`
}

// LockPackage represents a single entry under a lock's `packages:` key.
//
// Description stays an interface{} because pub writes it either as a nested
// map (hosted, path, git) or as a bare scalar (`description: flutter` for sdk
// sources). yaml.v3 decodes those to map[string]interface{} and string
// respectively.
type LockPackage struct {
	Dependency  string      `yaml:"dependency"`
	Description interface{} `yaml:"description"`
	Source      string      `yaml:"source"`
	Version     string      `yaml:"version"`
}

// PubspecYaml represents the structure of a pubspec.yaml file
type PubspecYaml struct {
	Name         string                 `yaml:"name"`
	Dependencies map[string]interface{} `yaml:"dependencies"`
	Environment  map[string]interface{} `yaml:"environment"`
}

// ParsePubspecLock parses a pubspec.lock file and returns the parsed structure
func ParsePubspecLock(path string) (*PubspecLock, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var lock PubspecLock
	if err := yaml.Unmarshal(data, &lock); err != nil {
		return nil, err
	}

	return &lock, nil
}

// ParsePubspecYaml parses a pubspec.yaml file and returns the parsed structure
func ParsePubspecYaml(path string) (*PubspecYaml, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var pubspec PubspecYaml
	if err := yaml.Unmarshal(data, &pubspec); err != nil {
		return nil, err
	}

	return &pubspec, nil
}

// GetDirectDependencies returns all direct dependencies from a pubspec.lock.
// This includes main, dev, and overridden dependencies while still excluding
// transitives — the lock spells those "direct main" / "direct dev" /
// "direct overridden" / "transitive".
func GetDirectDependencies(lock *PubspecLock) map[string]LockPackage {
	deps := make(map[string]LockPackage)

	if lock == nil {
		return deps
	}

	for name, pkg := range lock.Packages {
		if name == "" {
			continue
		}
		// Only include dependency entries that are marked as direct.
		if !strings.HasPrefix(pkg.Dependency, "direct") {
			continue
		}

		deps[name] = pkg
	}

	return deps
}

// HasFlutterEnvironment checks if pubspec.yaml has environment.flutter set
func HasFlutterEnvironment(pubspec *PubspecYaml) bool {
	if pubspec == nil || pubspec.Environment == nil {
		return false
	}

	// Check if flutter key exists in environment
	_, hasFlutter := pubspec.Environment["flutter"]
	return hasFlutter
}

// HasSDKEnvironment checks if pubspec.yaml has environment.sdk set
func HasSDKEnvironment(pubspec *PubspecYaml) bool {
	if pubspec == nil || pubspec.Environment == nil {
		return false
	}

	// Check if sdk key exists in environment
	_, hasSDK := pubspec.Environment["sdk"]
	return hasSDK
}
