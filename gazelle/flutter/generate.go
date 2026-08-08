package flutter

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/repo"
	"github.com/bazelbuild/bazel-gazelle/resolve"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// GenerateRules generates Flutter build rules for a directory
func (fl *flutterLang) GenerateRules(args language.GenerateArgs) language.GenerateResult {
	fc := GetFlutterConfig(args.Config)

	if !fc.Generate || fc.IsExcluded(args.Rel) {
		return language.GenerateResult{}
	}

	hasPubspec := false
	for _, f := range args.RegularFiles {
		if f == "pubspec.yaml" {
			hasPubspec = true
			break
		}
	}

	if !hasPubspec {
		return language.GenerateResult{}
	}

	hasLock := false
	var lock *PubspecLock
	for _, f := range args.RegularFiles {
		if f == "pubspec.lock" {
			hasLock = true
			parsed, err := ParsePubspecLock(filepath.Join(args.Dir, f))
			if err == nil {
				lock = parsed
			}
			break
		}
	}

	hasLib := false
	for _, d := range args.Subdirs {
		if d == "lib" {
			hasLib = true
			break
		}
	}

	pubspecYamlPath := filepath.Join(args.Dir, "pubspec.yaml")
	pubspecYaml, err := ParsePubspecYaml(pubspecYamlPath)
	if err != nil {
		pubspecYaml = nil
	}

	ruleKind := "flutter_library"
	if pubspecYaml != nil {
		hasFlutter := HasFlutterEnvironment(pubspecYaml)
		hasSDK := HasSDKEnvironment(pubspecYaml)

		if !hasFlutter && hasSDK {
			ruleKind = "dart_library"
		}
	}

	r := rule.NewRule(ruleKind, fc.LibraryName)
	r.SetAttr("pubspec", "pubspec.yaml")
	if hasLock {
		r.SetAttr("lock", "pubspec.lock")
	}

	if hasLib {
		srcs := collectSourceFiles(args.Dir, hasLib)
		if len(srcs) > 0 {
			r.SetAttr("srcs", srcs)
		}
	}

	if hasLock && lock != nil {
		deps := generateDeps(lock, fc, args.Rel)
		if len(deps) > 0 {
			r.SetAttr("deps", deps)
		}
	}

	// Must return same number of imports as rules (1)
	imports := []interface{}{[]resolve.ImportSpec{}}

	return language.GenerateResult{
		Gen:     []*rule.Rule{r},
		Imports: imports,
	}
}

// collectSourceFiles walks the lib/ directory and returns all source files
func collectSourceFiles(baseDir string, hasLib bool) []string {
	var srcs []string

	if hasLib {
		libFiles := walkDir(filepath.Join(baseDir, "lib"), baseDir)
		srcs = append(srcs, libFiles...)
	}

	// Sort for consistent output
	sort.Strings(srcs)
	return srcs
}

// walkDir recursively walks a directory and returns relative paths to all files
func walkDir(dir string, baseDir string) []string {
	var files []string

	filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil // Skip errors
		}
		if !info.IsDir() {
			// Get relative path from baseDir
			relPath, err := filepath.Rel(baseDir, path)
			if err == nil {
				files = append(files, relPath)
			}
		}
		return nil
	})

	return files
}

// generateDeps creates a list of dependency labels from a pubspec.lock.
//
// Hosted packages do not get one label each. A lock is a complete transitive
// closure, so the pub extension turns it into a single hub repository whose
// `:all` target carries the whole thing; the individual leaves are not
// importable by name. The hub is named in MODULE.bazel, so it reaches gazelle
// through the flutter_pub_hub directive.
func generateDeps(lock *PubspecLock, fc *FlutterConfig, rel string) []string {
	directDeps := GetDirectDependencies(lock)
	if len(directDeps) == 0 {
		return nil
	}

	deps := make([]string, 0, len(directDeps))
	hasHosted := false
	for pkg, meta := range directDeps {
		switch meta.Source {
		case "hosted":
			hasHosted = true
		case "sdk":
			if sdkLabel := sdkDependencyLabel(pkg, fc); sdkLabel != "" {
				deps = append(deps, sdkLabel)
			}
		case "path":
			if pathLabel := pathDependencyLabel(meta, fc, rel); pathLabel != "" {
				deps = append(deps, pathLabel)
			}
		}
	}

	if hasHosted && fc != nil && fc.PubHub != "" {
		deps = append(deps, fmt.Sprintf("@%s//:all", fc.PubHub))
	}

	// Sort for consistent output
	sort.Strings(deps)
	return deps
}

// pathDependencyLabel returns the Bazel label for a local path dependency.
func pathDependencyLabel(pkg LockPackage, fc *FlutterConfig, rel string) string {
	pathValue := ""
	switch desc := pkg.Description.(type) {
	case string:
		pathValue = desc
	case map[string]interface{}:
		if value, ok := desc["path"].(string); ok {
			pathValue = value
		}
	}
	if pathValue == "" {
		return ""
	}

	cleanPath := filepath.Clean(filepath.Join(rel, pathValue))
	if cleanPath == "." || strings.HasPrefix(cleanPath, "..") {
		return ""
	}

	targetName := "lib"
	if fc != nil && fc.LibraryName != "" {
		targetName = fc.LibraryName
	}
	return fmt.Sprintf("//%s:%s", filepath.ToSlash(cleanPath), targetName)
}

// sdkDependencyLabel returns the Bazel label for an SDK provided package.
func sdkDependencyLabel(pkg string, fc *FlutterConfig) string {
	if fc == nil || fc.SDKRepo == "" {
		return ""
	}

	path := sdkPackagePath(pkg)
	if path == "" {
		return ""
	}

	return fmt.Sprintf("%s//%s:%s", fc.SDKRepo, path, pkg)
}

// sdkPackagePath returns the repository relative path for an SDK package target.
func sdkPackagePath(pkg string) string {
	switch pkg {
	case "sky_engine":
		return fmt.Sprintf("flutter/bin/cache/pkg/%s", pkg)
	default:
		return fmt.Sprintf("flutter/packages/%s", pkg)
	}
}

// Imports extracts import statements from Flutter/Dart source files
func (fl *flutterLang) Imports(c *config.Config, r *rule.Rule, f *rule.File) []resolve.ImportSpec {
	// For now, we don't need to parse Dart imports
	// The dependencies are extracted from pubspec.lock
	return []resolve.ImportSpec{}
}

// Embeds is not used for Flutter
func (fl *flutterLang) Embeds(r *rule.Rule, from label.Label) []label.Label {
	return nil
}

// Resolve resolves imports to labels
func (fl *flutterLang) Resolve(c *config.Config, ix *resolve.RuleIndex, rc *repo.RemoteCache, r *rule.Rule, importsRaw interface{}, from label.Label) {
	// Dependencies are already resolved in GenerateRules
	// This is called after generation to finalize labels
}

// parseImports parses Dart import statements from source code
// Returns a list of import paths
func parseImports(content string) []string {
	var imports []string

	lines := strings.Split(content, "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)

		// Look for import statements: import 'package:...' or import "package:..."
		if strings.HasPrefix(line, "import ") {
			// Extract the quoted string
			start := strings.Index(line, "'")
			if start == -1 {
				start = strings.Index(line, "\"")
			}
			if start == -1 {
				continue
			}

			quote := line[start]
			end := strings.Index(line[start+1:], string(quote))
			if end == -1 {
				continue
			}

			importPath := line[start+1 : start+1+end]

			// Only include package: imports
			if strings.HasPrefix(importPath, "package:") {
				imports = append(imports, importPath)
			}
		}
	}

	return imports
}
