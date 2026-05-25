# Releasing

This guide describes how to publish a versioned Symphony release. Releases are
built by the [`release` workflow](../.github/workflows/release.yml) and produce a
GitHub Release with self-contained macOS binaries (`arm64` and `x86_64`) built
via [Burrito](https://github.com/burrito-elixir/burrito).

## Versioning

- `mix.exs` `version:` is the single source of truth.
- Versions follow [semantic versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`).
- Versioning starts at `0.0.1`.

## Prepare a release

1. Bump `version:` in `mix.exs` to the new version.
2. Add a matching section to `changelog.txt`. The heading must be `## <version>`
   (no `v` prefix); its body becomes the GitHub Release notes:

   ```
   ## 0.0.2
   - Summary of what changed in this release.
   ```

3. Commit and merge the changes to `main`.

## Cut the release

Trigger the workflow manually — no local tagging is required:

1. Go to **Actions → release → Run workflow**.
2. Select the branch/ref to release (usually `main`, after merging the prep
   changes).
3. Enter the **version** (for example `0.0.2`, without the `v` prefix).

The workflow then:

1. Verifies the input version is valid semver and matches `mix.exs`.
2. Extracts the matching `changelog.txt` section as the release notes.
3. Builds the macOS binaries with `MIX_ENV=prod mix release`.
4. Creates the `v<version>` tag at the selected commit and publishes the GitHub
   Release with both binaries attached.

Each guard fails the run loudly rather than producing a partial release:

- version not semver,
- version does not match `mix.exs`,
- no `changelog.txt` entry for the version.

## Notes

- The workflow creates the `v<version>` tag at the commit of the ref you select,
  so run it from the commit you intend to ship.
- Only macOS binaries are produced today; there is no Linux binary or published
  Docker image.

## macOS Gatekeeper

The binaries are ad-hoc signed by Burrito but **not** signed with an Apple
Developer ID or notarized, because the project has no Apple Developer Program
membership. As a result, macOS Gatekeeper shows "Apple could not verify
`symphony_macos_arm64` is free of malware…" on first launch. This is a provenance
check, not a sign that anything is wrong with the binary.

The release workflow appends an **Installing on macOS** section to every release's
notes that tells users to clear the quarantine flag
(`xattr -d com.apple.quarantine …`) or right-click → **Open**.

To remove the warning entirely (silent launch), the build would need to codesign
each binary with a Developer ID Application certificate, run hardened-runtime
notarization via `xcrun notarytool`, and distribute the notarized archive. That
requires a paid Apple Developer account and is not set up today.
