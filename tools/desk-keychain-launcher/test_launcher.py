import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock
import launcher

spec = importlib.util.spec_from_file_location('bridge', str(Path(__file__).with_name('bridge.py')))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = str(Path(self.tmp.name).resolve())
        self.path = Path(self.root) / 'map.json'
        self.entries = [dict(root=self.root, base_url='http://127.0.0.1:24886', tenant='tenant', project='project', bearer_env=launcher.DESK_ENV)]
        self.save()
        self.reader = Mock(return_value='FAKE-TEST-BEARER')
    def tearDown(self):
        self.tmp.cleanup()
    def save(self):
        self.path.write_text(json.dumps(dict(version=1, workspaces=self.entries)))
        self.path.chmod(0o600)
    def make(self, env=None, account='http://127.0.0.1:24886'):
        return launcher.make_bridge(bridge, self.path, account, env or {}, self.reader)
    def test_bound_and_ambient_reserved_ignored(self):
        endpoint, headers = self.make({launcher.DESK_ENV: 'WRONG'}).resolve(self.root)
        self.assertTrue(endpoint.endswith('/v1/tenants/tenant/projects/project/mcp'))
        self.assertEqual(headers['Authorization'], 'Bearer FAKE-TEST-BEARER')
        self.reader.assert_called_once_with('http://127.0.0.1:24886')
    def test_offline_catalog_does_not_read_keychain(self):
        result = self.make().dispatch(dict(jsonrpc='2.0', id=1, method='tools/list'))
        self.assertEqual(len(result['result']['tools']), 5)
        self.reader.assert_not_called()
    def test_other_environment_preserved(self):
        self.entries[0]['bearer_env'] = 'OTHER'; self.save()
        self.assertEqual(self.make({'OTHER': launcher.SENTINEL}).resolve(self.root)[1]['Authorization'], 'Bearer '+launcher.SENTINEL)
        self.reader.assert_not_called()
    def test_all_opted_origins_checked(self):
        self.entries.append(dict(self.entries[0], root='/another', base_url='https://another.example'))
        self.save()
        with self.assertRaises(bridge.BridgeError): self.make().resolve(self.root)
        self.reader.assert_not_called()
    def test_remote_requires_cf_before_keychain(self):
        self.entries[0]['base_url'] = 'https://memory.example'; self.save()
        with self.assertRaises(bridge.BridgeError): self.make(account='https://memory.example').resolve(self.root)
        self.reader.assert_not_called()
    def test_remote_with_existing_cf(self):
        self.entries[0].update(base_url='https://memory.example', cf_client_id_env='CF_ID', cf_client_secret_env='CF_SECRET'); self.save()
        headers = self.make({'CF_ID':'fake-id','CF_SECRET':'fake-cf'}, 'https://memory.example').resolve(self.root)[1]
        self.assertEqual(headers['CF-Access-Client-Secret'], 'fake-cf')
    def test_insecure_or_symlink_map_rejected(self):
        self.path.chmod(0o644)
        with self.assertRaises(bridge.BridgeError): self.make().resolve(self.root)
        self.path.chmod(0o600)
        link = self.path.with_name('link'); link.symlink_to(self.path)
        obj = launcher.make_bridge(bridge, link, 'http://127.0.0.1:24886', {}, self.reader)
        with self.assertRaises(bridge.BridgeError): obj.resolve(self.root)
        self.reader.assert_not_called()
    def test_changed_destination_never_receives_bearer(self):
        obj=self.make()
        original=bridge.Bridge.resolve
        def changed(instance, root):
            endpoint, headers=original(instance,root)
            return endpoint.replace('127.0.0.1:24886','127.0.0.1:9999'),headers
        from unittest.mock import patch
        with patch.object(bridge.Bridge,'resolve',changed):
            with self.assertRaises(bridge.BridgeError): obj.resolve(self.root)
        self.reader.assert_not_called()
    def test_security_exact_args_and_no_shell(self):
        run=Mock(return_value=subprocess.CompletedProcess([],0,b'FAKE\n',b''))
        self.assertEqual(launcher.read_bearer('http://127.0.0.1:24886',run),'FAKE')
        args,kwargs=run.call_args
        self.assertEqual(args[0],['/usr/bin/security','find-generic-password','-s',launcher.SERVICE,'-a','http://127.0.0.1:24886','-w'])
        self.assertNotIn('shell',kwargs)
    def test_security_errors_redacted(self):
        for result in [subprocess.CompletedProcess([],1,b'SECRET',b'SECRET'),subprocess.CompletedProcess([],0,b'bad token\n',b'SECRET')]:
            with self.assertRaises(launcher.CredentialError) as caught:
                launcher.read_bearer('http://127.0.0.1:24886',Mock(return_value=result))
            self.assertNotIn('SECRET',str(caught.exception))
    def test_mapping_changes_rechecked(self):
        obj=self.make(); obj.resolve(self.root)
        self.entries[0]['base_url']='https://other.example'; self.save(); self.reader.reset_mock()
        with self.assertRaises(bridge.BridgeError): obj.resolve(self.root)
        self.reader.assert_not_called()
    def test_unmapped_never_reads_keychain(self):
        self.entries = []; self.save()
        result = self.make().dispatch(dict(jsonrpc='2.0', id=2, method='tools/call', params=dict(name='memory_search',arguments=dict(workspace_root=self.root,arguments=dict(query='test')))))
        self.assertIn('Workspace unmapped', result['error']['message'])
        self.reader.assert_not_called()
    def test_stdio_offline_catalog_and_parse_error(self):
        import sys
        command = [sys.executable, str(Path(launcher.__file__)), '--bridge', str(Path(bridge.__file__)), '--mapping', str(self.path), '--keychain-account', 'http://127.0.0.1:24886']
        result = subprocess.run(command, input=b'{bad\n{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n', capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        lines = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(lines[0]['error']['code'], -32700)
        self.assertEqual(len(lines[1]['result']['tools']), 5)
        self.assertEqual(result.stderr, b'')
    def test_invalid_account_rejected_without_read(self):
        for url in ['http://example.com','https://user:password@example.com','https://example.com/path','https://example.com/?x=1']:
            with self.assertRaises(launcher.CredentialError): self.make(account=url)
        self.reader.assert_not_called()

if __name__=='__main__': unittest.main()
