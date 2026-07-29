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
./scripts/test_final_artifact_contract.sh
./scripts/test_final_candidate_validator.sh
./scripts/test_formal_publish.sh
./scripts/test_release_workflow_contract.sh
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

The tagged `.github/workflows/release-validation.yml` workflow is the production
entry point for candidate creation. Do not use a working-tree-only or unmerged
script as release infrastructure. The workflow and publisher fail closed unless:

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

Create a protected GitHub environment named `formal-release`. Restrict who can
approve it and configure these environment values:

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `GATEBEAM_DEVELOPER_ID_P12_BASE64` | Base64-encoded Developer ID Application and Installer identities exported together as PKCS#12. |
| Secret | `GATEBEAM_DEVELOPER_ID_P12_PASSWORD` | Password for that PKCS#12 export. |
| Secret | `GATEBEAM_NOTARY_PRIVATE_KEY_BASE64` | Base64-encoded App Store Connect API private key. |
| Secret | `GATEBEAM_NOTARY_KEY_ID` | App Store Connect API key ID. |
| Secret | `GATEBEAM_NOTARY_ISSUER_ID` | App Store Connect issuer ID. |
| Variable | `GATEBEAM_CODE_SIGN_IDENTITY` | Exact Developer ID Application common name. |
| Variable | `GATEBEAM_INSTALLER_SIGN_IDENTITY` | Exact Developer ID Installer common name. |
| Variable | `GATEBEAM_DEVELOPER_TEAM_ID` | Ten-character Apple Team ID. |

`build-candidate` and `publish-release` enter this protected environment, but
only `build-candidate` references signing or notarization secrets. It imports
credentials into an ephemeral Keychain, removes source key files immediately,
and deletes the Keychain in an `always()` cleanup step. `clean-machine` has no
environment and receives no signing or notarization secret. The publisher gets
only its job-scoped `contents: write` token through a private 0600 file.

After a successful push CI run for the tagged commit, dispatch:

```sh
gh workflow run release-validation.yml \
  --ref vVERSION \
  -f ci_run_id=CI_RUN_ID \
  -f bootstrap=false
```

Use `bootstrap=true` only for the first formal release. The workflow has three
trust stages:

1. `build-candidate` validates the tag, CI evidence, immutable release history,
   and rollback package; builds, signs, notarizes, staples, and verifies the app,
   PKG, and DMG; writes `SHA256SUMS`, schema 4 `release-manifest.json`, and
   `candidate-envelope.json`; then uploads that frozen directory once.
2. `clean-machine` downloads that artifact by the exact artifact ID. On a fresh
   `macos-14` runner it validates the envelope and all file hashes, Developer ID
   signatures, notarization tickets, Gatekeeper, full ZIP/flat-PKG/DMG
   structural allowlists and the exact Gatebeam path/type/mode closure, matching
   app tree hashes, fresh install, upgrade, previous-version rollback, injected
   transaction rollback, reinstall, and uninstall. Only then does it upload
   `clean-machine-attestation.json`.
3. `publish-release` starts only after both upstream jobs succeed and invokes
   `release_formal.sh` inside the same repository-wide workflow concurrency
   group. It downloads the candidate and attestation from the current run and
   validates repository/run/event/HEAD/workflow/job/step
   provenance, artifact IDs and protected SHA-256 digests, safe archive paths,
   the complete byte inventory, current immutable history, and the attestation.
   It cannot build, sign, notarize, staple, or rewrite a candidate. Under one
   repository-wide local lock and one remote draft-release lock, it creates the
   draft through the GitHub API, uploads the seven frozen assets, verifies every
   asset ID/name/size/digest, rechecks tag/history/run/job/attestation evidence,
   publishes the draft, requires `immutable: true`, and only then exposes the
   same bytes in `dist/release-VERSION`.

The formal PKG must be one flat component. Any `Distribution` package is
rejected before installation, including packages containing `script`,
`installation-check`, `volume-check`, an external script reference, or an
extra component. Before `pkgutil --expand-full`, the validator checks the raw
XAR TOC and gzip/odc-cpio payload and scripts for exact paths, normalized-name
collisions, types, modes, ownership, hard links, entry counts, and logical byte
budgets. The expanded tree is checked again. ZIP and DMG inputs reject sparse
containers and enforce the same bounded APP closure.

The XAR TOC contract accepts the exact productsign flat-package signature
shape: SHA-1 TOC range, one RSA signature with an XMLDSIG X.509 chain, and an
optional contiguous CMS `x-signature` timestamp chain. It still requires
exactly `Bom`, `Payload`, `Scripts`, and `PackageInfo`, complete member
checksums/encoding/ranges, non-overlapping heap ranges, and no other root file.
The committed structural fixture and a locally available Apple-signed flat PKG
exercise parser compatibility; neither replaces the production Gatebeam
Developer ID Installer signature and trusted-timestamp E2E gate.

