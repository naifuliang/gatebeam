# ADR 0001: Modern Keychain Storage

- Status: Proposed
- Date: 2026-07-28
- Owners: Gatebeam maintainers
- Scope: Cloudflare API token storage on macOS

## Context

Gatebeam must keep a Cloudflare API token available to a menu bar app that performs
background DDNS checks. The token must survive ordinary formal updates without
allowing an unrelated or spoofed process to read it, and background work must never
open a Keychain authorization dialog.

macOS has two Keychain implementations with different identity models. Apple
[TN3137: On Mac keychain APIs and implementations][apple-tn3137] says that `SecItem`
targets the file-based Keychain by default on macOS, while setting
`kSecUseDataProtectionKeychain` to `true` targets the Data Protection Keychain.
The file-based implementation uses `SecAccess` access-control lists. The Data
Protection Keychain uses signed-app access groups, optionally supplemented by
`SecAccessControl`. Apple recommends the Data Protection Keychain for new work, but
also states that existing file-based items must be read through the file-based
implementation and migrated explicitly.

The Data Protection Keychain is available only in a user login context. Gatebeam's
menu bar process is intended to run there, including when started by its per-user
LaunchAgent, but that runtime topology must be demonstrated by the prototype gate
on every supported macOS configuration. This ADR does not extend Data Protection
Keychain access to a system daemon or another executable.

For Data Protection Keychain items, Apple defines an app's available groups from
its signed entitlements. The ordered list consists of explicit Keychain access
groups, the signed application identifier, and eligible application groups. An
item belongs to exactly one `kSecAttrAccessGroup`. If an add operation omits that
attribute, Keychain Services assigns the app's first available group as its
default. A group that the signer is not entitled to use fails with
`errSecMissingEntitlement`. See [Sharing access to keychain items among a
collection of apps][apple-sharing] and [`kSecAttrAccessGroup`][apple-access-group].

Apple documents that Xcode forms the macOS `com.apple.application-identifier` from
the App ID prefix and Bundle ID. Modern accounts commonly use the Team ID as the
App ID prefix, but Gatebeam must read and validate the actual profile and signed
entitlement rather than assume they are equal. Apple also documents that these
restricted entitlement claims must be authorized by a matching provisioning
profile, including for Developer ID distribution. An additional
`keychain-access-groups` claim has the same profile-authorization boundary. See
[Creating distribution-signed code for macOS][apple-distribution-signing] and
[TN3125: Inside Code Signing: Provisioning Profiles][apple-tn3125].

Gatebeam's current preview build is signed ad hoc by a custom shell pipeline. It
has a stable Bundle ID but no stable Team ID or profile-authorized application
identifier entitlement. Therefore, neither Apple documentation nor current
Gatebeam tests prove that an ad-hoc preview gets a stable Data Protection Keychain
default group across builds. This is an explicit unknown, not a solved property.

## Current Implementation

`KeychainStore` currently defaults to the file-based Keychain:

- Current service: `io.github.naifuliang.gatebeam.cloudflare-token.v3`
- Account: `cloudflare-api-token`
- Older service eligible for explicit migration:
  `com.local.RemoteControlNetwork.secure-v2`
- Item class: `kSecClassGenericPassword`
- `kSecUseDataProtectionKeychain`: absent by default
- Access control: `kSecAttrAccess` containing a `SecAccess` created for the current
  application

The current application is accepted only after Gatebeam validates the live code
signature:

- **Developer Preview:** hardened runtime and a nonzero runtime version are
  required; there is no Team ID or secure timestamp; the designated requirement
  must consist only of the current build's actual `cdhash` value or values.
  Replacing the preview changes its identity, so the user must explicitly choose
  **Authorize Token** to refresh the ACL for that exact build.
- **Formal Developer ID build:** the signed and expected Bundle IDs must match; the
  signed and expected Team IDs must match; a secure timestamp is required; and the
  designated requirement must contain the Apple generic anchor, Developer ID
  intermediate and leaf certificate OIDs, Bundle ID, and Team ID without an
  alternative `or` branch. This lets updates that satisfy the same Team-qualified
  Developer ID requirement retain access.

This is intentionally stronger than identifier-only persistence. Gatebeam must
never replace either policy with a file-Keychain ACL that trusts only a Bundle ID.

Every current background read, write, and delete sets both:

- `LAContext.interactionNotAllowed = true`
- `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail`

Only an explicit user action may use an interactive query. Legacy discovery and
migration are confined to **Authorize Token**; startup and periodic checks do not
enumerate legacy services.

For an existing `cloudflare-token.v3` item, the current
`authorizeCurrentOrMigrateLegacy` implementation uses this order:

1. Read `v3` interactively.
2. Rewrite the same bytes to `v3` with `refreshAccess: true`. This creates a fresh
   `SecAccess` from the validated current application requirement: an exact
   `cdhash` ACL for Preview, or the current Team-qualified Developer ID requirement
   for a formal build.
3. Read `v3` again with the background, no-UI query and require the exact value.
4. Only after that verification, inspect and remove an older service.

