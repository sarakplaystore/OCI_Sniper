"""Fly.io deployment guards.

The shipped ``fly.toml`` is what makes ``fly deploy`` work, and two of its
settings are load-bearing for this app:

* ``internal_port`` must match the ``PORT`` the process binds, or Fly's proxy
  has no listener and the app looks dead;
* auto-stop / scale-to-zero must stay off, because the provisioning loop, its
  live log and the boot-disk job only exist in process memory.

These tests read the real file so a future edit cannot quietly break a deploy.
No network access is needed.

    python -m unittest tests.test_fly_deploy -v
"""
import os
import re
import tomllib
import unittest
from pathlib import Path
from unittest import mock

os.environ.setdefault('APP_PASSWORD', 'test-password')

import app  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
FLY_CONFIG = tomllib.loads((ROOT / 'fly.toml').read_text(encoding='utf-8'))
HTTP_SERVICE = FLY_CONFIG.get('http_service', {})


def _megabytes(value):
    """Parse Fly memory values: '512mb', '1gb', or a bare number of MB."""
    if isinstance(value, int):
        return value
    match = re.fullmatch(r'\s*(\d+)\s*(mb|gb|m|g)?\s*', str(value).lower())
    if not match:
        raise AssertionError('unparseable memory setting: %r' % value)
    amount = int(match.group(1))
    unit = match.group(2) or 'mb'
    return amount * 1024 if unit.startswith('g') else amount


class FlyConfigTests(unittest.TestCase):
    def test_app_and_region_are_set(self):
        self.assertIsInstance(FLY_CONFIG.get('app'), str)
        self.assertTrue(FLY_CONFIG['app'].strip())
        self.assertTrue(FLY_CONFIG.get('primary_region'))

    def test_dockerfile_is_the_build_source(self):
        build = FLY_CONFIG.get('build', {})
        dockerfile = build.get('dockerfile', 'Dockerfile')
        self.assertTrue((ROOT / dockerfile).is_file(), 'missing %s' % dockerfile)

    def test_internal_port_matches_the_port_the_app_binds(self):
        # Fly does not inject PORT, so fly.toml has to set it and keep it equal
        # to internal_port. Gunicorn reads PORT from the environment.
        internal_port = HTTP_SERVICE.get('internal_port')
        env_port = FLY_CONFIG.get('env', {}).get('PORT')
        self.assertIsNotNone(internal_port, 'http_service.internal_port is required')
        self.assertIsNotNone(env_port, '[env] PORT is required (Fly does not set it)')
        self.assertEqual(int(env_port), int(internal_port))

        gunicorn_conf = (ROOT / 'gunicorn.conf.py').read_text(encoding='utf-8')
        self.assertIn('os.environ.get("PORT"', gunicorn_conf)

    def test_machine_never_scales_to_zero(self):
        # A stopped Machine loses the in-memory provisioning loop.
        self.assertEqual(
            str(HTTP_SERVICE.get('auto_stop_machines')).lower(), 'off',
            'auto_stop_machines must be off: stopping the Machine kills the loop',
        )
        self.assertGreaterEqual(
            int(HTTP_SERVICE.get('min_machines_running', 0)), 1,
            'keep at least one Machine running',
        )

    def test_health_check_targets_the_real_endpoint(self):
        checks = HTTP_SERVICE.get('checks') or []
        self.assertTrue(checks, 'the app must be probed by Fly')
        paths = [check.get('path') for check in checks]
        self.assertIn('/healthz', paths)
        routes = {rule.rule for rule in app.app.url_map.iter_rules()}
        self.assertIn('/healthz', routes)

        # The health check must stay cheap and unauthenticated, so it cannot
        # sit behind the Basic Auth decorator.
        client = app.app.test_client()
        self.assertEqual(client.get('/healthz').status_code, 200)

    def test_vm_size_is_consistent_and_not_below_the_floor(self):
        vms = FLY_CONFIG.get('vm') or []
        self.assertEqual(len(vms), 1, 'exactly one vm block describes the Machine')
        vm = vms[0]
        self.assertIn('memory', vm)
        megabytes = _megabytes(vm['memory'])
        self.assertGreaterEqual(megabytes, 256, 'the OCI SDK needs real headroom')
        # fly launch used to emit a legacy memory_mb key; if it is present it
        # must agree with memory instead of silently winning.
        if 'memory_mb' in vm:
            self.assertEqual(_megabytes(vm['memory_mb']), megabytes)
        if 'cpus' in vm:
            self.assertGreaterEqual(int(vm['cpus']), 1)

    def test_toplevel_keys_are_not_swallowed_by_the_vm_table(self):
        # TOML has no closing tag for a table: any bare key written after
        # [[vm]] silently becomes a VM field. flyctl then rejects or ignores it.
        vm = FLY_CONFIG['vm'][0]
        for key in ('kill_timeout', 'kill_signal', 'swap_size_mb', 'console_command'):
            self.assertNotIn(
                key, vm,
                '%s is a top-level option and must appear before the [[vm]] block' % key,
            )
        if 'kill_timeout' in FLY_CONFIG:
            self.assertGreaterEqual(int(FLY_CONFIG['kill_timeout']), 30)

    def test_single_process_group(self):
        http_processes = HTTP_SERVICE.get('processes')
        if http_processes is not None:
            self.assertEqual(http_processes, ['app'])
        processes = FLY_CONFIG.get('processes') or {}
        self.assertLessEqual(len(processes), 1, 'app state is per process')

    def test_no_volume_is_required(self):
        # Nothing is written to disk: the OCI key and Telegram token are passed
        # per request and the loop lives in memory.
        self.assertNotIn('mounts', FLY_CONFIG)
        self.assertNotIn('[mounts]', (ROOT / 'fly.toml').read_text(encoding='utf-8'))

    def test_deploy_workflow_exists_and_is_secret_gated(self):
        workflow = ROOT / '.github' / 'workflows' / 'fly-deploy.yml'
        self.assertTrue(workflow.is_file())
        text = workflow.read_text(encoding='utf-8')
        self.assertIn('FLY_API_TOKEN', text)
        self.assertIn('flyctl deploy', text)
        self.assertIn('--ha=false', text, 'deploy must create a single Machine')
        # A missing token must skip, not fail.
        self.assertIn("env.FLY_API_TOKEN != ''", text)


