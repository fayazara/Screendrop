package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Release-note input and prompt behaviour can be supplied via flags so the
// tool can run fully non-interactively (e.g. from an agent or CI). When no
// notes flag is given it falls back to reading them from stdin.
var (
	notesFlag     string
	notesFileFlag string
	assumeYes     bool
)

const (
	red    = "\033[0;31m"
	green  = "\033[0;32m"
	yellow = "\033[0;33m"
	cyan   = "\033[0;36m"
	bold   = "\033[1m"
	reset  = "\033[0m"
)

func step(msg string)    { fmt.Printf("\n%s%s==> %s%s\n", cyan, bold, msg, reset) }
func success(msg string) { fmt.Printf("%s  OK %s%s\n", green, msg, reset) }
func warn(msg string)    { fmt.Printf("%s  WARN %s%s\n", yellow, msg, reset) }

func fail(msg string) {
	fmt.Printf("%s  ERROR %s%s\n", red, msg, reset)
	os.Exit(1)
}

const (
	appDisplayName = "Screendrop"
	githubRepo     = "fayazara/screendrop"
	gitBranch      = "main"
	minSystemVer   = "26.4"
	dmgVolumeName  = "Screendrop"
	appName        = "Screendrop.app"
	dmgName        = "Screendrop.dmg"
	appcastFile    = "appcast.xml"
	repoEnvVar     = "SCREENDROP_REPO"
	appcastURL     = "https://raw.githubusercontent.com/fayazara/screendrop/main/appcast.xml"

	// Homebrew tap (cask) configuration.
	tapRepo      = "fayazara/homebrew-tap"
	caskRelPath  = "Casks/screendrop.rb"
	tapDirEnvVar = "SCREENDROP_TAP_DIR"
	bundleID     = "com.fayazahmed.Screendrop"
)

var derivedDataPrefixes = []string{
	"Screendrop-",
	"OpenShot-",
}

type Appcast struct {
	XMLName xml.Name `xml:"rss"`
	Version string   `xml:"version,attr"`
	Channel Channel  `xml:"channel"`
}

type Channel struct {
	Title    string `xml:"title"`
	Link     string `xml:"link"`
	Language string `xml:"language"`
	Items    []Item `xml:"item"`
}

type Item struct {
	Title              string    `xml:"title"`
	Version            string    `xml:"http://www.andymatuschak.org/xml-namespaces/sparkle version"`
	ShortVersionString string    `xml:"http://www.andymatuschak.org/xml-namespaces/sparkle shortVersionString"`
	MinSystemVersion   string    `xml:"http://www.andymatuschak.org/xml-namespaces/sparkle minimumSystemVersion"`
	PubDate            string    `xml:"pubDate"`
	Description        string    `xml:"description"`
	Enclosure          Enclosure `xml:"enclosure"`
}

type Enclosure struct {
	URL         string `xml:"url,attr"`
	Type        string `xml:"type,attr"`
	EdSignature string `xml:"http://www.andymatuschak.org/xml-namespaces/sparkle edSignature,attr"`
	Length      string `xml:"length,attr"`
}