When `v3` is absent, the same implementation interactively reads an older service,
writes those bytes to `v3` with `refreshAccess: true`, background-verifies `v3`,
and only then removes the older item. A write or verification failure throws
before legacy deletion. The caller latches the failure, so startup and timers
cannot retry interactively; a later retry requires another explicit user action.

`KeychainStore(useDataProtectionKeychain: true)` is an unshipped prototype hook.
It sets `kSecUseDataProtectionKeychain`, uses
`io.github.naifuliang.gatebeam.data-protection.v1`, and adds
`kSecAttrAccessibleAfterFirstUnlock`. It does not set `kSecAttrAccessGroup`, does
not migrate the production `v3` service, and is not selected by the production
composition root. Its presence is not evidence that migration, cross-build access,
signing entitlements, or rollback have been solved.

## Problem

The file-based Keychain path protects current releases, but depends on legacy ACL
APIs including `SecTrustedApplicationCreateFromPath` and `SecAccessCreate`. Those
APIs are deprecated, and TN3137 describes the file-based implementation as being
on the road to deprecation. Keeping them forever creates a compatibility risk.

A direct switch to the Data Protection Keychain would create different risks:

- The current ad-hoc preview has no proven stable, profile-authorized
  application-ID group across builds.
- Gatebeam's manual signing pipeline does not yet embed and validate a provisioning
  profile that authorizes `com.apple.application-identifier` or an additional
  Keychain access-group claim.
- A destination item and a source item live in different Keychain
  implementations, so no atomic cross-implementation move exists.
- Deleting the source too early would break rollback to an older Gatebeam build.
- Performing migration from startup or a timer could display security UI or create
  a prompt loop.

The architecture must modernize formal releases without turning an unproven preview
identity into persistent trust or sacrificing recovery.

## Goals

1. Prefer the Data Protection Keychain for formally signed Gatebeam releases.
2. Bind persistent access to a validated signed-app identity and the narrowest
   private access group.
3. Preserve background token availability after ordinary same-signer updates.
4. Migrate without losing the only readable copy and retain a bounded rollback
   path.
5. Guarantee that startup, timers, diagnostics, tests, and screenshots cannot
   request Keychain UI.
6. Keep Developer Preview behavior fail-closed until isolated evidence proves a
   stable and non-spoofable Data Protection Keychain identity.
7. Remove legacy ACL APIs only after objective release and compatibility gates
   pass.

## Non-goals

- Sharing the Cloudflare token with unrelated apps, command-line tools, helpers, or
  a system daemon.
- Synchronizing the token through iCloud Keychain.
- Treating notarization alone as Keychain authorization.
- Preserving access across a Team transfer without a separately designed and
  tested transfer migration.
- Claiming that the existing Data Protection Keychain constructor flag is
  production-ready.

## Candidate Solutions

| Candidate | Update identity | Advantages | Risks and limits | Decision |
| --- | --- | --- | --- | --- |
| Keep file Keychain plus current `SecAccess` | Exact build for preview; Team-qualified Developer ID requirement for formal | Requirement classification and no-UI query policy have unit coverage; supports explicit migration from older service | Real Keychain cross-build ACL and SecurityAgent behavior are not yet release-matrix evidence; depends on deprecated APIs | Retain temporarily as source, rollback mirror, and preview fallback |
| Data Protection Keychain with an omitted group | First signed group on add; all available groups on unqualified queries | Minimal attributes | A later entitlement can change the first group; read/update/delete can collide with an item in another available group | Prototype comparison only; rejected for production queries |
| Data Protection Keychain with `kSecAttrAccessGroup` equal to the signed application ID | Profile-authorized App ID prefix plus Bundle ID | Deterministic private namespace; ordinary compatible updates can retain access | Requires the real signed entitlement and profile to be stable; the Team/profile issuer remains a trust root | Preferred formal target after prototype gate |
| Data Protection Keychain with a custom shared access group | Explicit profile-authorized group shared by selected apps | Supports a future same-Team helper | Expands the trust set and requires an additional `keychain-access-groups` entitlement | Rejected until a separately reviewed sharing requirement exists |
| Session-only token for preview | Process lifetime only | No unstable persistent identity and no legacy API dependency | User must re-enter the token after relaunch; background startup cannot run until then | Acceptable preview mode if exact-build ACL is removed before preview Data Protection identity is proven |
| File Keychain with identifier-only ACL | Bundle ID only | Appears to survive ad-hoc rebuilds | A spoofed same-identifier binary can become trusted | Rejected permanently |
| Data Protection Keychain for every build immediately | Whatever group the current signature happens to expose | One code path | Unsupported claim for ad-hoc preview; could lose access or broaden trust | Rejected until isolated evidence exists |

## Decision

Adopt a staged hybrid migration:

