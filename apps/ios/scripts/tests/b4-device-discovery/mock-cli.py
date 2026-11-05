#!/usr/bin/env python3
import json
import os
import plistlib
import sys
import time
from pathlib import Path

args = sys.argv[1:]
name = Path(sys.argv[0]).name
scenario = json.loads(Path(os.environ['B4_SCENARIO']).read_text())
with open(os.environ['B4_ARGV'], 'a') as stream:
    stream.write(json.dumps([name, args, os.environ.get('DEVELOPER_DIR')]) + '\n')
if name == 'sleep':
    sys.exit(0)
if name == 'xcodegen':
    sys.exit(scenario.get('generate_status', 0))
if name == 'xcodebuild':
    app = Path(args[args.index('-derivedDataPath') + 1]) / 'Build/Products/Debug-iphoneos/Folio.app'
    app.mkdir(parents=True, exist_ok=True)
    with (app / 'Info.plist').open('wb') as stream:
        plistlib.dump({'CFBundleIdentifier': scenario.get('bundle_id', 'app.foliodesign.folio')}, stream)
    sys.exit(scenario.get('build_status', 0))
assert name == 'xcrun' and args[0] == 'devicectl', args
args = args[1:]
if args[:2] == ['list', 'devices']:
    response = scenario.get('list')
    stage = 'list'
elif args[:3] == ['device', 'info', 'details']:
    response = scenario['details'][args[args.index('--device') + 1]]
    stage = 'details'
elif args[:3] == ['device', 'info', 'lockState']:
    response = scenario.get('lock', {'result': {'deviceIdentifier': args[args.index('--device') + 1], 'passcodeRequired': False}})
    response = scenario.get('locks', {}).get(args[args.index('--device') + 1], response)
    stage = 'lock'
elif args[:3] == ['device', 'info', 'files']:
    identifier = args[args.index('--device') + 1]
    stage = 'crashes'
    response = scenario.get('crashes', {'result': {'files': [{'name': 'Folio-old.ips', 'size': 5}]}})
    if 'verify.json' in args[args.index('--json-output') + 1]:
        response = scenario.get('crashes_after', response)
elif args[:3] == ['device', 'info', 'apps']:
    identifier = args[args.index('--device') + 1]
    assert args[args.index('--bundle-id') + 1] == scenario.get('bundle_id', 'app.foliodesign.folio')
    stage = 'apps'
    response = scenario.get('apps', {'result': {'apps': [{'bundleIdentifier': scenario.get('bundle_id', 'app.foliodesign.folio'), 'url': 'file:///private/new/Folio.app/'}]}})
elif args[:3] == ['device', 'info', 'processes']:
    identifier = args[args.index('--device') + 1]
    stage = 'processes'
    response = scenario.get('processes', {'result': {'runningProcesses': [{'executable': 'file:///private/new/Folio.app/Folio', 'processIdentifier': 42}]}})
elif args[:3] == ['device', 'install', 'app']:
    print(scenario.get('install_error', ''))
    sys.exit(scenario.get('install_status', 0))
elif args[:3] == ['device', 'process', 'launch']:
    print(scenario.get('launch_error', ''))
    sys.exit(scenario.get('launch_status', 0))
else:
    raise AssertionError(args)
if stage in ('crashes', 'processes', 'apps') and isinstance(response, dict) and isinstance(response.get('result'), dict):
    response['result'].setdefault('deviceIdentifier', identifier)
    if stage == 'crashes': response['result'].setdefault('domain', 'systemCrashLogs')
if scenario.get(stage + '_sleep'):
    time.sleep(scenario[stage + '_sleep'])
if scenario.get(stage + '_status'):
    print(scenario.get(stage + '_error', 'probe failure'), file=sys.stderr)
    sys.exit(scenario[stage + '_status'])
path = Path(args[args.index('--json-output') + 1])
path.write_text(response if isinstance(response, str) else json.dumps(response))
