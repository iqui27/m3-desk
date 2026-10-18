# Desk Keychain credential launcher

Optional global MCP launcher for credentials stored by M3 Desk in macOS Keychain. Installation and private workspace mappings are configured separately; no credentials are included in this repository.

## Contract

The existing bridge and its five-tool wrapper remain authoritative. Every workspace still requires its own explicit canonical-root → tenant/project mapping. There is one global client registration, not one MCP registration per project.

An entry opts into this launcher by setting `bearer_env` to `M3_PLATFORM_DESK_BEARER`. All such entries must use the same origin as the explicit `--keychain-account` argument. This argument must be the exact `endpoint.absoluteString` used by Desk, including any trailing slash; it must be an origin, not a scoped MCP URL. The launcher uses the generic-password service `local.m3desk.mvp.platform` and this exact account. It never searches by project name or chooses a different item.

The launcher loads the existing bridge module, preserves other environment references and overrides any ambient value of the reserved Desk bearer variable. It does not put the bearer into `os.environ`, a file, a command argument or a child environment. On an actual mapped call only, it captures `/usr/bin/security find-generic-password` stdout in memory. It checks the actual resolved destination before inserting that bearer into the request headers. Failed reads do not echo stdout, stderr or tracebacks. Keychain access controls may deny access or require macOS authorization; no ACL is changed.

Catalog, initialization, malformed wrapper and unmapped requests do not access Keychain. A private mapping is reread and checked on each resolve. Symlink and world/group-readable files are rejected. Remote origins require preexisting valid CF environment references; this launcher does not retrieve or provision CF credentials.

## Launch command

Install the launcher and bridge together at a stable private location, then configure the global `m3_platform` registration with this argument vector (adapt paths for your account):

```json
[
  "/Users/hrocha/.local/lib/m3-platform-bridge/desk_keychain_launcher.py",
  "--bridge", "/Users/hrocha/.local/lib/m3-platform-bridge/bridge.py",
  "--mapping", "/Users/hrocha/.config/m3-platform-bridge/mapping.json",
  "--keychain-account", "http://127.0.0.1:24886"
]
```

Executable: `/opt/homebrew/bin/python3`. Codex and Claude use executable plus `args`; OpenCode's `command` array starts with the executable followed by these arguments. Preserve all unrelated settings. No token values belong in any client configuration. The account example must be verified against the actual authorized Desk connection before use.

## Validation

`python3 -m unittest -v` in this directory: 14 tests passed. Coverage includes exact service/account command without shell, stdout/stderr error redaction, reserved ambient token rejection, other environment preservation, offline catalog and parse-error stdio integration, unmapped rejection without Keychain, CF gating before bearer retrieval, private-map permissions/symlinks, origin mismatch, actual-resolved-endpoint race, and map updates.

Tests use fake credentials only. Real Keychain ACL behavior, actual client startup/reconnection, authenticated scoped search and an authorized memory write remain unverified. Launchers depend on the current bridge's `Bridge.resolve` contract (bearer first, CF afterward), protected by tests and rejection if the reserved reference is later requested as CF. Re-review if that upstream contract changes.