func main() {
	flag.StringVar(&notesFlag, "notes", "", "Release notes, one bullet per line. Skips the interactive prompt.")
	flag.StringVar(&notesFileFlag, "notes-file", "", "Path to a file with release notes, one bullet per line. Skips the interactive prompt.")
	flag.BoolVar(&assumeYes, "yes", false, "Assume \"yes\" for all confirmation prompts (non-interactive).")
	flag.BoolVar(&assumeYes, "y", false, "Alias for -yes.")
	flag.Parse()

	homeDir, _ := os.UserHomeDir()
	appPath := filepath.Join(homeDir, "Downloads", appName)
	dmgPath := filepath.Join(homeDir, "Downloads", dmgName)

	repoDir := findRepoDir(homeDir)
	appcastPath := filepath.Join(repoDir, appcastFile)

	fmt.Printf("\n%s=======================================%s\n", bold, reset)
	fmt.Printf("%s  %s Release Manager%s\n", bold, appDisplayName, reset)
	fmt.Printf("%s=======================================%s\n", bold, reset)

	step("Checking prerequisites...")

	requireCommand("create-dmg", "Install with: brew install create-dmg")
	requireCommand("gh", "Install with: brew install gh")
	requireCommand("git", "")
	requireCommand("plutil", "")

	signUpdate := findSignUpdate(homeDir)
	if signUpdate == "" {
		fail("Sparkle sign_update not found in DerivedData. Build the project once first.")
	}
	success("All tools found")

	step("Validating " + appPath + "...")

	info, err := os.Stat(appPath)
	if err != nil || !info.IsDir() {
		fail(appName + " not found in ~/Downloads. Export it from Xcode first.")
	}

	plist := filepath.Join(appPath, "Contents", "Info.plist")
	version, err := plistValue(plist, "CFBundleShortVersionString")
	if err != nil {
		fail("Could not read version from Info.plist")
	}

	build, err := plistValue(plist, "CFBundleVersion")
	if err != nil {
		fail("Could not read build number from Info.plist")
	}

	if feedURL, err := plistValue(plist, "SUFeedURL"); err != nil {
		warn("SUFeedURL not found in Info.plist")
	} else if feedURL != appcastURL {
		warn("SUFeedURL is " + feedURL + ", expected " + appcastURL)
	}

	if _, err := plistValue(plist, "SUPublicEDKey"); err != nil {
		warn("SUPublicEDKey not found in Info.plist")
	}

	fmt.Printf("  Version: %s%s%s  Build: %s%s%s\n", bold, version, reset, bold, build, reset)

	existingData, _ := os.ReadFile(appcastPath)
	if strings.Contains(string(existingData), "sparkle:version>"+build+"<") {
		warn(fmt.Sprintf("Build %s already exists in appcast.xml", build))
		if !confirm("Continue anyway?", false) {
			os.Exit(0)
		}
	}

	success("App validated")

	notes, err := collectReleaseNotes()
	if err != nil {
		fail(err.Error())
	}
	if len(notes) == 0 {
		fail("No release notes provided")
	}

	fmt.Printf("\n  %sRelease summary:%s\n", bold, reset)
	fmt.Printf("  App:     %s\n", appDisplayName)
	fmt.Printf("  Version: %s (build %s)\n", version, build)
	fmt.Printf("  Tag:     v%s\n", version)
	fmt.Println("  Notes:")
	for _, n := range notes {
		fmt.Printf("    - %s\n", n)
	}
	fmt.Println()

	if !confirm("Proceed with release?", true) {
		os.Exit(0)
	}

	step("Creating DMG...")

	_ = os.Remove(dmgPath)
	dmgArgs := []string{
		"--volname", dmgVolumeName,
		"--window-pos", "200", "120",
		"--window-size", "600", "400",
		"--icon-size", "100",
		"--icon", appName, "150", "185",
		"--app-drop-link", "450", "185",
		dmgPath,
		appPath,
	}

	out, err := runCmd("create-dmg", dmgArgs...)
	if err != nil {
		if _, statErr := os.Stat(dmgPath); statErr != nil {
			fail(fmt.Sprintf("DMG creation failed: %s\n%s", err, out))
		}
	}

	if _, err := os.Stat(dmgPath); err != nil {
		fail("DMG creation failed: file not found")
	}
	success("DMG created at " + dmgPath)

	step("Signing DMG with Sparkle...")

	signOut, err := runCmd(signUpdate, dmgPath)
	if err != nil {
		fail(fmt.Sprintf("sign_update failed: %s\n%s", err, signOut))
	}

	signature, length := parseSparkleSignature(signOut)
	success(fmt.Sprintf("Signed (length: %s bytes)", length))

	step("Updating appcast.xml...")

	appcastData, err := os.ReadFile(appcastPath)
	if err != nil {
		fail("Could not read appcast.xml: " + err.Error())
	}

	var appcast Appcast
	if err := xml.Unmarshal(appcastData, &appcast); err != nil {
		fail("Could not parse appcast.xml: " + err.Error())
	}

	pubDate := time.Now().UTC().Format("Mon, 02 Jan 2006 15:04:05 +0000")
	downloadURL := fmt.Sprintf("https://github.com/%s/releases/download/v%s/%s", githubRepo, version, dmgName)

	newItem := Item{
		Title:              fmt.Sprintf("Version %s", version),
		Version:            build,
		ShortVersionString: version,
		MinSystemVersion:   minSystemVer,
		PubDate:            pubDate,
		Description:        buildDescription(version, notes),
		Enclosure: Enclosure{
			URL:         downloadURL,
			Type:        "application/octet-stream",
			EdSignature: signature,
			Length:      length,
		},
	}

	allItems := make([]Item, 0, len(appcast.Channel.Items)+1)
	allItems = append(allItems, newItem)
	allItems = append(allItems, appcast.Channel.Items...)

	if err := writeAppcast(appcastPath, allItems); err != nil {
		fail("Could not write appcast.xml: " + err.Error())
	}
	success(fmt.Sprintf("Appcast updated with v%s", version))

	step("Pushing appcast to GitHub...")

	if _, err := runCmd("git", "-C", repoDir, "add", appcastFile); err != nil {
		fail("git add failed: " + err.Error())
	}

	commitMsg := fmt.Sprintf("Release v%s appcast", version)
	if out, err := runCmd("git", "-C", repoDir, "commit", "--only", appcastFile, "-m", commitMsg); err != nil {
		fail(fmt.Sprintf("git commit failed: %s\n%s", err, out))
	}

	if out, err := runCmd("git", "-C", repoDir, "push", "origin", gitBranch); err != nil {
		fail(fmt.Sprintf("git push failed: %s\n%s", err, out))
	}
	success("Pushed to " + gitBranch)

	step("Creating GitHub release...")

	var mdNotes strings.Builder
	mdNotes.WriteString("## What's New\n\n")
	for _, n := range notes {
		mdNotes.WriteString(fmt.Sprintf("- %s\n", n))
	}

	releaseURL, err := runCmd("gh", "release", "create",
		"v"+version,
		dmgPath,
		"--repo", githubRepo,
		"--title", "v"+version,
		"--notes", mdNotes.String(),
	)
	if err != nil {
		fail(fmt.Sprintf("gh release create failed: %s\n%s", err, releaseURL))
	}
	success("Release created")

	step("Updating Homebrew cask...")
	if err := updateHomebrewCask(homeDir, version, dmgPath); err != nil {
		warn("Homebrew cask not updated: " + err.Error())
	} else {
		success("Homebrew cask updated in " + tapRepo)
	}

	fmt.Printf("\n%s%s=======================================%s\n", green, bold, reset)
	fmt.Printf("%s%s  Released %s v%s%s\n", green, bold, appDisplayName, version, reset)
	fmt.Printf("%s%s  %s%s\n", green, bold, releaseURL, reset)
	fmt.Printf("%s%s=======================================%s\n\n", green, bold, reset)
}

