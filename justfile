# Run `just` to list recipes.

[private]
default:
    @just --list

# Build and sign Wicher.app
build:
    scripts/build.sh

# Run unit tests (extra args for `swift test`, e.g. `just test --filter FuzzyMatcher`)
test *args:
    swift test {{args}}

# Run tests and write list/settings PNG snapshots to DIR
snapshot dir="snapshots":
    mkdir -p {{dir}}
    WICHER_SNAPSHOT_DIR="$(cd {{dir}} && pwd)" swift test

# Build, quit any running Wicher, and launch the fresh bundle
run: build
    -pkill -x Wicher
    open Wicher.app

# Build, quit any running Wicher, and copy the bundle to /Applications
install: build
    -pkill -x Wicher
    rm -rf /Applications/Wicher.app
    ditto Wicher.app /Applications/Wicher.app
    open /Applications/Wicher.app

# Regenerate app icon from Resources/Wicher.icon (needs Xcode)
icon:
    scripts/make-icon.sh

# Create the self-signed "Wicher Development" identity (once)
signing-identity:
    scripts/make-signing-identity.sh

# Write release notes (Claude + app-store-changelog skill, then $EDITOR), bump the version,
# commit, tag and push; CI builds the release and bumps the Homebrew cask
release version:
    #!/usr/bin/env bash
    set -euo pipefail
    notes=".github/release-notes/v{{version}}.md"
    # A notes file left by an aborted run is reused, so it doesn't count as dirty.
    [[ -z "$(git status --porcelain -- . ":!$notes")" ]] || { echo "✗ Working tree not clean" >&2; exit 1; }
    if [[ ! -s "$notes" ]]; then
        since="$(git describe --tags --abbrev=0)"
        echo "Writing release notes for changes since $since…"
        mkdir -p "$(dirname "$notes")"
        echo "Use the app-store-changelog skill to write release notes for Wicher {{version}} (a macOS window switcher), covering every change since $since. This text goes on the GitHub release page. Reply with only the notes: Markdown, '- ' bullets, optionally under '### New' / '### Improved' / '### Fixed' headings, no title, no preamble, no questions. If nothing is user-facing, reply with one bullet saying so." \
            | claude -p --allowedTools "Skill Read Grep Glob Bash(git log:*) Bash(git diff:*) Bash(git show:*) Bash(.agents/skills/app-store-changelog/scripts/collect_release_changes.sh:*)" \
            > "$notes"
    fi
    ${EDITOR:-vi} "$notes"
    grep -q '[^[:space:]]' "$notes" || { echo "✗ $notes is empty; not releasing" >&2; exit 1; }
    build=$(( $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist) + 1 ))
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString {{version}}" -c "Set :CFBundleVersion $build" Info.plist
    git add "$notes"
    git commit -qam "Wicher {{version}}"
    git tag "v{{version}}"
    git push --atomic origin HEAD "v{{version}}"
    echo "✓ Pushed v{{version}}; follow the build with: gh run watch"

# Remove build products
clean:
    rm -rf .build Wicher.app
