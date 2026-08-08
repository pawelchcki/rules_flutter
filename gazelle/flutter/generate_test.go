package flutter

import (
	"reflect"
	"testing"
)

func TestGenerateDepsIncludesAllDirectDependencies(t *testing.T) {
	lock := &PubspecLock{
		Packages: map[string]LockPackage{
			"vector_math": {Dependency: "direct main", Source: "hosted"},
			// A bare scalar description, which is how pub writes sdk sources.
			"flutter_test": {Dependency: "direct dev", Source: "sdk", Description: "flutter"},
			"flutter":      {Dependency: "direct main", Source: "sdk", Description: "flutter"},
			"flutter_lints": {Dependency: "direct dev", Source: "hosted"},
			"local_models": {
				Dependency:  "direct main",
				Source:      "path",
				Description: map[string]interface{}{"path": "../local_models"},
			},
			"collection": {Dependency: "transitive", Source: "hosted"},
		},
	}

	fc := &FlutterConfig{SDKRepo: "@flutter_sdk", PubHub: "example_deps"}
	got := generateDeps(lock, fc, "apps/example")

	// Every hosted package collapses into the single hub label: the lock is a
	// complete closure, so the hub carries all of it.
	want := []string{
		"//apps/local_models:lib",
		"@example_deps//:all",
		"@flutter_sdk//flutter/packages/flutter:flutter",
		"@flutter_sdk//flutter/packages/flutter_test:flutter_test",
	}

	if !reflect.DeepEqual(got, want) {
		t.Fatalf("generateDeps(...):\nwant %v\n got %v", want, got)
	}
}

func TestGenerateDepsOmitsHubWhenDirectiveUnset(t *testing.T) {
	lock := &PubspecLock{
		Packages: map[string]LockPackage{
			"vector_math": {Dependency: "direct main", Source: "hosted"},
		},
	}

	got := generateDeps(lock, &FlutterConfig{SDKRepo: "@flutter_sdk"}, "apps/example")
	if len(got) != 0 {
		t.Fatalf("without flutter_pub_hub there is no label to emit, got %v", got)
	}
}

func TestGetDirectDependenciesIncludesAllDirectKinds(t *testing.T) {
	lock := &PubspecLock{
		Packages: map[string]LockPackage{
			"direct-main":       {Dependency: "direct main"},
			"direct-dev":        {Dependency: "direct dev"},
			"direct-overridden": {Dependency: "direct overridden"},
			"transitive":        {Dependency: "transitive"},
		},
	}

	got := GetDirectDependencies(lock)
	if len(got) != 3 {
		t.Fatalf("expected 3 direct dependencies, got %d", len(got))
	}

	for _, name := range []string{"direct-main", "direct-dev", "direct-overridden"} {
		if _, ok := got[name]; !ok {
			t.Fatalf("expected dependency %q to be returned", name)
		}
	}

	if _, ok := got["transitive"]; ok {
		t.Fatalf("did not expect transitive dependencies to be included")
	}
}

func TestSDKDependencyLabelDefaultPackage(t *testing.T) {
	fc := &FlutterConfig{SDKRepo: "@flutter_sdk"}
	got := sdkDependencyLabel("flutter", fc)
	want := "@flutter_sdk//flutter/packages/flutter:flutter"

	if got != want {
		t.Fatalf("sdkDependencyLabel(...): want %q got %q", want, got)
	}
}

func TestSDKDependencyLabelSkyEngine(t *testing.T) {
	fc := &FlutterConfig{SDKRepo: "@flutter_sdk"}
	got := sdkDependencyLabel("sky_engine", fc)
	want := "@flutter_sdk//flutter/bin/cache/pkg/sky_engine:sky_engine"

	if got != want {
		t.Fatalf("sdkDependencyLabel(...): want %q got %q", want, got)
	}
}