1. **Formal Developer ID releases** will preferentially use the Data Protection
   Keychain and set `kSecAttrAccessGroup` on every add, read, update, and delete to
   the exact `com.apple.application-identifier` value present in the signed
   entitlements and authorized by the embedded Developer ID distribution profile.
   Gatebeam will not derive this value from the Bundle ID or certificate Team ID
   alone and will not create a broad shared group merely for convenience.
2. **Developer Preview** will not use persistent Data Protection storage until the
   isolated prototype gate proves stable access across distinct ad-hoc builds and
   rejects spoofed identities. Until then it will retain the current exact-build
   legacy ACL or offer session-only storage. It will never persist by trusting only
   the Bundle ID.
3. Migration from file-based services remains an explicit, user-initiated,
   copy-verify-retain operation. Background paths never migrate.
4. The existing ACL implementation remains available only for migration,
   rollback, and the preview fallback during the compatibility window.

This decision deliberately separates the formal and preview trust models. Passing
the formal gate does not imply that the preview gate passes, and vice versa.

## Target Data Model

The first production Data Protection schema uses:

| Attribute | Value |
| --- | --- |
| Keychain implementation | Data Protection Keychain |
| Class | `kSecClassGenericPassword` |
| Service | `io.github.naifuliang.gatebeam.data-protection.v2` |
| Account | `cloudflare-api-token` |
| Data | UTF-8 Cloudflare API token |
| `kSecUseDataProtectionKeychain` | `true` on add, read, update, and delete |
| `kSecAttrSynchronizable` | absent / `false` |
| Accessibility | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, subject to the prototype confirming background login behavior |
| Access group | Explicit `kSecAttrAccessGroup` equal to the profile-authorized signed `com.apple.application-identifier` |

The service suffix is the storage schema version, not the app version. The dormant
prototype has already associated `data-protection.v1` with a different accessibility
and unqualified-group model. `v1` is therefore permanently experimental and is not
an authoritative migration source. The formal target always uses
`data-protection.v2`; it does not choose a service version based on local history.
Finding a `v1` fixture enters explicit conflict recovery and never causes Gatebeam
to reinterpret it as `v2`.

The storage layer reads and writes `Data` and compares exact bytes. Strict UTF-8
decoding happens only at the Cloudflare-token business boundary. Invalid UTF-8 is a
dedicated corruption error, not the same result as a missing item. Nonsecret
migration state may record the active schema, source-retention deadline, last
verified destination version, and reconciliation requirement outside the token
item. It must not contain the token, a token prefix, or reversible token-derived
data.

The formal implementation must read its effective code-signing entitlements and
embedded profile at build validation and in the isolated prototype. It must compare
the exact signed `com.apple.application-identifier`, profile allowlist, Bundle ID,
App ID prefix, and Developer ID Team identity against release constants. If any
source disagrees, persistent Data Protection storage is unavailable and the
operation fails closed.

The implementation uses two typed stores and a coordinator:

- `FileKeychainTokenStore` always omits
  `kSecUseDataProtectionKeychain` and owns `secure-v2` plus
  `cloudflare-token.v3`.
- `DataProtectionTokenStore` always sets
  `kSecUseDataProtectionKeychain = true` and the exact access group, and owns
  `data-protection.v2`.
- `KeychainMigrationCoordinator` is the only component allowed to move bytes
  between them. It must not reuse one `KeychainStore` instance's `legacyServices`
  loop because the current implementation-level switch applies one Keychain
  implementation to every query in that instance.

## Phased Migration

### Phase 0: Preserve and Instrument

- Keep production on `cloudflare-token.v3`.
- Keep both noninteractive controls on every background Keychain operation.
- Add no automatic legacy enumeration.
- Treat the dormant Data Protection constructor as test-only.
- Define the prototype and release evidence described below.

### Phase 1: Isolated Data Protection Prototype

Run the prototype in a disposable macOS user account or disposable VM, never
against a developer's production token. Use a unique fixture service and account
and remove them at the end.

The prototype must inspect, record, and assert the effective application identifier,
App ID prefix, Team ID, Keychain access groups, provisioning profile authorization,
Bundle ID, and designated requirement for each fixture. It must then exercise add,
background read, update, delete, relaunch, reboot/login, and replacement-build
behavior. Query observers must prove that every file-store query omits
`kSecUseDataProtectionKeychain`, while every destination operation sets it to
`true` and includes the exact `kSecAttrAccessGroup`.

Use at least these independently built fixtures:

- Preview build A and preview build B: same Bundle ID, different `cdhash`.
- A spoofed ad-hoc app: same Bundle ID, different code and path.
- Formal builds A and B: same Bundle ID and same Developer ID Team, distinct
  binaries and timestamps.
- Wrong-Team formal build: same Bundle ID, different Team.
- Wrong-Bundle formal build: same Team, different Bundle ID.
- A build with a missing or unauthorized access-group entitlement.

The preview result is **unknown** until this experiment passes across all supported
macOS versions and architectures. If preview A cannot create an item, preview B
cannot read it, or a spoofed build can read it, preview persistence through the
Data Protection Keychain is rejected. No experiment may "fix" this by introducing
identifier-only persistent trust.

