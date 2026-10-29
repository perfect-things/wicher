---
name: release
description: How Wicher releases work — `just release x.y.z`, the release notes, the GitHub release workflow, signing secrets and the Homebrew cask. Use when cutting a release or changing the release pipeline.
---

# Release
`just release x.y.z` first has headless `claude -p` write user-facing notes with the `app-store-changelog` skill (changes since the last tag) into `.github/release-notes/vx.y.z.md` and opens it in `$EDITOR` (empty → abort; an aborted run's file is reused), then commits it with the `Info.plist` bump, tags `vx.y.z` and pushes.
`.github/workflows/release.yml` (`xcode-27` runner: the code needs the macOS 27 SDK) checks tag = plist version, runs tests, imports the "Wicher Development" p12 (secret `SIGNING_P12`/`SIGNING_P12_PASSWORD`) and fails rather than ship an ad-hoc build, publishes `Wicher-x.y.z.zip` + `.dmg` (body: that notes file as "What's New" + `.github/release-notes.md`'s install section; no notes file → GitHub's generated commit list), then pushes the new version/sha256 to `Casks/wicher.rb` in `perfect-things/homebrew-tap` (deploy key `TAP_DEPLOY_KEY`). The cask's `url` must keep matching the zip's name.
