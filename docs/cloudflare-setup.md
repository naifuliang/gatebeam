# Cloudflare Setup

Gatebeam needs a scoped Cloudflare API token for one DNS zone. The token is used to list zones and create or update DNS-only `A` and `AAAA` records.

## Create A Token

1. Sign in to the [Cloudflare dashboard](https://dash.cloudflare.com/), then open **My Profile** > **API Tokens**.
2. Select **Create Token**. The **Edit zone DNS** template is a useful starting point.
3. Add these permissions:

   | Permission group | Permission | Access |
   | --- | --- | --- |
   | Zone | Zone | Read |
   | Zone | DNS | Edit |

4. Under **Zone Resources**, select **Include** > **Specific zone** > the zone Gatebeam will manage. For `remote.example.com`, choose the `example.com` zone.
5. Create the token and copy it once. Store it only in Gatebeam's token field; Cloudflare will not show the secret value again.

Do not use a **Global API Key**. Do not give the token access to all zones unless this Mac genuinely needs to manage all of them. Avoid Client IP filtering for a DDNS token: a changing home connection can make its own token unusable.

## Verify And Choose A Name

For an existing saved token, choose **Authorize Token** first so this Gatebeam build may read it from Keychain. For a new or replacement token, paste it into **API token** and choose **Verify**; Gatebeam uses the entered value to load the readable domains without saving it. A success means Cloudflare accepted the token and it can read at least one zone. It does **not** prove `Zone / DNS / Edit`; Cloudflare does not offer a harmless universal write test for this purpose. After verification, choose **Save Changes** with the edited, non-empty token still in the field to write or replace the Keychain item. A normal save with an untouched token field performs no token read, write, or deletion.

Choose the **Domain** as the Cloudflare zone, then enter the **Subdomain** in any of these forms:

| Domain | Accepted Subdomain | Result |
| --- | --- | --- |
| `example.com` | `remote` | `remote.example.com` |
| `example.com` | `remote.example.com` | `remote.example.com` |
| `example.com` | `@` | `example.com` |

Enter only `@`, a single label such as `remote`, or a full address that already ends with the selected zone. The current preview does not reliably reject a full address from another zone; it can treat that input as a relative name and append the selected zone. Check the **Full address** preview before saving.

When a matching DNS record does not exist, Gatebeam creates a **DNS-only** record. A successful first `A` or `AAAA` create/update is the point at which DNS Edit is actually confirmed. If Cloudflare returns a permission error then, edit the token and add `Zone / DNS / Edit` for the selected zone.

Cloudflare's orange-cloud proxy is not suitable for VNC TCP traffic. Keep these records **DNS only**.

## Address Modes And Records

| Address mode | Records Gatebeam updates or creates |
| --- | --- |
| IPv4 | `A` only |
| Dual | `A` and `AAAA` when each usable address is available |
| IPv6 | `AAAA` only |

The current preview does **not** automatically remove an existing record for the other address family. That is deliberate documentation of a current limitation, not a promise that the old record is still correct.

After changing address mode, or when usable IPv6 disappears:

1. Open **Cloudflare Dashboard** > the zone > **DNS** > **Records**.
2. Find the record name Gatebeam manages.
3. Check both its `A` and `AAAA` records against the mode you intend to publish.
4. Remove the inactive-family record manually when it should no longer be reachable, or leave it only when you have independently confirmed it remains valid.

Future Gatebeam versions may provide an explicit inactive-record cleanup flow. Until then, record deletion remains a deliberate Cloudflare dashboard action.

## Rotate Or Revoke A Token

Rotate a token when a device changes hands, a secret may have been exposed, or access should be narrowed.

1. Create a new scoped token with the same minimum permissions and target-zone resource limit.
2. Paste the new value into Gatebeam's **API token** field and choose **Verify** to confirm that it can read the intended domain. Verification does not save the token.
3. Choose **Save Changes** while the edited, non-empty token remains in the field. Gatebeam then writes or replaces the Keychain item; macOS may request authorization for this explicit write.
4. Run a normal update to confirm that the selected record can be written.
5. In Cloudflare, revoke the old token from **My Profile** > **API Tokens**.

To stop Gatebeam from using Cloudflare, turn the provider off and remove the saved token through its explicit **Remove Token** control when that control is present. Remove or rotate the token in Cloudflare as well; deleting a local Keychain item does not revoke a copied token elsewhere.

## Cloudflare References

- [Create API tokens](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
- [API token permissions](https://developers.cloudflare.com/fundamentals/api/reference/permissions/)
- [DNS Records API](https://developers.cloudflare.com/api/resources/dns/subresources/records/)