Candidate and attestation transport ZIPs are opened once with `O_NOFOLLOW`.
The same descriptor is hashed, rewound, extracted, and checked again for
device, inode, mode, link count, size, mtime, and ctime stability. The app ZIP
uses the same descriptor-bound pattern and also binds extraction to its
manifest SHA-256. A path replacement after hashing cannot select new bytes.

Do not run stage 3 manually. The public `release_formal.sh` entry is production
bound to the current `publish-release` Actions job, run attempt, repository ID,
tag, workflow SHA, and `HEAD`. Candidate creation remains a separate private
workflow entry.

The script never accepts a repository, evidence URL, previous build number,
rollback version, rollback URL, or rollback asset from the caller. It uses only
fixed HTTPS REST endpoints under `api.github.com/repos/naifuliang/gatebeam`,
with connection and total timeouts, environment proxies disabled, no redirects
for JSON, and HTTPS-only bounded redirects for protected release-asset bytes.
Every network, HTTP, JSON, pagination, digest, checksum, and asset failure stops
the release. Mutation transport failures are reconciled rather than guessed:
401, 403, and 404 are definite rejections; a missing response, 5xx, or malformed
success body triggers paginated read-back. Draft ownership uses a
per-publisher nonce. Asset recovery requires one matching name/ID/size/SHA-256
tuple, and publish recovery requires the exact immutable tag and seven-asset
byte set. An ambiguous or non-unique read-back fails closed.
The executable negative matrix covers draft POST, first asset upload, and
publish PATCH independently under non-executed 401, 403, 404, and 500
responses, requiring cleanup to leave no draft, asset, local release, or public
release. Separate cases retain response-loss and server-applied-then-500
reconciliation.

Before candidate creation and again before publication, the tooling requires
`GET /repos/naifuliang/gatebeam/immutable-releases` to return `enabled: true`.
Both evidence runs must belong to the fixed public repository and have the
exact workflow path/name and `head_sha`. CI must be a completed successful
`push`. The tag-bound final `workflow_dispatch` must have completed successful
build and clean-machine jobs plus the one currently executing publisher job;
the publisher rechecks that exact state immediately before publication.
Pull-request refs, another repository, run attempt, version, tag, artifact, or
replayed attestation are rejected.

For every release, the tooling paginates the complete release collection and
parses strict SemVer 2.0, including prerelease and build metadata. Precedence
uses SemVer numeric and alphanumeric rules (`alpha.2 < alpha.10`) and ignores
build metadata; two releases with equal precedence are rejected as ambiguous.
Legal prereleases are part of history and must agree with GitHub's
`prerelease` flag. It downloads every immutable formal release manifest,
requires SemVer precedence and `CFBundleVersion` values to increase in the same
order, rejects duplicate or forked version/build history, and selects the unique
highest release for rollback. New schema 4 releases contain the ZIP,
PKG, DMG, `candidate-envelope.json`, `release-manifest.json`, `SHA256SUMS`, and
`clean-machine-attestation.json`; reviewed legacy releases remain readable.
It resolves the tag commit, downloads every protected asset, and requires the
manifest, attestation, and
checksum file to describe exactly one ZIP, PKG, and DMG with matching names,
types, hashes, and byte counts. The rollback PKG must also be a single flat
component; every `Distribution` is rejected. Its PackageInfo has a complete
element and attribute allowlist and must identify Gatebeam with identifier
`io.github.naifuliang.gatebeam`, the previous manifest version/build, the fixed
`/Applications` installation root, and only the reviewed postinstall entry.
Only that component's sole
`Payload/Gatebeam.app`, installed as `/Applications/Gatebeam.app`, is accepted;
apps in Scripts, Resources, another component, or another payload location
cannot satisfy rollback validation. The expanded root, component, Payload, and
app must remain canonical and contained; every symlink or reparse entry and
every multiply linked or non-regular file inside the app bundle is rejected.
The APP is exactly `Contents/Info.plist`, `Contents/MacOS/Gatebeam`,
`Contents/Resources/AppIcon.icns`, and
`Contents/_CodeSignature/CodeResources` plus their expected directories and
modes. There are no permitted nested code objects. Extras such as
`Contents/unexpected.dylib`, casefold aliases, and NFC/NFD collisions are
rejected independently in ZIP, PKG, and DMG.
Its version, build, Bundle ID, and
signature, plus the PKG signature, must match the validated previous manifest
and signing contract. The new `CFBundleVersion` must be greater than that
manifest's `buildVersion`; rollback metadata is derived from the same immutable
release.

The first formal release is the only exception and must be explicit:

```sh
export GATEBEAM_RELEASE_BOOTSTRAP=1
```

Bootstrap succeeds only when the published releases API returns an empty list.
It records `previousBuildVersion` as `0` and `rollback.available` as `false`;
it cannot invent a historical rollback version or URL. Bootstrap is rejected
as soon as any published release exists.