// updateHomebrewCask regenerates the cask with the new version and the DMG's
// sha256, then commits and pushes it to the tap repo. Non-fatal: a missing or
// unconfigured tap should never block a release.
func updateHomebrewCask(homeDir, version, dmgPath string) error {
	sum, err := sha256File(dmgPath)
	if err != nil {
		return fmt.Errorf("hashing DMG: %w", err)
	}

	tapDir, cleanup, err := resolveTapDir(homeDir)
	if err != nil {
		return err
	}
	if cleanup != nil {
		defer cleanup()
	}

	caskPath := filepath.Join(tapDir, caskRelPath)
	if err := os.MkdirAll(filepath.Dir(caskPath), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(caskPath, []byte(renderCask(version, sum)), 0o644); err != nil {
		return err
	}

	if out, err := runCmd("git", "-C", tapDir, "add", caskRelPath); err != nil {
		return fmt.Errorf("git add: %s", out)
	}

	commitMsg := fmt.Sprintf("screendrop %s", version)
	if out, err := runCmd("git", "-C", tapDir, "commit", "-m", commitMsg); err != nil {
		if strings.Contains(out, "nothing to commit") {
			return nil
		}
		return fmt.Errorf("git commit: %s", out)
	}

	if out, err := runCmd("git", "-C", tapDir, "push"); err != nil {
		return fmt.Errorf("git push: %s", out)
	}
	return nil
}

// resolveTapDir returns a working copy of the tap repo. It honours
// SCREENDROP_TAP_DIR (a local clone) or falls back to a temporary clone.
func resolveTapDir(homeDir string) (string, func(), error) {
	if dir := strings.TrimSpace(os.Getenv(tapDirEnvVar)); dir != "" {
		if !fileExists(dir) {
			return "", nil, fmt.Errorf("%s set but %s does not exist", tapDirEnvVar, dir)
		}
		_, _ = runCmd("git", "-C", dir, "pull", "--ff-only")
		return dir, nil, nil
	}

	tmp, err := os.MkdirTemp("", "screendrop-tap-")
	if err != nil {
		return "", nil, err
	}
	cleanup := func() { _ = os.RemoveAll(tmp) }

	if out, err := runCmd("gh", "repo", "clone", tapRepo, tmp); err != nil {
		cleanup()
		return "", nil, fmt.Errorf("clone %s failed (create it or set %s): %s", tapRepo, tapDirEnvVar, out)
	}
	return tmp, cleanup, nil
}

func renderCask(version, sha string) string {
	return fmt.Sprintf(`cask "screendrop" do
  version "%s"
  sha256 "%s"

  url "https://github.com/%s/releases/download/v#{version}/%s"
  name "Screendrop"
  desc "Native macOS menu bar screenshot and screen recording tool"
  homepage "https://github.com/%s"

  auto_updates true

  app "%s"

  zap trash: [
    "~/Library/Preferences/%s.plist",
    "~/Library/Application Support/Screendrop",
  ]
end
`, version, sha, githubRepo, dmgName, githubRepo, appName, bundleID)
}

func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()

	hasher := sha256.New()
	if _, err := io.Copy(hasher, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(hasher.Sum(nil)), nil
}

func findRepoDir(homeDir string) string {
	if repoDir := strings.TrimSpace(os.Getenv(repoEnvVar)); repoDir != "" {
		if fileExists(filepath.Join(repoDir, appcastFile)) {
			return repoDir
		}
		fail(repoEnvVar + " is set, but appcast.xml was not found there.")
	}

	if cwd, err := os.Getwd(); err == nil {
		for dir := cwd; ; dir = filepath.Dir(dir) {
			if fileExists(filepath.Join(dir, appcastFile)) {
				return dir
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
		}
	}

	candidates := []string{
		filepath.Join(homeDir, "Developer", "fayazara", "mac", "OpenShot"),
		filepath.Join(homeDir, "Developer", "fayazara", "mac", "Screendrop"),
	}
	for _, candidate := range candidates {
		if fileExists(filepath.Join(candidate, appcastFile)) {
			return candidate
		}
	}

	fail("Could not find Screendrop repo. Set " + repoEnvVar + " to the repo path.")
	return ""
}

func findSignUpdate(homeDir string) string {
	derivedData := filepath.Join(homeDir, "Library", "Developer", "Xcode", "DerivedData")
	entries, err := os.ReadDir(derivedData)
	if err != nil {
		return ""
	}

	for _, prefix := range derivedDataPrefixes {
		for _, entry := range entries {
			if !strings.HasPrefix(entry.Name(), prefix) {
				continue
			}

			candidate := filepath.Join(derivedData, entry.Name(),
				"SourcePackages", "artifacts", "sparkle", "Sparkle", "bin", "sign_update")
			if fileExists(candidate) {
				return candidate
			}
		}
	}
	return ""
}

func requireCommand(name, installHint string) {
	if commandExists(name) {
		return
	}

	if installHint == "" {
		fail(name + " not found")
	}
	fail(name + " not found. " + installHint)
}

func commandExists(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

func runCmd(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func plistValue(plistPath, key string) (string, error) {
	out, err := runCmd("plutil", "-extract", key, "raw", "-o", "-", plistPath)
	if err != nil {
		return "", fmt.Errorf("key %q not found", key)
	}
	return out, nil
}

func confirm(prompt string, defaultYes bool) bool {
	if assumeYes {
		fmt.Printf("  %s (auto-yes)\n", prompt)
		return true
	}

	hint := "(Y/n)"
	if !defaultYes {
		hint = "(y/N)"
	}
	fmt.Printf("  %s %s ", prompt, hint)

	reader := bufio.NewReader(os.Stdin)
	line, _ := reader.ReadString('\n')
	line = strings.TrimSpace(strings.ToLower(line))
	if line == "" {
		return defaultYes
	}
	return line == "y" || line == "yes"
}

// collectReleaseNotes returns the release-note bullets from (in priority order)
// the -notes-file flag, the -notes flag, or interactive stdin input.
func collectReleaseNotes() ([]string, error) {
	if notesFileFlag != "" {
		data, err := os.ReadFile(notesFileFlag)
		if err != nil {
			return nil, fmt.Errorf("could not read notes file: %w", err)
		}
		step("Using release notes from " + notesFileFlag)
		return parseNotes(string(data)), nil
	}

	if notesFlag != "" {
		step("Using release notes from -notes flag")
		return parseNotes(notesFlag), nil
	}

	step("Release notes (one bullet point per line, empty line to finish):")
	fmt.Printf("  %sEnter your release notes below:%s\n", yellow, reset)

	var notes []string
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			break
		}
		notes = append(notes, cleanNote(line))
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("could not read release notes: %w", err)
	}
	return notes, nil
}

// parseNotes splits raw text into trimmed, non-empty bullet lines.
func parseNotes(raw string) []string {
	var notes []string
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		notes = append(notes, cleanNote(line))
	}
	return notes
}

// cleanNote strips a leading markdown-style bullet marker so callers can pass
// either "Fixed a bug" or "- Fixed a bug".
func cleanNote(line string) string {
	line = strings.TrimSpace(line)
	for _, prefix := range []string{"- ", "* ", "• "} {
		if strings.HasPrefix(line, prefix) {
			return strings.TrimSpace(strings.TrimPrefix(line, prefix))
		}
	}
	return line
}

func parseSparkleSignature(output string) (string, string) {
	sigRe := regexp.MustCompile(`sparkle:edSignature="([^"]+)"`)
	lenRe := regexp.MustCompile(`length="([^"]+)"`)

	sigMatch := sigRe.FindStringSubmatch(output)
	lenMatch := lenRe.FindStringSubmatch(output)

	if len(sigMatch) < 2 {
		fail("Could not parse signature from sign_update output:\n" + output)
	}
	if len(lenMatch) < 2 {
		fail("Could not parse length from sign_update output:\n" + output)
	}

	return sigMatch[1], lenMatch[1]
}

func buildDescription(version string, notes []string) string {
	var htmlItems strings.Builder
	for _, note := range notes {
		htmlItems.WriteString(fmt.Sprintf("          <li>%s</li>\n", xmlEscapeText(note)))
	}

	return fmt.Sprintf("<![CDATA[\n        <h2>What's New in %s</h2>\n        <ul>\n%s        </ul>\n      ]]>",
		xmlEscapeText(version), htmlItems.String())
}

func descriptionToCDATA(desc string) string {
	trimmed := strings.TrimSpace(desc)
	if strings.HasPrefix(trimmed, "<![CDATA[") {
		return desc
	}
	return "<![CDATA[\n        " + trimmed + "\n      ]]>"
}

func writeAppcast(path string, items []Item) error {
	var b strings.Builder

	b.WriteString(`<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
  xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
  xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Screendrop Updates</title>
    <link>https://raw.githubusercontent.com/fayazara/screendrop/main/appcast.xml</link>
    <language>en</language>

    <!--
      HOW TO ADD A NEW RELEASE:
      1. Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in Xcode.
      2. Export Screendrop.app to ~/Downloads.
      3. Run: go run ./cmd/screendrop-release
         - Enter release notes when prompted, or run non-interactively with
           flags, e.g.:
             go run ./cmd/screendrop-release -yes \
               -notes "Fixed pixelate preview
             Improved upload flow"
           (-notes-file <path> reads bullets from a file instead.)

      The release tool creates Screendrop.dmg, signs it with Sparkle, prepends
      this appcast, commits/pushes appcast.xml to main, and creates the GitHub
      release with the DMG attached.

      Newest release goes on top.
    -->
`)

	for _, item := range items {
		desc := descriptionToCDATA(item.Description)

		b.WriteString("\n    <item>\n")
		b.WriteString(fmt.Sprintf("      <title>%s</title>\n", xmlEscapeText(item.Title)))
		b.WriteString(fmt.Sprintf("      <sparkle:version>%s</sparkle:version>\n", xmlEscapeText(item.Version)))
		b.WriteString(fmt.Sprintf("      <sparkle:shortVersionString>%s</sparkle:shortVersionString>\n", xmlEscapeText(item.ShortVersionString)))
		b.WriteString(fmt.Sprintf("      <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>\n", xmlEscapeText(item.MinSystemVersion)))
		b.WriteString(fmt.Sprintf("      <pubDate>%s</pubDate>\n", xmlEscapeText(item.PubDate)))
		b.WriteString(fmt.Sprintf("      <description>%s</description>\n", desc))
		b.WriteString("      <enclosure\n")
		b.WriteString(fmt.Sprintf("        url=\"%s\"\n", xmlEscapeAttr(item.Enclosure.URL)))
		b.WriteString(fmt.Sprintf("        type=\"%s\"\n", xmlEscapeAttr(item.Enclosure.Type)))
		b.WriteString(fmt.Sprintf("        sparkle:edSignature=\"%s\"\n", xmlEscapeAttr(item.Enclosure.EdSignature)))
		b.WriteString(fmt.Sprintf("        length=\"%s\"\n", xmlEscapeAttr(item.Enclosure.Length)))
		b.WriteString("      />\n")
		b.WriteString("    </item>\n")
	}

	b.WriteString("\n  </channel>\n</rss>\n")
	return os.WriteFile(path, []byte(b.String()), 0644)
}

func xmlEscapeText(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	return s
}

func xmlEscapeAttr(s string) string {
	s = xmlEscapeText(s)
	s = strings.ReplaceAll(s, "\"", "&quot;")
	return s
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