### Phase 2: Formal Opt-in and Dual Compatibility

Enable the Data Protection path only when all formal signing and prototype checks
pass. On an explicit **Authorize Token** or **Save** action, the coordinator applies
this source order:

1. Read and fully validate an existing `data-protection.v2` destination.
2. Read `cloudflare-token.v3` from the file store interactively. After that read
   succeeds, rewrite the same bytes to `v3` with the current formal,
   Team-qualified `SecAccess` and `refreshAccess: true`, then read `v3` with the
   background, no-UI query and compare the exact bytes. Do not prepare the
   destination before this source rebind and verification succeed.
3. If `v3` is absent, read `secure-v2` interactively. When it exists, create `v3`
   with the same current formal `SecAccess` and `refreshAccess: true`, then
   background-verify the exact bytes. Do not delete `secure-v2` yet.
4. Add `data-protection.v2` with the exact target implementation, service, account,
   access group, accessibility, and synchronization attributes.
5. Read it back using the background, no-UI destination query and compare the exact
   bytes.
6. Record `dual-active` only after the destination and `v3` mirror are both
   verified.
7. Delete `secure-v2` only after `dual-active` is committed; report and retry a
   cleanup failure without deleting either verified copy.

This ordering deliberately matches the current `KeychainStore`: interactive read,
`refreshAccess: true` rewrite, background verification, then legacy cleanup. The
formal coordinator inserts destination preparation only after the verified `v3`
step.

The two authorization models do not cross that boundary. Preview's exact-`cdhash`
`SecAccess` protects only its file-Keychain item and is never copied into or
treated as authority for a formal migration. Formal `v3` uses the validated
Team-qualified `SecAccess` only as the rollback mirror's file-Keychain ACL. The
Data Protection destination does not use `SecAccess` or `refreshAccess`; every
operation selects the exact profile-authorized signed application-ID group with
`kSecAttrAccessGroup`.

If the `v3` rebind or its no-UI verification fails, stop before destination
creation and retain every pre-existing source item. If a later destination step
fails, remove any partially created destination when possible and roll back to the
verified `v3` source; never delete the source as part of that rollback. If the
coordinator cannot prove a verified source after a partial operation, enter
`reconciliation-required`, pause DDNS, and preserve all remaining copies rather
than claim success. In every failure case, latch the result: background work may
report the paused state but must not retry, request UI, or start a prompt loop.
Only a new explicit credential action may make one new interactive attempt. A
failed cleanup must not be reported as success.

An existing destination is never blindly updated. The coordinator validates its
implementation, service, account, group, accessibility, synchronization setting,
and raw bytes. An item with incompatible attributes, invalid UTF-8, an unknown
schema, or conflicting bytes enters `reconciliation-required`.

Observed-item resolution is deterministic:

| Observation | Result |
| --- | --- |
| No source and no `v2` destination | Stable `no-credential`; create nothing and keep DDNS paused until the user saves a token |
| Only `v3` | Explicitly migrate it |
| Only `secure-v2` | Explicitly create and verify `v3`, then migrate |
| Equal `v3` and valid `v2` | Commit or resume `dual-active` |
| Unequal copies | `reconciliation-required`; choose neither automatically |
| Valid `v2`, no `v3`, retention gate not complete | `reconciliation-required`; do not assume the source was intentionally removed |
| Valid `v2`, no `v3`, recorded retention gate complete | `destination-only` |
| Any incompatible destination attribute or experimental `v1` collision | `reconciliation-required`; never reinterpret in place |

During the compatibility window, a user-initiated token change must keep both
stores coherent:

1. Capture the previously verified values.
2. Write and verify the Data Protection destination.
3. Write and verify the file-Keychain rollback mirror.
4. Commit the new logical value only after both verifications pass.
5. On failure, restore the previous values where possible and present a precise
   recovery state; never silently leave an older build with a different token.

Periodic background checks use only the active Data Protection service after
migration. However, every app-version transition and every launch while a rollback
mirror is retained must complete one no-UI reconciliation of the exact `v3` mirror
before any DDNS request. A missing, changed, unreadable, or UI-requiring mirror
enters `reconciliation-required`, pauses DDNS, and asks for an explicit recovery
action. Timers never enumerate legacy services and never retry reconciliation with
UI.

The persisted migration state machine is:

| State | Required items | Background behavior | Allowed transition |
| --- | --- | --- | --- |
| `no-credential` | No token in any authoritative service | DDNS that requires Cloudflare credentials remains paused; no Keychain retry | Explicit user save creates the policy-selected item or items |
| `file-only` | Verified `v3`, or `secure-v2` awaiting explicit migration | Existing file-store policy | User starts migration |
| `destination-prepared` | Source retained; `v2` may exist but is not authoritative | DDNS remains on verified source or paused | Verify both copies, then commit `dual-active`; otherwise clean up and return to `file-only` |
| `dual-active` | `v3` and `data-protection.v2` exist and last verified equal | Launch/version-transition reconciliation first; then DP-only periodic reads | Continue, explicit conflict recovery, or retention expiry |
| `reconciliation-required` | Copies are missing, unreadable, or unequal | DDNS paused; no automatic choice or UI | Explicitly keep and resave one value, or explicitly confirm deletion and verify all authoritative items absent |
| `destination-only` | Verified `data-protection.v2`; retention gate recorded complete | DP-only | Explicit token change, or explicit deletion followed by `no-credential` |