`GATEBEAM_GITHUB_TOKEN_FILE` is required for every formal release and must name
a canonical, caller-owned `0600` regular file with one link. Use a fine-grained
token scoped to the fixed `naifuliang/gatebeam` repository with at least
Administration (read), Actions (read), and Contents (write). Contents write is
used only to create the draft, upload its frozen assets, publish it, and clean
up this publisher's abandoned draft. The environment and
curl argv contain only file paths, never the Bearer value. Each request uses a
private `0600` curl config that is deleted immediately after curl returns; the
overall cleanup removes any remainder. The token is never written to logs, the
release manifest, or retained release output. Delete the caller-owned input file
with the trap above. This boundary does not claim to prevent the same user from
reading process memory.

Test-only command overrides are accepted only with the explicit test-mode flag
inside a marked `/private/tmp` fixture. There is no unmarked production
override for candidate, provenance, attestation, or digest validation.

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

The workflow must remain bound to the release `HEAD`. Its first macOS job creates
the final Developer ID signed, notarized, and stapled candidate; its second
isolated macOS job downloads that candidate by artifact ID and tests those exact
bytes. The second job must not rebuild and must not receive the protected
signing environment. It verifies a real system fresh install, previous-to-current
upgrade, current-to-previous rollback, re-upgrade, injected-failure restoration,
and uninstall before writing its attestation.

Before any `sudo installer` call, the validator applies a complete container
allowlist. The app ZIP may extract only `Gatebeam.app` and rejects traversal,
normalization aliases, duplicates, links, special files, unsafe modes, and
oversize expansion. The PKG must have exactly one component; PackageInfo,
install location, BOM, payload, and tagged postinstall script closure must
match the expected app with no extras. The DMG root may contain only
`Gatebeam.app` and `Applications -> /Applications`. The complete app tree
content and mode digest must agree across ZIP, PKG, and DMG.

Candidate transport is accepted only when the GitHub artifact ID, protected
archive digest, envelope digest, manifest digest, and every contained file hash
agree. Archive traversal, duplicate entries, symlinks, hard links, special
files, non-canonical paths, extra files, cross-repository evidence, cross-run
attempt evidence, and stale attestations all fail closed. Do not publish
hostnames, public addresses, tokens, router exports, or screenshots containing
them.

## Manifest, Tag, and GitHub Release

Create a release manifest containing:

- Product and version.
- Exact source merge commit and annotated tag, which must resolve to the same
  commit.
- `CFBundleShortVersionString` and the monotonically increasing
  `CFBundleVersion`, plus `previousBuildVersion` derived from the latest
  immutable release manifest or `0` in API-proven bootstrap mode.
- Artifact filenames, byte sizes, and SHA-256 checksums, including the public
  `candidate-envelope.json` asset.
- Bundle ID, Team ID, signing certificate common names and non-secret
  fingerprints.
- Notary submission IDs and `Accepted` status, with sensitive fields redacted.
- Supported macOS version range and architectures, build-host platform, and
  Xcode/Swift toolchain versions.
- Exact release-suite, TSan, and clean-machine evidence URLs for the release
  commit.
- Final-artifact repository ID, workflow ref/SHA, run ID/attempt, build and
  validation job names, candidate and attestation artifact names, and source
  commit/tag. The separate attestation additionally binds the candidate artifact
  ID/digest, envelope hash, manifest hash, and every candidate file hash.
- Known limitations and rollback asset metadata derived from the latest
  immutable release, or an explicit no-history rollback record for bootstrap.

`prepare_release_candidate.sh` writes these fields from the final stapled
artifacts and validated inputs. It records byte counts after candidate staging,
extracts leaf-certificate SHA-256 fingerprints from the signed app and DMG,
records the trusted installer certificate chain, and stores `Accepted` for all
three notarization records. Notary logs are checked inside the protected build
job and then removed; they are not candidate or release assets. The Keychain
profile name is never a manifest field or retained output.

Re-run the privacy scan against the tag and release notes and push the annotated
tag once. `release_formal.sh` performs the immutable release sequence itself;
do not use `gh release create`, `gh release upload`, or a browser to finish it.
The publisher holds the global remote draft lock, uploads the final ZIP, PKG,
DMG, `candidate-envelope.json`, `release-manifest.json`, `SHA256SUMS`, and
`clean-machine-attestation.json`, verifies their API IDs, sizes and SHA-256
digests, rechecks the remote annotated tag and complete immutable-history
snapshot immediately before publication, and requires the fresh release API
response to report `immutable: true`. No production step rebuilds or rewrites
an asset after clean-machine attestation.
If a mutation response is lost, the publisher uses its ownership nonce and the
frozen asset SHA-256 values to paginate and reconcile remote state. It resumes
only from one exact draft/asset/release match; it never treats a retry response
or tag-name match alone as proof of success.

The envelope hashes candidate containers and rollback fixtures, while the
finalized manifest and `SHA256SUMS` hash the envelope. This acyclic closure lets
an auditor download public assets, recompute the actual
`candidateEnvelopeSHA256`, compare it with the manifest, checksums, and
attestation, and then verify every container byte.

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
