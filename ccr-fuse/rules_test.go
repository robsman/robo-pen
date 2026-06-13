package main

import (
	"os"
	"reflect"
	"strings"
	"testing"

	ignore "github.com/sabhiram/go-gitignore"
)

func compile(t *testing.T, patterns string) *Rules {
	t.Helper()
	r, err := parseRulesReader(strings.NewReader(patterns))
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestRulesMatchExact(t *testing.T) {
	r := compile(t, "node_modules\n.env.local\n.aws/credentials\n")
	tests := []struct {
		path string
		want bool
	}{
		{"node_modules", true},
		{".env.local", true},
		{".aws/credentials", true},
		// gitignore: unanchored pattern matches at any depth
		{"packages/foo/node_modules", true},
		{"a/b/c/node_modules", true},
		{"a/b/.env.local", true},
		{"src/main.go", false},
		{"", false},
		{".env", false},
	}
	for _, c := range tests {
		if got := r.Match(c.path); got != c.want {
			t.Errorf("Match(%q) = %v, want %v", c.path, got, c.want)
		}
	}
}

func TestRulesMatchStar(t *testing.T) {
	r := compile(t, "*.log\n*.tmp\n")
	cases := []struct {
		path string
		want bool
	}{
		{"a.log", true},
		{"path/to/x.log", true},
		{"foo.tmp", true},
		{"deep/nested/file.tmp", true},
		{"alog", false},
	}
	for _, c := range cases {
		if got := r.Match(c.path); got != c.want {
			t.Errorf("Match(%q) = %v, want %v", c.path, got, c.want)
		}
	}
}

func TestRulesMatchDoubleStar(t *testing.T) {
	r := compile(t, "**/cache\nbuild/**/*.o\n")
	cases := []struct {
		path string
		want bool
	}{
		{"cache", true},
		{"a/cache", true},
		{"a/b/c/cache", true},
		{"build/x.o", true},
		{"build/sub/x.o", true},
		{"build/deep/nested/x.o", true},
		{"src/x.o", false},
		{"cachefile", false},
	}
	for _, c := range cases {
		if got := r.Match(c.path); got != c.want {
			t.Errorf("Match(%q) = %v, want %v", c.path, got, c.want)
		}
	}
}

func TestRulesAnchoredVsUnanchored(t *testing.T) {
	r := compile(t, "/root-only\nany-depth\n")
	cases := []struct {
		path string
		want bool
	}{
		{"root-only", true},
		{"a/root-only", false},
		{"any-depth", true},
		{"a/any-depth", true},
		{"x/y/z/any-depth", true},
	}
	for _, c := range cases {
		if got := r.Match(c.path); got != c.want {
			t.Errorf("Match(%q) = %v, want %v", c.path, got, c.want)
		}
	}
}

func TestRulesComments(t *testing.T) {
	r := compile(t, `# top comment
node_modules
  # indented comment
target

# blank line above
.venv
`)
	want := []string{"node_modules", "target", ".venv"}
	if !reflect.DeepEqual(r.Patterns(), want) {
		t.Errorf("patterns = %v, want %v", r.Patterns(), want)
	}
}

func TestRulesNegationSkipped(t *testing.T) {
	r := compile(t, "node_modules\n!keep\n.env\n")
	want := []string{"node_modules", ".env"}
	if !reflect.DeepEqual(r.Patterns(), want) {
		t.Errorf("patterns = %v, want %v (negation must be dropped)", r.Patterns(), want)
	}
}

func TestRulesInvalidSkipped(t *testing.T) {
	r := compile(t, "..\nfoo/../bar\nvalid\n")
	want := []string{"valid"}
	if !reflect.DeepEqual(r.Patterns(), want) {
		t.Errorf("patterns = %v, want %v", r.Patterns(), want)
	}
}

func TestRulesEmpty(t *testing.T) {
	r := compile(t, "")
	if r.Match("anything") {
		t.Errorf("empty ruleset should match nothing")
	}
}

func TestRulesMissingFile(t *testing.T) {
	r, err := ParseRulesFile("/nonexistent/.ccrshadow")
	if err != nil {
		t.Fatalf("missing file should not error: %v", err)
	}
	if r.Match("anything") {
		t.Errorf("missing file should yield empty matcher")
	}
}

func TestRulesTempFile(t *testing.T) {
	f, err := os.CreateTemp("", "ccrshadow-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(f.Name())
	if _, err := f.WriteString("node_modules\n*.log\n"); err != nil {
		t.Fatal(err)
	}
	f.Close()
	r, err := ParseRulesFile(f.Name())
	if err != nil {
		t.Fatal(err)
	}
	if !r.Match("a/node_modules") || !r.Match("path/to/x.log") {
		t.Errorf("real-file parsing failed")
	}
}

func TestClassify(t *testing.T) {
	cases := []struct {
		in       string
		wantKind patKind
		wantKey  string
	}{
		{"node_modules", patUnanchored, "node_modules"},
		{".env.local", patUnanchored, ".env.local"},
		{"node_modules/", patUnanchored, "node_modules"},
		{"/secret", patAnchored, "secret"},
		{"/foo/bar", patAnchored, "foo/bar"},
		{"/foo/bar/", patAnchored, "foo/bar"},
		// Mid-slash without leading slash → matcher (go-gitignore treats as unanchored).
		{".aws/credentials", patGlob, ".aws/credentials"},
		{"a/b/c", patGlob, "a/b/c"},
		{"*.log", patGlob, "*.log"},
		{"build/**/*.o", patGlob, "build/**/*.o"},
		{"**/cache", patGlob, "**/cache"},
		{"foo?.bin", patGlob, "foo?.bin"},
		{"[abc]", patGlob, "[abc]"},
	}
	for _, c := range cases {
		k, key := classify(c.in)
		if k != c.wantKind || key != c.wantKey {
			t.Errorf("classify(%q) = (%v, %q), want (%v, %q)", c.in, k, key, c.wantKind, c.wantKey)
		}
	}
}

// TestFastPathParityWithGitignore ensures the literal fast-path returns the same
// Match result as a pure go-gitignore matcher for every (pattern, query) pair
// across a representative pattern corpus.
func TestFastPathParityWithGitignore(t *testing.T) {
	patterns := []string{
		"node_modules",
		"node_modules/",
		".env.local",
		"/secret",
		".aws/credentials",
		"a/b/c",
		"*.log",
		"build/**/*.o",
		"**/cache",
	}
	queries := []string{
		"node_modules",
		"a/node_modules",
		"a/b/c/node_modules",
		".env.local",
		"deep/.env.local",
		"secret",
		"a/secret",
		"secret-dir-at-root",
		".aws/credentials",
		"x/.aws/credentials",
		"a/b/c",
		"x/a/b/c",
		"app.log",
		"path/to/app.log",
		"build/main.o",
		"build/sub/main.o",
		"src/main.o",
		"cache",
		"a/cache",
		"src/main.go",
		"unrelated/file.txt",
		"",
	}
	rules := compile(t, strings.Join(patterns, "\n")+"\n")
	pure := ignore.CompileIgnoreLines(patterns...)
	for _, q := range queries {
		fast := rules.Match(q)
		ref := false
		if q != "" {
			ref = pure.MatchesPath(q)
		}
		if fast != ref {
			t.Errorf("divergence on %q: fast=%v ref=%v", q, fast, ref)
		}
	}
}

// TestFastPathHitsOnly verifies that single-component-literal-only configs skip
// the go-gitignore matcher entirely.
func TestFastPathHitsOnly(t *testing.T) {
	r := compile(t, "node_modules\n.env.local\n/secret\n")
	if r.matcher != nil {
		t.Errorf("matcher should be nil for pure-literal config; got %v", r.matcher)
	}
	if !r.Match("a/node_modules") {
		t.Errorf("unanchored basename should match at depth")
	}
	if !r.Match("secret") {
		t.Errorf("leading-slash anchored should match at root")
	}
	if r.Match("a/secret") {
		t.Errorf("leading-slash anchored should NOT match deeper")
	}
}

// TestFastPathWithGlobsAlsoOK checks mixed config (literals + globs) still
// behaves correctly across both buckets.
func TestFastPathWithGlobsAlsoOK(t *testing.T) {
	r := compile(t, "node_modules\n*.log\n/secret\n")
	if r.matcher == nil {
		t.Fatalf("expected matcher to be non-nil due to glob pattern")
	}
	checks := []struct {
		path string
		want bool
	}{
		{"node_modules", true},        // literal fast-path
		{"deep/node_modules", true},   // literal fast-path unanchored
		{"app.log", true},             // glob via matcher
		{"path/to/app.log", true},     // glob via matcher
		{"secret", true},              // anchored literal
		{"a/secret", false},           // anchored — no deep match
		{"src/main.go", false},
	}
	for _, c := range checks {
		if got := r.Match(c.path); got != c.want {
			t.Errorf("Match(%q) = %v, want %v", c.path, got, c.want)
		}
	}
}

// Benchmarks: compare fast-path Rules.Match against pure go-gitignore.
func BenchmarkMatchLiteralFastPath(b *testing.B) {
	r, _ := parseRulesReader(strings.NewReader("node_modules\n.env.local\n.venv\ntarget\ndist\n"))
	queries := []string{
		"node_modules", "a/b/node_modules", "src/main.go", ".env.local",
		"a/x/y/z/something", "deep/nested/.venv", "target", "x/y/dist",
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = r.Match(queries[i%len(queries)])
	}
}

func BenchmarkMatchGoGitignoreOnly(b *testing.B) {
	pure := ignore.CompileIgnoreLines("node_modules", ".env.local", ".venv", "target", "dist")
	queries := []string{
		"node_modules", "a/b/node_modules", "src/main.go", ".env.local",
		"a/x/y/z/something", "deep/nested/.venv", "target", "x/y/dist",
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = pure.MatchesPath(queries[i%len(queries)])
	}
}

func TestJoinRel(t *testing.T) {
	cases := []struct {
		parent, name, want string
	}{
		{"", "foo", "foo"},
		{".", "foo", "foo"},
		{"a", "b", "a/b"},
		{"a/b", "c", "a/b/c"},
	}
	for _, c := range cases {
		if got := joinRel(c.parent, c.name); got != c.want {
			t.Errorf("joinRel(%q,%q) = %q, want %q", c.parent, c.name, got, c.want)
		}
	}
}