The transition marker is not proof by itself. Item verification is authoritative.
Interrupted writes resume from observed item state, not from the last intended step.

Deletion is a first-class credential transaction. In `dual-active`, an explicit
delete removes and verifies both `v3` and `data-protection.v2` before committing
`no-credential`; a partial failure enters `reconciliation-required`. If an older
build removed only `v3`, the modern recovery UI offers two explicit choices:

- **Keep saved token:** copy the verified Data Protection bytes back to a new
  verified `v3` rollback mirror.
- **Confirm deletion:** delete the Data Protection item and verify both
  authoritative services are absent before committing `no-credential`.

Cancel or denial changes nothing and leaves DDNS paused. No missing item is treated
as deletion intent without that confirmation.

### Phase 3: Destination Default

After one migration-capable formal release has shipped and its rollback tests pass,
new formal installations write only the Data Protection item. Upgrades still retain
and maintain the `v3` mirror until the source-retention deadline.

Preview remains independently selected:

- Use exact-build file-Keychain ACL while legacy support remains; or
- use session-only storage.

Formal and preview packages must use different policy selection based on validated
signing evidence, not an environment variable or mutable preference.

Session-only preview storage has its own hard contract: the token lives only in
process memory, no `SecItem` operation is issued, relaunch or crash loses the value,
and Login Item startup pauses DDNS until the user enters it again. Tests must prove
zero Keychain queries, restart loss, concurrent read safety, and no DDNS attempt
before entry.

### Phase 4: Retire Routine Legacy ACL Creation

Stop creating or refreshing `SecAccess` items for new formal installations and
already migrated users. During the published direct-upgrade window, retain one
narrow, user-initiated migration bridge that may create and verify a `v3` mirror
from an otherwise stranded `secure-v2` source. The bridge cannot run in the
background, refresh unrelated ACLs, or serve new installations.

That bridge remains until every still-supported `secure-v2` source can instead
migrate through a supported intermediate release. Preview must also have a proven
replacement or have moved to session-only storage before this phase can remove its
fallback.

### Phase 5: Delete Legacy APIs

Remove `SecTrustedApplicationCreateFromPath`, `SecAccessCreate`,
`kSecAttrAccess`, and the file-Keychain write path only after every admission
condition below is satisfied. A separately reviewed read-and-delete migrator may
remain for one additional release if supported by Apple, but it must never run in
the background.

## Rollback and Loss Prevention

There is no atomic transaction spanning the file-based and Data Protection
Keychains. Gatebeam therefore uses copy, destination verification, source retention,
and an explicit commit marker.

Rollback guarantees are bounded and stated precisely:

- Before the destination is verified, the old build remains authoritative.
- During the compatibility window, a prior formal build satisfying the same
  Team-qualified file-Keychain ACL can continue reading the retained and verified
  `v3` mirror.
- If that old build changes or deletes `v3`, the next modern build detects the
  mismatch during mandatory launch reconciliation and pauses DDNS before using the
  Data Protection copy.
- Removing the destination during rollback must never delete the only verified
  source.
- Removing the source is irreversible for old builds and requires the Phase 5
  admission gate.
- Team transfer, Bundle ID change, access-group rename, or lost Developer ID
  identity blocks release until a dedicated migration is designed.

If both copies exist but differ, Gatebeam must stop background DDNS updates, report
the conflict without revealing either value, and require an explicit user choice
to resave. It must not choose a value based only on modification timestamps.

Preview-to-formal and formal-to-preview replacement is not an unattended rollback
guarantee. Refreshing `v3` to a formal Team-qualified ACL can make an exact-cdhash
preview require authorization again; refreshing it for that preview can conversely
interrupt formal background access. Gatebeam retains the data and provides an
explicit **Authorize Token** recovery path, but it does not claim transparent
cross-policy rollback. Tests cover preview -> formal -> same preview, token change,
token deletion, denial, and return to formal.

## Background No-UI Contract

Every non-user-initiated add, read, update, and delete in either Keychain
implementation must:

- set `LAContext.interactionNotAllowed` to `true`;
- set `kSecUseAuthenticationUI` to `kSecUseAuthenticationUIFail`;
- treat `errSecInteractionNotAllowed`, `errSecInteractionRequired`, a locked
  Keychain, missing entitlements, and an unavailable Data Protection Keychain as
  noninteractive failures;
- latch repeated failures so a timer cannot create a retry or log storm; and
- avoid legacy-service enumeration or migration.

Only direct activation of **Authorize Token**, **Save**, or a similarly explicit
credential command may allow UI. UI validation, screenshot rendering, CI,
diagnostics, and tests must use injected stores or disposable fixtures and must
never query the production services.

