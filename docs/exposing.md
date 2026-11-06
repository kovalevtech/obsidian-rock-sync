# Exposing the server

How to put a Rock Sync server on the internet behind a proxy without opening more than your devices and Claude need. Read [Deployment](deployment.md#network) first: if a VPN suits your devices, keep the sync API on it and none of this applies to it.

The examples use `sync.example.com` for the sync API, `mcp.example.com` for MCP and a vault named `notes`. Replace them with yours.

## What to expose

- **Only a process without the admin panel.** Run the public-facing server with `admin` left out of [`ENABLED_APPS`](container.md), and the admin panel in a process of its own that only your private network reaches. The admin panel never goes through the proxy.
- **One hostname per exposed app:** one for the sync API, one for MCP if you use it. Each hostname then gets a rule that allows that app's requests and nothing else.
- **The origin reachable only through the proxy.** If anything can reach the server directly, the proxy's rules are only advice. Use a tunnel, where the server connects out to the proxy and accepts no inbound connections, or a firewall that admits only the proxy.

## Allow by method and exact path

Write the rule as an allowlist: block everything that isn't one of the requests below. A blocklist (`/admin` blocked) misses spellings the server still routes, such as `//admin` or an encoded path that only the server decodes.

The sync API, as the plugin uses it:

| Method | Path | |
|---|---|---|
| `GET` | `/manifest` | query `v=1`, `wait=25` for long polls |
| `GET`, `PUT`, `DELETE` | `/files/<path>` | |
| `POST` | `/move/<path>` | the new path in a `Destination` header |
| `POST` | `/merge/<path>` | |
| `DELETE` | `/token` | the plugin's **Remove** |
| `POST` | `/pair` | **closed by default**, see below |

- **`X-Rock-Sync-Vault`** must be present, once, and equal to a vault you expose. The plugin sends it with every request except `POST /pair`. The server refuses a request whose header differs from the vault in its credentials ([API](api.md#authentication)), so with this rule a leaked token of another vault reaches nothing from outside. Require the header, not "absent or equal": the server accepts a request without it. Check the hyphenated name exactly: a proxy may treat `X_Rock_Sync_Vault` as a different header, while the server reads either spelling as the same one. Require exactly one value: a proxy may look at the first of two, while the server joins them (`notes, work`).
- **`/pair` stays closed** unless you're connecting a device right now. A connection code is six digits; the server limits guesses, but anyone who reaches `/pair` can keep cancelling your codes. Connect devices over your private network, or open `/pair` for the minute it takes and close it again.
- **`/vaults` and `/health` stay closed.** The plugin doesn't use `/vaults`; `/health` is for Docker and your monitoring.

MCP: only `POST` with the path exactly `/mcp`.

## Cloudflare

A worked example with Cloudflare's proxy. Cloudflare's dashboard moves things around, so the setting names below are the ones in its documentation, linked from each.

**URL normalization** ([settings](https://developers.cloudflare.com/rules/normalization/settings/)): turn on both **Normalize incoming URLs** (on by default) and **Normalize URLs to origin** (off by default). With the second one off, Cloudflare's rules see a normalized path, with dot segments removed, but the server gets the path as the client sent it, so a rule can allow a path that the server reads differently. With both on, rules and server get the same path. The plugin's paths come through normalization unchanged. Leave the normalization type at **RFC-3986**, the default. That type decodes only unreserved characters (letters, digits, `-`, `.`, `_`, `~`), not `%2F`, and removes dot segments ([how it works](https://developers.cloudflare.com/rules/normalization/how-it-works/)). Cloudflare's documentation contradicts itself on whether adjacent slashes (`//`) are always merged, so the rules below check for them explicitly.

**WAF custom rules** ([custom rules](https://developers.cloudflare.com/waf/custom-rules/), action **Block**; the Free plan has 5). They use only `eq`, `in`, `contains`, `starts_with()`, `ends_with()`, `lower()`, `len()` and `any()`, because the regex operator `matches` needs a Business plan ([operators](https://developers.cloudflare.com/ruleset-engine/rules-language/operators/), [functions](https://developers.cloudflare.com/ruleset-engine/rules-language/functions/)).

1. The sync API allowlist:

   ```
   http.host eq "sync.example.com" and not (
     (http.request.method eq "GET" and http.request.uri.path eq "/manifest")
     or (http.request.method in {"GET" "PUT" "DELETE"} and starts_with(http.request.uri.path, "/files/"))
     or (http.request.method eq "POST" and starts_with(http.request.uri.path, "/move/"))
     or (http.request.method eq "POST" and starts_with(http.request.uri.path, "/merge/"))
     or (http.request.method eq "DELETE" and http.request.uri.path eq "/token")
   )
   ```

   While connecting a device from outside, add `or (http.request.method eq "POST" and http.request.uri.path eq "/pair")` inside the parentheses, and remove it afterwards.

2. The vault header ([`http.request.headers`](https://developers.cloudflare.com/ruleset-engine/rules-language/fields/reference/http.request.headers/): names lowercased, every value of a repeated header in the array, values not decoded):

   ```
   (http.host eq "sync.example.com" and http.request.uri.path ne "/pair" and not (
     http.request.headers["x-rock-sync-vault"][0] eq "notes"
     and len(http.request.headers["x-rock-sync-vault"]) eq 1
   ))
   or any(http.request.headers.names[*] contains "_")
   ```

   One value, equal to the vault. Without the header, `[0]` is a missing value, which compares unequal to anything, so the request is blocked ([missing values](https://developers.cloudflare.com/ruleset-engine/rules-language/values/)). For several vaults, use `in {"notes" "work"}` instead of `eq "notes"`. The last line blocks any header name with an underscore: the plugin never sends one, and it closes off the `X_Rock_Sync_Vault` spelling.

3. MCP:

   ```
   http.host eq "mcp.example.com" and not (http.request.method eq "POST" and http.request.uri.path eq "/mcp")
   ```

4. Encoded and unnormalized paths, checked on [`raw.http.request.uri.path`](https://developers.cloudflare.com/ruleset-engine/rules-language/fields/reference/raw.http.request.uri.path/), the path as the client sent it:

   ```
   http.host in {"sync.example.com" "mcp.example.com"} and (
     lower(raw.http.request.uri.path) contains "%2f"
     or lower(raw.http.request.uri.path) contains "%5c"
     or lower(raw.http.request.uri.path) contains "%2e"
     or raw.http.request.uri.path contains "%00"
     or raw.http.request.uri.path contains "\\"
     or raw.http.request.uri.path contains "//"
     or raw.http.request.uri.path contains "/./"
     or raw.http.request.uri.path contains "/../"
     or ends_with(raw.http.request.uri.path, "/.")
     or ends_with(raw.http.request.uri.path, "/..")
   )
   ```

   Cloudflare says the raw field "may include some basic normalization done by Cloudflare's HTTP server", so this rule is a backstop, not a guarantee. The server's own guard (below) refuses all of these anyway.

**Rate limiting** ([rate limiting rules](https://developers.cloudflare.com/waf/rate-limiting-rules/)): the Free plan has one rule, counts by IP over 10 seconds and can match only on the path. Spend it on `/pair` and `/mcp`, for example `http.request.uri.path in {"/pair" "/mcp"}`, more than 20 requests in 10 seconds → block. The server has its own limits there as well (10 pairing attempts a minute, 60 MCP tool calls a minute per token). Don't put a tight limit on `/files/`: a first sync sends one request per file, back to back.

**Other limits.** Cloudflare refuses request bodies over 100 MB on the Free and Pro plans ([error 413](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/4xx-client-error/error-413/)), which matches the server's default `MAX_FILE_SIZE`. It waits 125 seconds for an answer ([error 524](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-5xx-errors/error-524/)), more than a long poll takes.

**The origin.** A [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/) needs no inbound port at all. If you allow Cloudflare's addresses in a firewall instead, keep in mind that every Cloudflare account's traffic comes from those addresses, so a request from them hasn't necessarily passed your rules. [Authenticated Origin Pulls](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/) with a certificate of your own (zone-level) proves it came through your zone; the global certificate "only proves a request came from the Cloudflare network".

**Cloudflare sees everything.** It terminates TLS, so tokens, connection codes and every note you sync pass through it in the clear. That is the price of this setup; a VPN avoids it.

## Limiting MCP to Anthropic's addresses

Anthropic publishes the [addresses](https://platform.claude.com/docs/en/api/ip-addresses) its outbound requests, MCP tool calls included, come from. A rule that blocks `/mcp` from anywhere else (`not ip.src in {…}`) keeps scanners away, but it isn't authentication: those addresses are shared by every Claude user's connectors and by Claude's web fetch. The scoped token is still what lets a request in. Copy the ranges from that page and check it now and then.

## The server's own guard

Before any routing or logging, the server refuses a request whose path, exactly as sent, isn't canonical: `400` with an empty body, and one line in its log. It refuses a path that:

- doesn't start with `/` (`GET http://host/…`, `OPTIONS *`);
- has an empty segment (`//`, a leading `//` too), or a `.` or `..` segment;
- contains `\`, or an encoded `/`, `\` or `.` (`%2F`, `%5C`, `%2E`, either case);
- contains a control character, raw or encoded (`%00`, `%0A`, …);
- has malformed percent-encoding (`%` not followed by two hex digits).

So a proxy that normalizes differently from the server can't make the server route a path it didn't check. The plugin never sends such a path: it encodes each name with `encodeURIComponent`, which leaves `.` alone and turns `%` into `%25`, and names with `\` or control characters are ones Obsidian doesn't allow. The guard is a second line, not a replacement for the allowlist: it doesn't stop a well-formed `/admin/login` or `/pair`.

## Check from outside

Run these from another network, for example a phone's hotspot. For the token checks, make a throwaway device token: issue a code in the admin panel and trade it over your private network, then revoke it in the admin panel when you're done. Do the same for a vault you don't expose, if you have one, for `OTHER`.

```sh
# a throwaway token (over your private network)
curl -sS -X POST https://sync.internal.example.com/pair -d '{"code":"123456","name":"outside-check"}'

S=https://sync.example.com M=https://mcp.example.com
T=paste-the-throwaway-token OTHER=paste-a-token-of-another-vault
code() { curl -sS -o /dev/null -w '%{http_code}\n' "$@"; }
```

Blocked: 403 from the proxy, or 400 from the server for the malformed paths. Anything else, a 401 included, means a rule doesn't apply:

```sh
code "$S/admin/login"
code --path-as-is "$S//admin/login"
code --path-as-is "$S/admin/./login"
code --path-as-is "$S/files/../admin/login"
code --path-as-is "$S/admin/../files/a%2f..%2f..%2flogin"
code --path-as-is "$S/files/a%2fb.md" -u "notes:$T" -H 'X-Rock-Sync-Vault: notes'
code "$S/vaults" -u "notes:$T"
code "$S/health"
code -X POST "$S/pair" -d '{}'
code -X PATCH "$S/files/a.md" -u "notes:$T" -H 'X-Rock-Sync-Vault: notes'
code "$S/manifest?v=1" -u "notes:$T"                                   # no vault header
code "$S/manifest?v=1" -u "notes:$T" -H 'X_Rock_Sync_Vault: notes'
code "$S/manifest?v=1" -u "notes:$T" -H 'X-Rock-Sync-Vault: notes' -H 'X-Rock-Sync-Vault: notes'
code "$S/manifest?v=1" -u "work:$OTHER" -H 'X-Rock-Sync-Vault: work'   # a vault you don't expose
code "$M/admin/login"
code --path-as-is "$M/mcp/../admin/login"
code "$M/mcp"                                                          # GET
code -X POST "$S/mcp"                                                  # MCP on the sync hostname
```

Refused by the server (401):

```sh
code "$S/manifest?v=1" -u "notes:$OTHER" -H 'X-Rock-Sync-Vault: notes'  # another vault's token
code "$S/manifest?v=1" -u "work:$T" -H 'X-Rock-Sync-Vault: notes'     # header and credentials disagree
code -X POST "$M/mcp"                                                   # no token
```

Working (200):

```sh
code "$S/manifest?v=1" -u "notes:$T" -H 'X-Rock-Sync-Vault: notes'
```

`--path-as-is` matters: without it curl removes `/./` and `/../` itself, and the request never tests anything. Then check that a device syncs normally, and revoke the throwaway token.