class FlyKeepaliveTests(unittest.TestCase):
    """Fly exposes FLY_APP_NAME (a bare app name), not a hostname."""

    def _defaults(self, env):
        base = {
            'KEEPALIVE_URLS': '',
            'RAILWAY_PUBLIC_DOMAIN': '',
            'RAILWAY_STATIC_URL': '',
            'FLY_APP_NAME': '',
        }
        base.update(env)
        with mock.patch.dict(os.environ, base):
            return app._default_keepalive_urls()

    def test_fly_app_name_builds_the_default_hostname(self):
        self.assertEqual(
            self._defaults({'FLY_APP_NAME': 'oci-sniper'}),
            ['https://oci-sniper.fly.dev/healthz'],
        )

    def test_fly_app_name_with_a_scheme_is_used_as_is(self):
        self.assertEqual(
            self._defaults({'FLY_APP_NAME': 'https://oci.example.com'}),
            ['https://oci.example.com/healthz'],
        )

    def test_explicit_targets_win_over_fly(self):
        self.assertEqual(
            self._defaults({
                'FLY_APP_NAME': 'oci-sniper',
                'KEEPALIVE_URLS': 'https://pinger.example/uuid',
            }),
            ['https://pinger.example/uuid'],
        )

    def test_railway_domain_wins_over_fly_app_name(self):
        # Only one of the two can be set in practice; pick deterministically.
        self.assertEqual(
            self._defaults({
                'FLY_APP_NAME': 'oci-sniper',
                'RAILWAY_PUBLIC_DOMAIN': 'myapp.up.railway.app',
            }),
            ['https://myapp.up.railway.app/healthz'],
        )

    def test_no_hints_means_no_targets(self):
        self.assertEqual(self._defaults({}), [])

    def test_self_domain_helper(self):
        with mock.patch.dict(os.environ, {
            'RAILWAY_PUBLIC_DOMAIN': '', 'RAILWAY_STATIC_URL': '',
            'FLY_APP_NAME': 'oci-sniper',
        }):
            self.assertEqual(app._keepalive_self_domain(), 'oci-sniper.fly.dev')
        with mock.patch.dict(os.environ, {
            'RAILWAY_PUBLIC_DOMAIN': '', 'RAILWAY_STATIC_URL': '',
            'FLY_APP_NAME': '',
        }):
            self.assertEqual(app._keepalive_self_domain(), '')


if __name__ == '__main__':
    unittest.main()
