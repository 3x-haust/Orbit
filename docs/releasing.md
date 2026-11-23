# Releases

Orbit 1.7.0 and older accept only `com.lyu.orbit` and read GitHub's
`/releases/latest`. Keep **v1.7.1** marked as GitHub's latest release: it is the
last legacy-ID build and can install `dev.3xhaust.Orbit`.

Starting with 1.7.1, the updater reads `/releases?per_page=100` and picks the
highest stable version. Publish **1.7.2 and every later release with
`--latest=false`**. Never delete the 1.7.1 release or its ZIP. A newer release
must not take over `/releases/latest`, or older apps lose their upgrade path.
The README links to the release list and sorts its version badge by SemVer.

The bridge respects a legacy user's decision to dismiss 1.7.1. Because the
legacy endpoint remains pinned, that version will not prompt again; the user
must check manually in General > Updates. Do not silently reset dismissal.
Login-item registration is owned by macOS rather than the copied preferences;
users should check Open at login after the ID change and enable it again if
needed. No automatic transfer of that system registration is promised.

## Build and publish

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`,
   run `xcodegen generate`, and commit both the spec and generated project.
2. Build Debug and run `python3 tools/regressions/check-metadata.py`, the updater
   regression and the tests for the changed modules. Merge the PR into `main`.
3. Build the merged source with a verified Tavi helper (`tools/fetch-tavi.sh`)
   and the signing identity for team `UM52UU4B7L`. Release is universal:
   `xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release
   -derivedDataPath build-rel build`.
4. Verify the app with `codesign --verify --deep --strict --all-architectures`
   and a requirement for `dev.3xhaust.Orbit`, anchored to Apple and team
   `UM52UU4B7L`. Also check the embedded helper and Quick Look extension.
5. Package `Orbit-<version>.zip` using `ditto -c -k --sequesterRsrc --keepParent`
   on the signed app. Build the DMG with `tools/dmg/make-dmg.sh <version>`.
   Recheck the unpacked ZIP; the updater installs that artifact, not the DMG.
6. Create the release as a draft, targeting the exact merged source commit.
   Upload both assets and publish with `gh release edit <tag> --draft=false
   --latest=false`. Release notes have English, `---`, Korean, then one
   `### Install` section with the two SHA-256 hashes.
7. Confirm `/releases/latest` still returns v1.7.1 and the stable release list
   selects the new version with its matching ZIP. Verify the published asset
   digests against the local files.

The initial 1.7.1 bridge must be built from its own merged source commit, before
the main app ID changes. Its version is 1.7.1 (37), with `com.lyu.orbit` as the
main ID and `com.lyu.orbit.quicklook` for Quick Look. Only that release is
published with `--latest=true`.

The main app and Quick Look use the new prefix in 1.7.2 (38). The privileged
helper keeps its existing ID and Mach service to avoid a second daemon. It
accepts only the two Orbit IDs signed by the same team. Preferences are copied
once to the new app domain; storage directories, Keychain service names and
saved menu-bar item keys are unchanged. System-managed approvals may need to
be granted again; do not reset or modify TCC or Keychain access controls.

Current releases use the configured Apple Development identity and are not
notarized. Notarization requires a Developer ID Application certificate and
Apple notarization credentials; do not describe a development-signed build as
Developer ID signed or notarized.
