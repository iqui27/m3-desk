"""Global stdio bridge with an explicitly origin-bound Desk Keychain bearer."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
from urllib.parse import urlsplit

DESK_ENV = 'M3_PLATFORM_DESK_BEARER'
SERVICE = 'local.m3desk.mvp.platform'
SENTINEL = 'launcher-internal-placeholder'


class CredentialError(Exception):
    pass


def origin(value):
    try:
        u = urlsplit(value)
        port = u.port
        if (u.scheme not in ('http', 'https') or not u.hostname or u.username or u.password
                or u.path not in ('', '/') or u.query or u.fragment
                or (u.scheme == 'http' and u.hostname not in ('127.0.0.1', '::1'))):
            raise ValueError()
        return u.scheme, u.hostname, port or (443 if u.scheme == 'https' else 80)
    except (ValueError, TypeError, AttributeError):
        raise CredentialError('Invalid explicit Keychain endpoint origin.') from None


def check_mapping(path, expected):
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
        with os.fdopen(fd, encoding='utf-8') as f:
            s = os.fstat(f.fileno())
            if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid() or s.st_mode & 0o077:
                raise ValueError()
            raw = f.read(2_000_001)
        if len(raw) > 2_000_000:
            raise ValueError()
        data = json.loads(raw)
        if not isinstance(data, dict) or set(data) != {'version', 'workspaces'} or data['version'] != 1 or not isinstance(data['workspaces'], list):
            raise ValueError()
        for entry in data['workspaces']:
            if not isinstance(entry, dict):
                raise ValueError()
            if any(entry.get(k) == DESK_ENV for k in ('cf_client_id_env', 'cf_client_secret_env')):
                raise CredentialError('Desk bearer reference cannot supply Cloudflare credentials.')
            if entry.get('bearer_env') == DESK_ENV and origin(entry.get('base_url')) != expected:
                raise CredentialError('Desk bearer mappings must all use the explicitly bound Keychain origin.')
    except CredentialError:
        raise
    except (OSError, ValueError, TypeError):
        raise CredentialError('Invalid private mapping; no credential was retrieved.') from None


def read_bearer(account, run=subprocess.run):
    try:
        result = run(['/usr/bin/security', 'find-generic-password', '-s', SERVICE, '-a', account, '-w'],
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=False)
        if result.returncode != 0:
            raise ValueError()
        # security adds one LF; no broad strip that could hide an invalid credential.
        raw = result.stdout[:-1] if result.stdout.endswith(b'\n') else result.stdout
        token = raw.decode('ascii')
        if not token or any(ord(c) < 33 or ord(c) > 126 for c in token):
            raise ValueError()
        return token
    except (OSError, subprocess.SubprocessError, ValueError, UnicodeError):
        raise CredentialError('Desk Keychain credential unavailable or invalid; no fallback.') from None


def make_bridge(module, mapping, account, environ=None, reader=read_bearer):
    expected = origin(account)
    inherited = dict(os.environ if environ is None else environ)
    # Ignore ambient values for the reserved opt-in name, even if already set.
    inherited[DESK_ENV] = SENTINEL

    class DeskBridge(module.Bridge):
        def secret(self, reference):
            self.secret_calls += 1
            if reference == DESK_ENV and self.secret_calls != 1:
                raise module.BridgeError('Desk bearer reference cannot supply Cloudflare credentials.')
            if reference == DESK_ENV:
                self.used_desk = True
            return super().secret(reference)

        def resolve(self, root):
            self.used_desk = False
            self.secret_calls = 0
            try:
                check_mapping(mapping, expected)
                endpoint, headers = super().resolve(root)
                if self.used_desk:
                    # super.resolve has validated fields and CF references. Bind the
                    # actual resolved destination too, closing mapping-change races.
                    u = urlsplit(endpoint)
                    actual = origin(f'{u.scheme}://{u.netloc}')
                    if actual != expected:
                        raise CredentialError('Resolved endpoint differs from the Keychain origin; no fallback.')
                    headers['Authorization'] = 'Bearer ' + reader(account)
                return endpoint, headers
            except CredentialError as exc:
                raise module.BridgeError(str(exc)) from None
    return DeskBridge(mapping, environ=inherited)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bridge', required=True, type=Path)
    p.add_argument('--mapping', required=True, type=Path)
    p.add_argument('--keychain-account', required=True,
                   help='Exact Desk endpoint.absoluteString used as Keychain account; origin only')
    a = p.parse_args()
    if not a.bridge.is_absolute() or not a.mapping.is_absolute():
        p.error('bridge and mapping paths must be absolute')
    try:
        spec = importlib.util.spec_from_file_location('m3_bridge_runtime', a.bridge)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        bridge = make_bridge(module, a.mapping, a.keychain_account)
        while True:
            line = sys.stdin.buffer.readline(module.MAX_BYTES + 1)
            if not line:
                return 0
            if len(line) > module.MAX_BYTES:
                response = {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600, 'message': 'Request too large; closing stdio.'}}
                print(json.dumps(response), flush=True)
                return 1
            try:
                response = bridge.dispatch(json.loads(line))
            except (ValueError, UnicodeError):
                response = {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32700, 'message': 'Parse error.'}}
            if response is not None:
                print(json.dumps(response, ensure_ascii=False), flush=True)
    except Exception:
        # No traceback, command output or exception payload can disclose secrets.
        print('M3 credential launcher unavailable; verify private configuration. No fallback.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