The use of `kSecUseAuthenticationUIFail` is itself deprecated on newer SDKs, so the
implementation must track Apple's supported replacement behavior. It may not remove
the second no-UI barrier until an isolated test proves that the replacement cannot
launch SecurityAgent for all supported systems.

## Preview Policy

The preview has no stable Team entitlement today. A stable Bundle ID is not a
stable trusted identity.

Until the preview prototype gate passes:

- persistent storage may use only the current exact-build `cdhash` ACL;
- replacing the build requires explicit user authorization and ACL refresh; or
- the user may choose session-only token storage.

The preview must fail closed if its exact-build requirement cannot be validated.
It must not add a self-chosen `application-identifier` or
`keychain-access-groups` entitlement and assume that ad-hoc signing makes that
claim authoritative. It must not use a default Data Protection access group whose
value and cross-build behavior have not been observed and adversarially tested.

Even if Apple changes preview behavior in a future macOS release, Gatebeam treats
that as a new capability result. It does not extrapolate from one machine or one OS
version.

## Formal Developer ID Policy

A formal build may select Data Protection persistence only when the release gate
proves all of the following:

- a real Developer ID Application signature with the expected Team ID and Bundle
  ID;
- hardened runtime, secure timestamp, and the existing certificate OID checks;
- an embedded Developer ID distribution provisioning profile that authorizes the
  signed `com.apple.application-identifier`, even when Gatebeam claims no custom
  `keychain-access-groups` entitlement;
- when a custom `keychain-access-groups` entitlement is ever claimed, profile
  authorization for every value in that entitlement;
- an explicit `kSecAttrAccessGroup` on every operation equal to the exact
  profile-authorized App ID prefix plus Gatebeam Bundle ID;
- successful same-Team cross-build access and wrong-Team rejection;
- no unsafe code-signing entitlement that weakens the runtime; and
- successful notarization for the distributable artifact.

For a single Gatebeam executable, use its private application-ID group explicitly.
Introduce a custom shared access group only for a concrete, separately
threat-modeled same-Team component. Never grant another app access merely to
simplify testing.

The Team's certificate and provisioning-profile issuance authority is part of the
trust root. A same-Team app with a profile expressly authorizing Gatebeam's
application-ID group may be able to join that group; the Keychain cannot distinguish
it solely by Bundle ID. Release credentials, Developer account roles, profile
issuance, and CI signing access therefore require organizational controls outside
this storage API.

## Threat Model

| Threat | Required control |
| --- | --- |
| Ad-hoc attacker copies Gatebeam's Bundle ID | Preview exact-build ACL or session-only storage; no identifier-only trust |
| Different developer signs the same Bundle ID | Profile-authorized application-ID group and wrong-Team negative test |
| Ordinary same-Team app with a different Bundle ID | Explicit private application-ID group prevents accidental access |
| Same-Team app whose profile explicitly authorizes Gatebeam's group | Accepted trust-root limitation; restrict Developer account, profile issuance, signing keys, and CI credentials |
| Malicious or injected code inside Gatebeam | Hardened runtime, library validation, strict signing, no dangerous entitlements; Keychain identity does not mitigate a fully compromised authorized process |
| Background SecurityAgent prompt used for phishing or denial of service | Two independent no-UI query controls, explicit user-only authorization, retry latch |
| Partial migration or power loss | Copy, verify, retain source, idempotent resume, explicit commit marker |
| Downgrade to an old build | Verified `v3` rollback mirror for a bounded window; downgrade tests before source deletion |
| Team transfer, Bundle ID change, or lost certificate continuity | Block release and design a dedicated pre-transfer migration |
| iCloud or backup propagation | `kSecAttrSynchronizable` absent and a ThisDeviceOnly accessibility class |
| Confused query returns a similarly named item | Exact class, service, account, implementation, and explicit group where applicable; one-result match |
| Locked or unavailable user Keychain | Fail without UI in background; preserve configuration and request explicit recovery |
| Test touches a real token | Disposable user or VM, unique fixture namespace, teardown verification, privacy scan |

## Test Matrix

All cells are release gates unless marked prototype-only.

