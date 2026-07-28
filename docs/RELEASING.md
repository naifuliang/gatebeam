# Releasing Gatebeam

This guide separates reproducible developer previews from formal releases.
Passing preview checks is necessary, but it is not evidence of Apple
notarization or public reachability.

## Release Classes

### Developer Preview

A Developer Preview is intended for source review and controlled testing:

- `build_app.sh` uses an ad-hoc signature with hardened runtime.
- The PKG is unsigned.
- The app, PKG, and DMG are not notarized or stapled.
- The Cloudflare token ACL is bound to the exact preview build.
- Artifacts must be labeled **Developer Preview** in notes and filenames or
  accompanying manifests.
- Do not describe a preview as a formal, production, signed, notarized, or
  generally available release.
- Do not infer public reachability from a DNS update, local TCP check, router
  response, test fixture, or CI result.

### Formal Release

A Formal Release requires all preview gates plus:

- An active **Developer ID Application** certificate for the app.
- An active **Developer ID Installer** certificate for the PKG.
- Hardened runtime, secure timestamps, and the expected Bundle ID and Team ID.
- Apple notarization acceptance for every distributed container.
- A stapled and validated notarization ticket for the app, DMG, and PKG.
- Gatekeeper assessment and clean-machine installation/upgrade verification.
- Final checksums, a manifest, release notes, rollback material, and a signed or
  otherwise protected release record.
- Repository-level GitHub Immutable Releases enforcement and an immutable
  published release whose assets and tag are covered by GitHub's release
  attestation.

Do not publish a Formal Release when any item is missing.

## Apple References

