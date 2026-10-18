"""Isolated stdio adapter for the authenticated, stateless Platform MCP profile.

Only stdlib; runnable by absolute file path without importing the legacy CLI.
Workspace context belongs to the wrapper and is never sent upstream.
"""
from __future__ import annotations

import argparse
from http.client import HTTPException
import json
import os
from pathlib import Path
import re
import stat
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener
from uuid import UUID

PROTOCOL = '2025-03-26'
MAX_BYTES = 2_000_000
IDENTIFIER = re.compile(r'[A-Za-z0-9_-]{1,128}\Z')
ENV_NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_]*\Z')


def string(maximum, minimum=1):
    return {'type': 'string', 'minLength': minimum, 'maxLength': maximum}


def schema(properties, required):
    return {'type': 'object', 'properties': properties, 'required': required, 'additionalProperties': False}


ID = {'type': 'string', 'format': 'uuid'}
SCHEMAS = {
    'memory_search': schema({'query': string(4096), 'k': {'type': 'integer', 'minimum': 1, 'maximum': 100}}, ['query']),
    'memory_get': schema({'id': ID}, ['id']),
    'memory_write': schema({'type': string(40), 'content': string(200000), 'title': string(500)}, ['type', 'content']),
    'memory_update': schema({'id': ID, 'content': string(200000), 'version': {'type': 'integer', 'minimum': 1}}, ['id', 'content', 'version']),
    'memory_delete': schema({'id': ID}, ['id']),
}
INSTRUCTIONS = (
    'Global Platform bridge: every tool requires workspace_root (the exact canonical absolute '
    'workspace directory) and arguments (the narrow upstream arguments). Never infer scope from '
    'the server cwd, basename or a previous call. If workspace is unknown, ask the user for its '
    'absolute root. If unmapped, ask the operator to add an explicit private mapping and retry. '
    'Identity and permissions come only from the Platform bearer. Never use legacy tools, '
    'attribution hooks, agent_id, user_id, metadata or importance. Full UUIDs; update requires version.'
)


class BridgeError(Exception):
    """Safe operator-facing error; never include credentials or upstream bodies."""


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise BridgeError('Upstream redirect refused; verify the configured endpoint.')


def canonical_root(value, *, must_exist=True):
    if (not isinstance(value, str) or not value or not Path(value).is_absolute()
            or str(Path(value)) != value or os.path.normpath(value) != value):
        raise BridgeError('workspace_root must be an absolute canonical directory.')
    path = Path(value)
    if must_exist and (not path.is_dir() or str(path.resolve(strict=True)) != value):
        raise BridgeError('Workspace must exist and use its canonical path; aliases and symlinks are refused.')
    return value


def validate_arguments(name, arguments):
    expected = SCHEMAS.get(name)
    if expected is None or not isinstance(arguments, dict):
        raise BridgeError('Unknown tool or invalid arguments; only five scoped tools are available.')
    if set(arguments) - set(expected['properties']) or set(expected['required']) - set(arguments):
        raise BridgeError('Unsupported or missing arguments; legacy attribution is forbidden.')
    for key, value in arguments.items():
        field = expected['properties'][key]
        if field['type'] == 'integer':
            if type(value) is not int or value < field['minimum'] or value > field.get('maximum', value):
                raise BridgeError('Invalid integer argument.')
        elif not isinstance(value, str) or not field.get('minLength', 1) <= len(value) <= field.get('maxLength', 36):
            raise BridgeError('Invalid string argument.')
        if field.get('format') == 'uuid':
            try:
                if str(UUID(value)) != value.lower():
                    raise ValueError()
            except ValueError:
                raise BridgeError('A full UUID is required.') from None