| Dimension | Cases | Required evidence |
| --- | --- | --- |
| Signing mode | Ad-hoc preview, Developer ID formal, wrong Team, wrong Bundle ID, missing profile, App ID prefix different from Team ID | Effective signature, profile, and entitlement dump plus expected allow/deny result |
| Build continuity | Build A to B, B to A rollback, A changes/deletes token, B relaunch, reinstall, app relocation policy | Exact bytes remain readable only where policy allows; B reconciles before DDNS |
| macOS | Every supported major version, latest minor, next macOS beta before support declaration | Add/read/update/delete and no-UI results recorded per OS |
| Architecture | arm64 and x86_64 where supported | Native process results; translation is not a substitute for a native runner |
| Launch context | Direct launch, Login Item/per-user LaunchAgent, relaunch after logout/login, reboot | Data Protection Keychain availability and expected background read |
| Keychain state | unlocked, locked where reproducible, item absent, duplicate fixture, corrupted UTF-8 fixture | Deterministic fail-closed status with no secret disclosure |
| Migration | no source, only `secure-v2`, only `v3`, experimental `v1`, destination only, equal copies, conflicting copies, incompatible attributes | Typed backends, deterministic state transition, and no source deletion before verification |
| Credential deletion | Delete in every state; old build deletes only `v3`; partial delete; cancel/deny recovery; confirm deletion | No automatic resurrection or loss; both authoritative services are absent before `no-credential` |
| Fault injection | add failure, verification failure, mirror failure, delete failure, interruption after every step | At least one verified copy remains and recovery is resumable |
| Background UI | startup, periodic timer, DDNS retry, diagnostics, screenshot, UI validation | SecurityAgent launch detector remains zero; query observer confirms both no-UI controls |
| User interaction | Authorize, Save, cancel, deny, allow, repeated click | UI appears only for the foreground action and state remains coherent |
| Access groups | private application-ID group, another available group with the same service/account, unauthorized group, empty group | Every query selects the exact private group; collision is not read, changed, or deleted |
| Team trust root | same Team/different Bundle without target-group authorization; same Team with a profile that authorizes the target group | First case is denied; second demonstrates and documents the profile-issuer trust boundary |
| Synchronization | iCloud Keychain on and off | Item does not synchronize because `kSecAttrSynchronizable` is absent |
| Downgrade | formal B to formal A; A saves, deletes, denies, or cancels; B resumes; preview -> formal -> preview | Formal B detects mirror changes before DDNS; cross-policy paths require explicit recovery and never lose the last copy |
| Privacy | current tree and full PR commit range | No token, local path, private domain, fixture residue, or signing credential |

The isolated preview experiment must additionally prove that two distinct ad-hoc
builds either have a stable, non-spoofable identity or are classified as
unsupported. A test that merely shows one build can read its own item is
insufficient.

## Admission Criteria

### Enable Data Protection Storage for Formal Releases

All of these must be true:

1. The isolated formal prototype passes on every supported macOS version and native
   architecture.
2. The actual release pipeline embeds and validates any required provisioning
   profile and signed entitlements, including the application identifier even when
   there is no custom Keychain access-group entitlement.
3. Two separately built and timestamped same-Team releases share only the intended
   private item through an explicit application-ID group on every operation.
4. Wrong-Team, wrong-Bundle, missing-profile, unauthorized-group, and injected-code
   tests fail closed.
5. Direct launch and the production per-user login path both access the same item.
6. Migration fault injection proves that a verified source survives every
   pre-commit failure.
7. Background UI detection passes for startup, timers, diagnostics, UI validation,
   and denied/locked states.
8. A notarized formal package passes installation and rollback testing without
   changing the effective access group.
9. Tests distinguish synthetic requirement/query fixtures from real disposable-user
   Keychain evidence; synthetic fixtures alone cannot satisfy this gate.

### Enable Data Protection Storage for Preview

This is a separate gate. It requires all formal-style Data Protection operations
plus evidence that distinct ad-hoc preview builds retain access while a same-Bundle
spoof does not. If Apple platform behavior cannot satisfy both properties, this
gate remains closed and preview uses exact-build ACL or session-only storage.

### Stop Routine Legacy ACL Creation

All of these must be true:

1. A migration-capable formal release has completed the full release matrix.
2. The next formal release has passed upgrade and downgrade testing against it.
3. New installs and migrated installs use the Data Protection destination by
   default.
4. The rollback mirror remains available for the published retention window.
5. Preview has either passed its independent gate or moved to session-only
   storage.
6. There are no unresolved P0 or P1 Keychain, signing, migration, or UI-prompt
   findings.
7. The first migration release publishes a retention window of at least 90 days and
   two consecutive formal release versions, whichever ends later.
8. Every supported source version is classified. If direct `secure-v2` upgrade is
   still supported, the narrowly scoped migration-only `v3` mirror writer remains
   enabled and its packaged upgrade tests pass. Otherwise, a supported intermediate
   migration release and explicit upgrade path are published before Phase 4.

### Delete `SecAccess` and Other Legacy APIs

All of these must be true:

1. Every supported upgrade source can migrate through a still-supported
   intermediate release, or the project has published an explicit manual recovery
   path.
2. The published rollback retention window has expired after at least 90 days and
   two consecutive formal release versions.
3. Release tests prove no production composition root creates, refreshes, or
   background-reads a file-Keychain item.
4. Repository search and compile-time availability checks show no remaining
   `SecAccess`, `SecTrustedApplication`, `kSecAttrAccess`, or accidental
   file-Keychain write path, except a separately approved transitional reader if
   still required.
5. The modern no-UI replacement has an isolated SecurityAgent negative test on
   every supported macOS release.
6. Formal and preview rollback behavior is documented in the release notes and
   verified from packaged artifacts.
