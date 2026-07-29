# Keychain Manual Validation

Use this matrix only for a final local check of macOS SecurityAgent behavior. It runs
the built app directly from the worktree and does not install or replace anything in
`/Applications`.

## Prepare

1. Quit every running Gatebeam build.
2. Build with `./scripts/build_app.sh`.
3. Open `dist/Gatebeam.app` directly.
4. Use a disposable scoped Cloudflare token. Do not paste a production token into
   logs, screenshots, shell history, or issue reports.

Stop the check if the same action opens more than one Keychain authorization dialog.
Do not keep approving a repeated prompt.

## Matrix

| Action | Expected Keychain behavior |
| --- | --- |
| Open Settings | No authorization dialog. Background reads fail closed. |
| Enter a new token and click Verify | No Keychain write or delete. The token and current unsaved DDNS proxy route are used only for this request. |
| Click Save Changes once after entering a new token | At most one authorization dialog and one logical write. |
| Click Save Changes again without changing the token | No authorization dialog and no Keychain operation. |
| Click the trash button, then Cancel | No authorization dialog and no Keychain operation. |
| Click the trash button, then Remove Token | At most one authorization dialog and exactly one logical delete. |
| Click Remove Token again after removal | No authorization dialog and no Keychain operation. |

After a successful removal, quit and reopen the same worktree build. Settings must
show no saved token. A failed or cancelled write/delete must keep the previous
in-memory token state and show one actionable error; it must not retry automatically.

## Safe Diagnostics

If a step fails, record only:

- the matrix row,
- whether the dialog appeared zero, one, or multiple times,
- the app build path,
- the visible Gatebeam error text,
- the macOS version.

Never include the token, Keychain password, Cloudflare response body, or proxy
credentials.
