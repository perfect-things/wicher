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

# Remove build products
clean:
    rm -rf .build Wicher.app