- [Notarizing macOS software before distribution](https://developer&#46;apple&#46;com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer&#46;apple&#46;com/documentation/security/customizing-the-notarization-workflow)
- [Resolving common notarization issues](https://developer&#46;apple&#46;com/documentation/security/resolving-common-notarization-issues)
- [TN3147: Migrating to the latest notarization tool](https://developer&#46;apple&#46;com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)

Use `notarytool`; Apple no longer accepts `altool` notarization submissions.

## Credential Handling

Store notarization credentials once in Keychain and refer only to the profile
name afterward:

```sh
xcrun notarytool store-credentials GatebeamNotary
```

Leave credential options unspecified so `notarytool` prompts interactively. For
an Apple ID flow, provide the Apple ID and Team ID only when prompted or
requested, then enter the app-specific password at the secure prompt. For an
App Store Connect API-key flow, keep the private key outside the repository and
follow the same Keychain-profile approach.

Never:

- Commit an Apple ID, app-specific password, API key, issuer ID, private key, or
  certificate export.
- Put those values in shell history, environment variables, CI command echo,
  build logs, release notes, or issue attachments.
- Print `security` output that reveals credential values.
- Upload a Keychain, provisioning material, or signing-key backup as an
  artifact.

CI should receive a temporary signing Keychain through the platform's secret
store and must mask all values. Notarization commands should use
`--keychain-profile GatebeamNotary`.

## Prepare the Release

1. Prepare the version, Changelog, release tooling, and release notes in a
   dedicated release-preparation pull request.
2. Choose the release version and update both version keys together:
   `CFBundleShortVersionString` is the user-visible semantic version, while
   `CFBundleVersion` is a numeric build version that must be strictly greater
   than every previously distributed Gatebeam build.
3. Confirm that all release-preparation changes pass review and merge the pull
   request with a merge commit. Gatebeam does not squash pull requests.
4. Record that exact merge commit as `RELEASE_COMMIT`. Do not make a separate
   artifact, documentation, version, or release-tooling commit afterward.
5. Create the matching annotated tag, such as `v0.5.1`, directly on
   `RELEASE_COMMIT`. Never tag an earlier preparation commit, reuse a tag, or
   move a published tag.
6. Create a fresh release worktree at the tag. The checked-out `HEAD`, resolved
   tag commit, archived build source, manifest commit, and source commit used for
   every artifact must all be exactly `RELEASE_COMMIT`.
7. Require that release worktree to be clean before the first build:

```sh
test -z "$(git status --porcelain)"
git diff --check
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist
test "$(git rev-parse HEAD^{commit})" = \
  "$(git rev-parse "vVERSION^{commit}")"
test "$(git cat-file -t "refs/tags/vVERSION")" = tag
test "$(git rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')" -eq 3
```

Verify the visible version matches `VERSION`, the build version is the reviewed
monotonically increasing value, and the annotated tag is `vVERSION`. Build,
sign, package, notarize, staple, and checksum only from that exact merge commit,
without source edits or commits between stages. A build from one SHA must never
be attached to a tag resolving to another SHA.

## Required Gates

Run the complete repository suite:

```sh
./scripts/test_backend.sh
./scripts/test_proxy_policy.sh
./scripts/test_integration_contract.sh
./scripts/test_integration_tsan.sh
./scripts/test_keychain_identity.sh
./scripts/test_upgrade.sh
./scripts/test_clean_machine_validation.sh
./scripts/test_ui_validation.sh
./scripts/test_build_assets.sh
./scripts/test_release_pipeline.sh
./scripts/build_app.sh
./scripts/test_privacy.sh
codesign --verify --deep --strict ./dist/Gatebeam.app
git diff --check
```

Build before the privacy gate so the scan covers the final Gatebeam binary as
well as the reviewed source.

For UI changes, regenerate every canonical Aqua and Dark Aqua state and inspect
each image for alignment, clipping, overlap, disabled state, scroll reachability,
and legibility. Record which IPv4-only, IPv6-only, dual-stack, proxy, VPN/TUN,
and router environments were exercised. Keep all environment details redacted.

If a reviewed formal-pipeline script is present in the exact tagged release
commit, it may automate the manual stages below. Do not use or document a
working-tree-only or unmerged script as release infrastructure. The script must
fail closed unless:

- The worktree is clean, `HEAD` has exactly two parents, and the annotated
  release tag resolves exactly to `HEAD`.
- Both bundle version keys match the reviewed release preparation, and
  `CFBundleVersion` is greater than the previous distributed build.
- The app, PKG, and DMG satisfy the required Developer ID identities and secure
  timestamp contracts before notarization.
- Every notarization status and log is `Accepted` without issues.
- Every accepted ticket is stapled and validated.
- Checksums and the manifest are generated only from the final stapled
  artifacts, and output publication is atomic.

`release_formal.sh` accepts only the numeric run IDs for the two GitHub Actions
evidence records:

```sh
export GATEBEAM_RELEASE_CI_RUN_ID='CI_RUN_ID'
export GATEBEAM_RELEASE_CLEAN_MACHINE_RUN_ID='CLEAN_MACHINE_RUN_ID'
export GATEBEAM_GITHUB_TOKEN='FINE_GRAINED_TOKEN'
```

The script never accepts a repository, evidence URL, previous build number,
rollback version, rollback URL, or rollback asset from the caller. It uses only
fixed HTTPS REST endpoints under `api.github.com/repos/naifuliang/gatebeam`,
with connection and total timeouts, environment proxies disabled, no redirects
for JSON, and HTTPS-only bounded redirects for protected release-asset bytes.
Every network, HTTP, JSON, pagination, digest, checksum, and asset failure stops
the release.

Before building, the script requires
`GET /repos/naifuliang/gatebeam/immutable-releases` to return `enabled: true`.
For both run IDs it fetches the workflow run and its jobs/steps, then verifies
the public repository, exact workflow path and name, `head_sha == HEAD`,
`completed/success`, the required job, and every required step. The regular CI
record must be a `push` run of `.github/workflows/ci.yml`; pull-request and
merge-ref runs are rejected. The clean-machine record must be a
`workflow_dispatch` run of `.github/workflows/release-validation.yml`, whose
isolated test actually runs installation, upgrade, injected-failure rollback,
and uninstall validation. Only after those machine checks validate may the
manifest record `Passed`.

For every release after the first, the script reads `/releases/latest`, requires
that published release to be immutable and to contain exactly the ZIP, PKG,
DMG, `release-manifest.json`, and `SHA256SUMS` assets. It resolves the tag
commit, downloads all five protected assets, and requires the manifest and
checksum file to describe exactly one ZIP, PKG, and DMG with matching names,
types, hashes, and byte counts. The rollback PKG is expanded; its internal
Gatebeam app version, build, Bundle ID, and signature, plus the PKG signature,
must match the validated previous manifest and signing contract. The new
`CFBundleVersion` must be greater than that manifest's `buildVersion`;
rollback metadata is derived from the same immutable release.

The first formal release is the only exception and must be explicit:

```sh
export GATEBEAM_RELEASE_BOOTSTRAP=1
```

Bootstrap succeeds only when the published releases API returns an empty list.
It records `previousBuildVersion` as `0` and `rollback.available` as `false`;
it cannot invent a historical rollback version or URL. Bootstrap is rejected
as soon as any published release exists.

`GATEBEAM_GITHUB_TOKEN` is required for every formal release. Use a fine-grained
token scoped to the fixed `naifuliang/gatebeam` repository with at least
Administration (read), Actions (read), and Contents (read). The script sends it
as a Bearer credential on every GitHub API request through a mode-`0600`
temporary curl config, unsets it before child processes run, and never writes
the token to logs, the release manifest, or retained release output.

## Build and Sign

List identities without copying certificate material into logs:

```sh
security find-identity -v -p codesigning
```

Build the app with the expected Developer ID Application identity and Team ID:

```sh
GATEBEAM_CODE_SIGN_IDENTITY='Developer ID Application: ORGANIZATION (TEAMID)' \
GATEBEAM_DEVELOPER_TEAM_ID='TEAMID' \
./scripts/build_app.sh
```

The build must have hardened runtime, a secure timestamp, the expected Bundle ID
and Team ID, and no development-only dangerous entitlement. Verify before
packaging:

```sh
codesign --verify --deep --strict --verbose=2 dist/Gatebeam.app
codesign --display --verbose=4 dist/Gatebeam.app
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  dist/Gatebeam.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  dist/Gatebeam.app/Contents/Info.plist
```

Create a ZIP solely for app notarization without losing bundle metadata:

```sh
ditto -c -k --keepParent dist/Gatebeam.app dist/Gatebeam-app-notary.zip
xcrun notarytool submit dist/Gatebeam-app-notary.zip \
  --keychain-profile GatebeamNotary --wait
xcrun notarytool log SUBMISSION-ID \
  --keychain-profile GatebeamNotary
xcrun stapler staple dist/Gatebeam.app
xcrun stapler validate dist/Gatebeam.app
spctl --assess --type execute --verbose=4 dist/Gatebeam.app
```

Confirm the submission status is `Accepted` before stapling. Review the
notarization log and stop on warnings that affect signing, entitlements, nested
code, or executable integrity.

Recreate the distributable app archive from the now-stapled app. Do not publish
the pre-stapling submission ZIP:

```sh
rm dist/Gatebeam-app-notary.zip
ditto -c -k --keepParent dist/Gatebeam.app dist/Gatebeam-VERSION.zip
```

Package only the signed, stapled app:

```sh
./scripts/package_dmg.sh
./scripts/package_pkg.sh
productsign --sign 'Developer ID Installer: ORGANIZATION (TEAMID)' \
  --timestamp \
  dist/Gatebeam-VERSION.pkg dist/Gatebeam-VERSION-signed.pkg
```

Keep the unsigned intermediate private and distribute only the signed PKG.
Before notarization, verify that the installer has a trusted Developer ID
Installer signature, the expected Team ID, and a secure timestamp:

```sh
pkgutil --check-signature dist/Gatebeam-VERSION-signed.pkg
```

The generated DMG must also be signed with Developer ID Application and a secure
timestamp before it is submitted to Apple:

```sh
codesign --force \
  --sign 'Developer ID Application: ORGANIZATION (TEAMID)' \
  --timestamp \
  dist/Gatebeam-VERSION.dmg
codesign --verify --strict --verbose=2 dist/Gatebeam-VERSION.dmg
codesign --display --verbose=4 dist/Gatebeam-VERSION.dmg
```

Confirm the DMG signing details show the expected Developer ID Application
authority, Team ID, and a nonempty secure timestamp. Do not submit an unsigned,
ad-hoc-signed, incorrectly identified, or unverified DMG.

## Notarize and Staple Containers

Submit each container exactly as it will be distributed:

```sh
xcrun notarytool submit dist/Gatebeam-VERSION.dmg \
  --keychain-profile GatebeamNotary --wait
xcrun notarytool submit dist/Gatebeam-VERSION-signed.pkg \
  --keychain-profile GatebeamNotary --wait
xcrun notarytool log DMG-SUBMISSION-ID \
  --keychain-profile GatebeamNotary
xcrun notarytool log PKG-SUBMISSION-ID \
  --keychain-profile GatebeamNotary
```

Only after both submissions return `Accepted` and their logs contain no issues,
staple and validate:

```sh
xcrun stapler staple dist/Gatebeam-VERSION.dmg
xcrun stapler validate dist/Gatebeam-VERSION.dmg
xcrun stapler staple dist/Gatebeam-VERSION-signed.pkg
xcrun stapler validate dist/Gatebeam-VERSION-signed.pkg
```

After a notarization submission is accepted, stapling that accepted ticket is
the only permitted mutation of the submitted artifact. Apart from stapling,
never modify, re-sign, or repackage it. Any other byte change requires rebuilding
the affected artifact, resubmitting it, and stapling the newly accepted ticket.

## Final Verification

Verify the final artifacts, not an earlier staging copy. Generate checksums and
the release manifest only after the app, DMG, and PKG have all been stapled and
their tickets validated:

```sh
hdiutil verify dist/Gatebeam-VERSION.dmg
pkgutil --check-signature dist/Gatebeam-VERSION-signed.pkg
spctl --assess --type open --context context:primary-signature \
  --verbose=4 dist/Gatebeam-VERSION.dmg
spctl --assess --type install --verbose=4 \
  dist/Gatebeam-VERSION-signed.pkg
shasum -a 256 dist/Gatebeam-VERSION.dmg \
  dist/Gatebeam-VERSION-signed.pkg \
  dist/Gatebeam-VERSION.zip
```

Dispatch `.github/workflows/release-validation.yml` at the exact release tag.
The resulting run must remain bound to the release `HEAD` and pass its single
isolated macOS job. That job:

- Builds the application from the checked-out SHA.
- Runs the package migration and developer installer fixtures, including fresh
  install, upgrade, repeated install, and failures injected across the
  transaction with previous-state restoration checks.
- Installs into a fresh temporary HOME, verifies the application, removes the
  application and any owned launch agent, and proves no transaction state
  remains.
- Exercise only approved test DNS names and router mappings.
- Do not publish hostnames, public addresses, tokens, router exports, or
  screenshots containing them.

## Manifest, Tag, and GitHub Release

Create a release manifest containing:

- Product and version.
- Exact source merge commit and annotated tag, which must resolve to the same
  commit.
- `CFBundleShortVersionString` and the monotonically increasing
  `CFBundleVersion`, plus `previousBuildVersion` derived from the latest
  immutable release manifest or `0` in API-proven bootstrap mode.
- Artifact filenames, byte sizes, and SHA-256 checksums.
- Bundle ID, Team ID, signing certificate common names and non-secret
  fingerprints.
- Notary submission IDs and `Accepted` status, with sensitive fields redacted.
- Supported macOS version range and architectures, build-host platform, and
  Xcode/Swift toolchain versions.
- Exact release-suite, TSan, and clean-machine evidence URLs for the release
  commit.
- Known limitations and rollback asset metadata derived from the latest
  immutable release, or an explicit no-history rollback record for bootstrap.

`release_formal.sh` writes these fields from the final stapled artifacts and
validated inputs. It records byte counts after publication staging, extracts
leaf-certificate SHA-256 fingerprints from the signed app and DMG, records the
trusted installer certificate chain, and stores `Accepted` for all three
notarization records. The Keychain profile name is never a manifest field and
must not appear in the manifest or retained notary logs.

Re-run the privacy scan against the tag and release notes. Reconfirm that the
already-created annotated tag points to the exact merge commit used to build
the artifacts, then push it once. Follow GitHub's immutable release sequence:

1. Create the GitHub Release as a draft for the exact annotated tag.
2. Upload every intended release asset to the draft: the final ZIP, PKG, DMG,
   `release-manifest.json`, and `SHA256SUMS`. Verify every local checksum and
   uploaded asset before publication; do not plan to add or replace an asset
   later.
3. Publish the draft. With Immutable Releases enabled, publication locks the
   release assets and tag and creates GitHub's release attestation.
4. Require the release API to report `immutable: true`, run
   `gh release verify vVERSION`, and run `gh release verify-asset vVERSION`
   against each local uploaded asset. A human statement or screenshot is not
   release evidence.

Release notes are derived from `CHANGELOG.md` and must clearly distinguish
Developer Preview notes from Formal Release notes. See GitHub's
[Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
and
[Verifying the integrity of a release](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/verify-release-integrity)
for the protection and attestation model.

## Rollback and Revocation

Before publishing, retain the previous verified artifacts, manifest, checksums,
and source tag. Document configuration compatibility and whether rollback
requires token reauthorization.

If a release is defective but credentials remain trustworthy:

1. Publish an advisory that identifies the affected immutable version; do not
   attempt to edit its locked assets or tag.
2. Restore the previous verified immutable release as the recommended download.
3. Publish a fixed version with a new tag and complete the full process again.

If a signing key, notarization credential, Cloudflare secret, or distributed
artifact may be compromised:

1. Stop distribution immediately.
2. Revoke or rotate the affected credential through Apple or Cloudflare.
3. Contact Apple Developer Support when notarization tickets or Developer ID
   certificates may require revocation.
4. Preserve evidence privately; do not place secrets in a public incident issue.
5. Publish a security advisory and replacement only after independent review.

Never solve rollback by force-moving a public tag, overwriting checksums, or
silently replacing an attached binary.