class Bridge:
    def __init__(self, mapping, environ=None):
        self.mapping = Path(mapping)
        self.environ = os.environ if environ is None else environ

    def resolve(self, root):
        canonical_root(root)
        # Open a fresh private snapshot on every call. No cached active project.
        fd = os.open(self.mapping, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
        with os.fdopen(fd, 'r', encoding='utf-8') as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise BridgeError('Mapping must be an owner-only regular file (chmod 600).')
            raw = handle.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            raise BridgeError('Mapping is too large.')
        config = json.loads(raw)
        if not isinstance(config, dict) or set(config) != {'version', 'workspaces'} or config['version'] != 1 or not isinstance(config['workspaces'], list):
            raise BridgeError('Invalid private mapping format.')
        entries = {}
        for entry in config['workspaces']:
            required = {'root', 'base_url', 'tenant', 'project', 'bearer_env'}
            optional = {'cf_client_id_env', 'cf_client_secret_env'}
            if not isinstance(entry, dict) or required - set(entry) or set(entry) - required - optional:
                raise BridgeError('Invalid workspace mapping fields.')
            mapped = canonical_root(entry['root'], must_exist=False)
            if mapped in entries:
                raise BridgeError('Ambiguous workspace mapping; remove duplicate roots.')
            entries[mapped] = entry
        if root not in entries:
            raise BridgeError('Workspace unmapped. Add its canonical absolute root, tenant, project and credential environment references to the private mapping, then retry. No request was sent.')
        entry = entries[root]
        for key in ('tenant', 'project'):
            if not isinstance(entry[key], str) or not IDENTIFIER.fullmatch(entry[key]):
                raise BridgeError('Invalid tenant/project identifier.')
        base = entry['base_url']
        if not isinstance(base, str):
            raise BridgeError('Invalid base_url.')
        url = urlsplit(base)
        local = url.hostname in {'127.0.0.1', '::1'}
        if (url.scheme != 'https' and not (url.scheme == 'http' and local)) or not url.hostname or url.username or url.password or url.path not in ('', '/') or url.query or url.fragment:
            raise BridgeError('base_url must be an HTTPS origin or literal loopback HTTP origin, without credentials/path/query.')
        headers = {
            'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream',
            'MCP-Protocol-Version': PROTOCOL,
            'Authorization': 'Bearer ' + self.secret(entry['bearer_env']),
        }
        cf = ('cf_client_id_env', 'cf_client_secret_env')
        if not local or any(key in entry for key in cf):
            if not all(key in entry for key in cf):
                raise BridgeError('Remote endpoints require both Cloudflare credential environment references.')
            headers['CF-Access-Client-Id'] = self.secret(entry[cf[0]])
            headers['CF-Access-Client-Secret'] = self.secret(entry[cf[1]])
        endpoint = f"{base.rstrip('/')}/v1/tenants/{entry['tenant']}/projects/{entry['project']}/mcp"
        return endpoint, headers

    def secret(self, reference):
        if not isinstance(reference, str) or not ENV_NAME.fullmatch(reference):
            raise BridgeError('Credentials must reference environment variable names.')
        value = self.environ.get(reference)
        if not value or any(ord(c) < 33 or ord(c) > 126 for c in value):
            raise BridgeError('Required credential environment variable is absent or invalid; provision it in the client process environment.')
        return value

    def call(self, root, name, arguments):
        validate_arguments(name, arguments)
        endpoint, headers = self.resolve(root)
        # No ambient proxy, redirect, cookies, reusable session or legacy transport.
        opener = build_opener(ProxyHandler({}), NoRedirect())

        def post(method, params, request_id=None):
            payload = {'jsonrpc': '2.0', 'method': method, 'params': params}
            if request_id is not None:
                payload['id'] = request_id
            request = Request(endpoint, json.dumps(payload).encode('utf-8'), headers, method='POST')
            try:
                with opener.open(request, timeout=20) as response:
                    if request_id is None:
                        if response.status != 202:
                            raise BridgeError('Invalid upstream notification response.')
                        return None
                    if response.status != 200 or response.headers.get_content_type() != 'application/json':
                        raise BridgeError('Upstream must return the stateless JSON MCP profile.')
                    raw = response.read(MAX_BYTES + 1)
                    if len(raw) > MAX_BYTES:
                        raise BridgeError('Upstream response exceeds bridge limit.')
                    result = json.loads(raw)
            except HTTPError as exc:
                status = exc.code
                exc.close()
                raise BridgeError(f'Upstream HTTP {status}; verify endpoint, credentials and project membership. No fallback.') from None
            except (URLError, TimeoutError, OSError, HTTPException):
                raise BridgeError('Upstream unavailable; no fallback. Verify the configured endpoint.') from None
            if not isinstance(result, dict) or result.get('jsonrpc') != '2.0' or result.get('id') != request_id or ('result' in result) == ('error' in result):
                raise BridgeError('Invalid upstream JSON-RPC response.')
            if 'error' in result:
                raise BridgeError('Upstream rejected the scoped MCP request; no fallback.')
            return result['result']

        initialized = post('initialize', {'protocolVersion': PROTOCOL, 'capabilities': {}, 'clientInfo': {'name': 'm3-platform-global-bridge', 'version': '1.0.0'}}, 1)
        if not isinstance(initialized, dict) or initialized.get('protocolVersion') != PROTOCOL:
            raise BridgeError('Upstream protocol mismatch.')
        post('notifications/initialized', {})
        catalog = post('tools/list', {}, 2)
        if (not isinstance(catalog, dict) or not isinstance(catalog.get('tools'), list)
                or len(catalog['tools']) != 5
                or {tool.get('name') for tool in catalog['tools'] if isinstance(tool, dict)} != set(SCHEMAS)):
            raise BridgeError('Upstream catalog must contain exactly the five scoped Platform tools.')
        return post('tools/call', {'name': name, 'arguments': arguments}, 3)

    def dispatch(self, message, *, in_batch=False):
        if isinstance(message, list) and message and not in_batch:
            responses = [self.dispatch(item, in_batch=True) for item in message]
            return [response for response in responses if response is not None] or None
        rid = message.get('id') if isinstance(message, dict) else None
        if (not isinstance(message, dict) or message.get('jsonrpc') != '2.0'
                or not isinstance(message.get('method'), str)
                or set(message) - {'jsonrpc', 'id', 'method', 'params'}
                or ('id' in message and type(rid) not in (str, int))):
            return {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600, 'message': 'Invalid JSON-RPC request.'}}
        if 'id' not in message:
            return None  # Never dispatch mutations from notifications, including batches.
        if in_batch and message['method'] == 'initialize':
            return {'jsonrpc': '2.0', 'id': rid, 'error': {'code': -32600, 'message': 'initialize cannot be batched.'}}
        try:
            method = message['method']
            params = message.get('params', {})
            if not isinstance(params, dict):
                raise BridgeError('params must be an object.')
            if '_meta' in params:
                if not isinstance(params['_meta'], dict):
                    raise BridgeError('_meta must be an object.')
                params = {key: value for key, value in params.items() if key != '_meta'}
            if method == 'initialize':
                if not isinstance(params.get('protocolVersion'), str):
                    raise BridgeError('initialize requires protocolVersion.')
                result = {'protocolVersion': PROTOCOL, 'capabilities': {'tools': {'listChanged': False}}, 'serverInfo': {'name': 'm3-platform-global-bridge', 'version': '1.0.0'}, 'instructions': INSTRUCTIONS}
            elif method == 'ping' and not params:
                result = {}
            elif method == 'tools/list' and not params:
                result = {'tools': [{'name': name, 'description': f'{name} in an explicitly mapped workspace. ' + INSTRUCTIONS, 'inputSchema': schema({'workspace_root': string(4096), 'arguments': arguments}, ['workspace_root', 'arguments'])} for name, arguments in SCHEMAS.items()]}
            elif method == 'tools/call':
                if set(params) != {'name', 'arguments'} or not isinstance(params['arguments'], dict) or set(params['arguments']) != {'workspace_root', 'arguments'}:
                    raise BridgeError('Tool requires name and wrapper arguments: workspace_root, arguments.')
                wrapper = params['arguments']
                result = self.call(wrapper['workspace_root'], params['name'], wrapper['arguments'])
            else:
                return {'jsonrpc': '2.0', 'id': rid, 'error': {'code': -32601, 'message': 'Method not supported.'}}
            return {'jsonrpc': '2.0', 'id': rid, 'result': result}
        except BridgeError as exc:
            error = str(exc)
        except (OSError, ValueError, TypeError, KeyError):
            error = 'Invalid mapping, workspace or upstream data; no fallback. Check private configuration.'
        return {'jsonrpc': '2.0', 'id': rid, 'error': {'code': -32602, 'message': error}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mapping', required=True, type=Path, help='Absolute owner-only private JSON mapping')
    args = parser.parse_args()
    if not args.mapping.is_absolute():
        parser.error('--mapping must be absolute')
    bridge = Bridge(args.mapping)
    while True:
        line = sys.stdin.buffer.readline(MAX_BYTES + 1)
        if not line:
            break
        if len(line) > MAX_BYTES:
            print(json.dumps({'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600, 'message': 'Request too large; closing stdio.'}}), flush=True)
            return 1
        try:
            response = bridge.dispatch(json.loads(line))
        except (ValueError, UnicodeError):
            response = {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32700, 'message': 'Parse error.'}}
        if response is not None:
            print(json.dumps(response, ensure_ascii=False), flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