7. No supported source still depends on the migration-only `v3` mirror writer; its
   removal is covered by direct-upgrade and unsupported-source negative tests.

Failure of any condition keeps the applicable legacy path in place. Deprecation
warnings alone are not permission to risk credential loss.

Phase 5 remains closed until a first formal migration release assigns the actual
calendar dates and version numbers to that minimum retention policy.

## Consequences

The recommended architecture gives formal releases an Apple-aligned, update-stable
identity while keeping the current preview honest about what ad-hoc signing can
prove. It also makes migration slower: Gatebeam must maintain two implementations,
a rollback mirror, signing-profile validation, and a larger platform matrix during
the transition.

The project accepts that cost because persistent credential trust cannot be safely
inferred from a Bundle ID. The prototype may conclude that preview persistence
cannot move to the Data Protection Keychain. Session-only preview storage is an
acceptable outcome; identifier-only persistent trust is not.

## Evidence Ledger

Evidence is classified so a future release gate cannot mistake a fixture for
platform proof:

| Evidence class | Current coverage | What it may prove | What it does not prove |
| --- | --- | --- | --- |
| Source and unit/integration review | Query-policy dictionaries, migration ordering with injected handlers, requirement parser, latches, and concurrency | Intended control flow and deterministic fault handling | Real file or Data Protection Keychain access, SecurityAgent behavior, cross-build identity |
| Code-signing fixtures | Ad-hoc exact-cdhash checks, synthetic Developer ID requirement strings, hardened-runtime and injection fixtures | Build-contract parsing and rejection of known weak requirements | A real Developer ID certificate, distribution profile, application-ID group, notarization, or cross-build Keychain access |
| Packaged artifact checks | Current preview codesign and package structure | The preview artifact matches its declared preview contract | Formal signing or Data Protection migration readiness |
| Disposable-user/VM Keychain experiment | Not yet run | Real OS behavior for the exact signed fixtures and launch contexts tested | Other OS versions, architectures, signing policies, or future releases |

Only the last class, combined with the actual formal packaged artifact and complete
matrix, can satisfy the Data Protection admission gate. Current tests are useful
but are not evidence that the modern identity problem is already solved.

## Unresolved Evidence

| Question | Current evidence | Required experiment |
| --- | --- | --- |
| Does an ad-hoc preview receive a stable Data Protection default group across different builds? | Unknown; current preview has no Team ID or profile-authorized app ID | Isolated preview A/B and spoof matrix |
| Can Gatebeam's manual Developer ID pipeline embed a profile-authorized application identifier and preserve that exact explicit group across updates? | Apple documents Xcode behavior, but Gatebeam does not currently build through an Xcode target, pass entitlements to `codesign`, or embed a profile | Real Developer ID A/B build with signed-entitlement, profile, and explicit-query inspection |
| What is Gatebeam's actual App ID prefix, and does it equal the certificate Team ID? | Unknown until a real distribution profile exists; the values must not be inferred as equal | Parse and compare the real profile, signed entitlements, and certificate identity |
| Is `AfterFirstUnlockThisDeviceOnly` compatible with every production login and locked-state workflow? | It matches the intended background/device-local policy but is not exercised by current production code | Login, logout, reboot, lock, and LaunchAgent matrix |
| What replaces deprecated `kSecUseAuthenticationUIFail` without allowing UI on all supported macOS versions? | Current two-barrier policy prevented known regressions; no replacement is proven | Isolated SecurityAgent launch detector against candidate query policies |
| What calendar date and release versions close the rollback window? | Policy minimum is 90 days and two formal releases, but no migration release exists | Assign dates and versions before the first migration release, then enforce them in packaged upgrade tests |

## Apple References

- [TN3137: On Mac keychain APIs and implementations][apple-tn3137]
- [`kSecUseDataProtectionKeychain`][apple-data-protection]
- [Sharing access to keychain items among a collection of apps][apple-sharing]
- [`kSecAttrAccessGroup`][apple-access-group]
- [`kSecAttrAccess`][apple-access]
- [Creating distribution-signed code for macOS][apple-distribution-signing]
- [TN3125: Inside Code Signing: Provisioning Profiles][apple-tn3125]
- [Restricting keychain item accessibility][apple-accessibility]

[apple-tn3137]: https://developer&#46;apple&#46;com/documentation/technotes/tn3137-on-mac-keychains
[apple-data-protection]: https://developer&#46;apple&#46;com/documentation/security/ksecusedataprotectionkeychain
[apple-sharing]: https://developer&#46;apple&#46;com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps
[apple-access-group]: https://developer&#46;apple&#46;com/documentation/security/ksecattraccessgroup
[apple-access]: https://developer&#46;apple&#46;com/documentation/security/ksecattraccess
[apple-distribution-signing]: https://developer&#46;apple&#46;com/documentation/xcode/creating-distribution-signed-code-for-the-mac
[apple-tn3125]: https://developer&#46;apple&#46;com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
[apple-accessibility]: https://developer&#46;apple&#46;com/documentation/security/restricting-keychain-item-accessibility
