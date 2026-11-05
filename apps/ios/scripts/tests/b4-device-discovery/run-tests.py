#!/usr/bin/env python3
"""Run copied production scripts against PATH-only mocks in a disposable repo."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(__file__).resolve().parents[2]
root = source.parents[2]
temporary = root / '.tmp'
temporary.mkdir(exist_ok=True)


def device(identifier='CORE-A', udid='UDID-A', state='disconnected', legacy=False, **changes):
    fixture = 'legacy.json' if legacy else 'modern.json'
    result = copy.deepcopy(json.loads(Path(__file__).with_name(fixture).read_text())['result'])
    result['identifier'] = identifier
    hardware = result['hardwareProperties'] if legacy else result['properties']['hardware']
    connection = result['connectionProperties'] if legacy else result['properties']['connection']
    hardware['udid'] = udid
    connection['tunnelState' if legacy else 'state'] = state
    hardware.update(changes.pop('hardware', {}))
    connection.update(changes.pop('connection', {}))
    if legacy:
        result['deviceProperties'].update(changes.pop('device_state', {}))
        result['deviceProperties'].update(changes.pop('software', {}))
    else:
        result['properties']['state'].update(changes.pop('device_state', {}))
        result['properties']['software'].update(changes.pop('software', {}))
    return result


def scenario(records=None, details=None, **changes):
    return {'list': {'result': {'devices': records if records is not None else [device()]}},
            'details': details if details is not None else {'CORE-A': {'result': device(state='connected')}}, **changes}


cases = []


def add(name, spec, status=0, selected=None, probes=None, label=None):
    cases.append((name, spec, status, selected, probes, label))


add('modern idle details reachable', scenario(), selected='A', probes=['CORE-A'])
add('legacy idle details reachable', scenario([device(legacy=True)], {'CORE-A': {'result': device(state='connected', legacy=True)}}), selected='A')
add('stale connected details unavailable', scenario([device(state='connected')], {'CORE-A': {'result': device()}}), label='unavailable')
add('missing identifier', scenario([device(identifier=None)]), 2, label='identity-mismatch')
add('missing udid', scenario([device(udid=None)]), 2, label='identity-mismatch')
add('malformed list', scenario(list='{'), 2, label='invalid-json')
add('invalid list schema', scenario(list={'result': {'devices': {}}}), 2, label='invalid-json')
add('invalid candidate schema', scenario([{'properties': []}]), 2, label='invalid-json')
add('malformed details', scenario(details={'CORE-A': '{'}), 2, label='invalid-json')
add('list failure', scenario(list_status=17), 2, label='probe-failed')
add('details failure', scenario(details_status=19), 2, label='probe-failed')
add('details timeout status', scenario(details_status=1, details_error='Command timed out'), 2, label='timeout')
add('details watchdog timeout', scenario(details_sleep=20), 2, label='timeout')
add('locked result', scenario(lock={'result': {'deviceIdentifier': 'CORE-A', 'passcodeRequired': True}}), 3, label='locked')
add('locked first candidate then ready', scenario([device(), device('CORE-B', 'UDID-B')], {'CORE-A': {'result': device(state='connected')}, 'CORE-B': {'result': device('CORE-B', 'UDID-B', 'connected')}}, lock_status=18, lock_error='Device is locked'), 3, probes=['CORE-A', 'CORE-B'], label='locked')
add('lock probe error', scenario(lock_status=18, lock_error='Device is locked'), 3, label='locked')
add('lock malformed', scenario(lock='{'), 2, label='invalid-json')
add('lock unknown', scenario(lock={'result': {'deviceIdentifier': 'CORE-A'}}), 2, label='invalid-json')
add('lock wrong device', scenario(lock={'result': {'deviceIdentifier': 'CORE-B', 'passcodeRequired': False}}), 2, label='identity-mismatch')
add('trust error', scenario(details_status=18, details_error='Trust pairing required'), 2, label='trust')
add('automation error', scenario(details_status=18, details_error='UI Automation prompt timed out'), 2, label='automation')
add('no device generic fallback', scenario([]), probes=[])
excluded = [device(hardware={'deviceType': 'iPhone'}), device(hardware={'reality': 'simulated'}), device(connection={'pairingState': 'unpaired'})]
add('iPhone simulator unpaired excluded', scenario(excluded), 2, probes=[], label='trust')
add('first eligible after exclusions', scenario(excluded + [device(), device('CORE-B', 'UDID-B')]), selected='A', probes=['CORE-A'])
add('first unavailable then eligible', scenario([device(), device('CORE-B', 'UDID-B')], {'CORE-A': {'result': device()}, 'CORE-B': {'result': device('CORE-B', 'UDID-B', 'connected')}}), selected='B', probes=['CORE-A', 'CORE-B'])
add('first probe fails then eligible', scenario([device(), device('CORE-B', 'UDID-B')], {'CORE-A': '{', 'CORE-B': {'result': device('CORE-B', 'UDID-B', 'connected')}}), selected='B', probes=['CORE-A', 'CORE-B'], label='invalid-json')
for name, fresh in [('wrong identifier', device('CORE-B', state='connected')), ('wrong udid', device(udid='UDID-B', state='connected')), ('details unpaired', device(state='connected', connection={'pairingState': 'unpaired'})), ('details simulator', device(state='connected', hardware={'reality': 'simulated'})), ('details iPhone', device(state='connected', hardware={'deviceType': 'iPhone'}))]:
    add(name, scenario(details={'CORE-A': {'result': fresh}}), 2, label='identity-mismatch')
add('modern fields override legacy', scenario([dict(device(connection={'pairingState': 'unpaired'}), hardwareProperties={'reality': 'physical', 'deviceType': 'iPad', 'udid': 'UDID-A'}, connectionProperties={'pairingState': 'paired', 'tunnelState': 'connected'})]), 2, probes=[], label='trust')
add('error envelope connected not selected', scenario(details={'CORE-A': {'info': {'outcome': 'failure'}, 'error': {'message': 'locked'}, 'result': device(state='connected')}}), 3, label='locked')
records = [device(f'CORE-{i}', f'UDID-{i}') for i in range(9)]
add('bounded eight probes', scenario(records, {d['identifier']: {'result': d} for d in records}), 2, probes=[f'CORE-{i}' for i in range(8)], label='candidate-limit')
add('build failure', scenario(build_status=65), 65, selected='A')
add('discovery failure stops build', scenario(list='{', build_status=66), 2, label='invalid-json')
add('generation failure', scenario(generate_status=67), 67, probes=[])
add('install failure', scenario(install_status=71), 71, selected='A', label='install: probe-failed')
add('install trust failure', scenario(install_status=72, install_error='Trust required'), 72, selected='A', label='install: trust')
add('launch failure', scenario(launch_status=73), 73, selected='A', label='launch: probe-failed')
add('launch locked failure', scenario(launch_status=74, launch_error='passcode required'), 74, selected='A', label='launch: locked')
add('launch automation failure', scenario(launch_status=75, launch_error='UI Automation failure'), 75, selected='A', label='launch: automation')

phone = device(hardware={'deviceType': 'iPhone'}, device_state={'name': 'Test iPhone'})
phone_ready = device(state='connected', hardware={'deviceType': 'iPhone'}, device_state={'name': 'Test iPhone'})
add('explicit iPhone type', scenario([phone], {'CORE-A': {'result': phone_ready}}, env={'FOLIO_DEVICE_TYPE': 'iPhone'}), selected='A')
add('explicit phone name', scenario([phone], {'CORE-A': {'result': phone_ready}}, env={'FOLIO_DEVICE': 'Test iPhone'}), selected='A')
add('explicit phone udid', scenario([phone], {'CORE-A': {'result': phone_ready}}, env={'FOLIO_DEVICE': 'UDID-A'}), selected='A')
add('missing selector', scenario(env={'FOLIO_DEVICE': 'missing'}), 2, probes=[], label='not-found')
add('invalid type', scenario(env={'FOLIO_DEVICE_TYPE': 'Mac'}), 2, probes=[], label='invalid-selector')
add('ambiguous name', scenario([device(), device('CORE-B', 'UDID-B')], env={'FOLIO_DEVICE': 'Test iPad'}), 2, probes=[], label='ambiguous')
add('unsupported OS', scenario(details={'CORE-A': {'result': device(state='connected', software={'osVersionNumber': {'stringValue': '25.9'}})}}), 2, label='unsupported-os')
add('developer mode disabled', scenario(details={'CORE-A': {'result': device(state='connected', device_state={'developerModeStatus': {'disabled': {}}})}}), 2, label='developer-mode')
add('unknown OS', scenario(details={'CORE-A': {'result': device(state='connected', software={'osVersionNumber': None})}}), 2, label='unknown-readiness')
add('crash listing unavailable', scenario(crashes_status=18), 2, selected='A', label='crashes-before: probe-failed')
add('process check unavailable', scenario(processes_status=18), 2, selected='A', label='verification/processes: probe-failed')
add('process not running', scenario(processes={'result': {'runningProcesses': []}}), 2, selected='A', label='Installed verification: no')
old_process = {'executable': 'file:///private/old/Folio.app/Folio', 'processIdentifier': 508}
new_process = {'executable': 'file:///private/new/Folio.app/Folio', 'processIdentifier': 1590}
add('old same-named app alone fails', scenario(processes={'result': {'runningProcesses': [old_process]}}), 2, selected='A', label='Installed verification: no')
add('new bundle alongside old passes', scenario(processes={'result': {'runningProcesses': [old_process, new_process]}}), selected='A')
add('bundle prefix sibling fails', scenario(processes={'result': {'runningProcesses': [{'executable': 'file:///private/new/Folio.app.other/Folio', 'processIdentifier': 9}]}}), 2, selected='A', label='Installed verification: no')
add('share extension alone fails', scenario(processes={'result': {'runningProcesses': [{'executable': 'file:///private/new/Folio.app/PlugIns/FolioShare.appex/FolioShare', 'processIdentifier': 9}]}}), 2, selected='A', label='Installed verification: no')
add('resolved bundle setting override', scenario(bundle_id='example.custom.folio'), selected='A')
add('apps query unavailable', scenario(apps_status=18), 2, selected='A', label='verification/apps: probe-failed')
add('missing installed app', scenario(apps={'result': {'apps': []}}), 2, selected='A', label='invalid-json')
add('wrong installed bundle', scenario(apps={'result': {'apps': [{'bundleIdentifier': 'example.other.folio', 'url': 'file:///private/new/Folio.app'}]}}), 2, selected='A', label='invalid-json')
add('wrong app evidence device', scenario(apps={'result': {'deviceIdentifier': 'CORE-WRONG', 'apps': []}}), 2, selected='A', label='invalid-json')
add('new Folio crash', scenario(crashes_after={'result': {'files': [{'name': 'Folio-new.ips'}]}}), 2, selected='A', label='Installed verification: no')
add('unrelated new crash allowed', scenario(crashes_after={'result': {'files': [{'name': 'Folio-old.ips', 'size': 5}, {'name': 'Other.ips'}]}}), selected='A')

add('wrong crash evidence device', scenario(crashes={'result': {'deviceIdentifier': 'CORE-WRONG', 'files': []}}), 2, selected='A', label='identity-mismatch')
add('wrong process evidence device', scenario(processes={'result': {'deviceIdentifier': 'CORE-WRONG', 'runningProcesses': []}}), 2, selected='A', label='invalid-json')
add('changed old Folio crash', scenario(crashes_after={'result': {'files': [{'name': 'Folio-old.ips', 'size': 6}]}}), 2, selected='A', label='Installed verification: no')
add('first locked then ready', scenario([device(), device('CORE-B', 'UDID-B')], {'CORE-A': {'result': device(state='connected')}, 'CORE-B': {'result': device('CORE-B', 'UDID-B', 'connected')}}, locks={'CORE-A': {'result': {'deviceIdentifier': 'CORE-A', 'passcodeRequired': True}}}), selected='B', probes=['CORE-A', 'CORE-B'], label='locked')
add('explicit iPad type', scenario(env={'FOLIO_DEVICE_TYPE': 'iPad'}), selected='A')
add('type and selector disagree', scenario(env={'FOLIO_DEVICE_TYPE': 'iPhone', 'FOLIO_DEVICE': 'UDID-A'}), 2, probes=[], label='not-found')
add('Developer Mode CLI error', scenario(details_status=18, details_error='Developer Mode is disabled'), 2, label='developer-mode')
with tempfile.TemporaryDirectory(prefix='b4-mocks-', dir=temporary) as directory:
    sandbox = Path(directory)
    scripts = sandbox / 'apps/ios/scripts'
    scripts.mkdir(parents=True)
    for name in ['device-build.sh', 'b4-device-discovery.py']:
        shutil.copy2(source / name, scripts / name)
    binaries = sandbox / 'bin'
    binaries.mkdir()
    for name in ['xcrun', 'xcodegen', 'xcodebuild', 'sleep']:
        shutil.copy2(Path(__file__).with_name('mock-cli.py'), binaries / name)
        (binaries / name).chmod(0o755)
    for name, spec, status, selected, probes, label in cases:
        spec_path = sandbox / 'scenario.json'
        argv_path = sandbox / 'argv.jsonl'
        spec_path.write_text(json.dumps(spec))
        argv_path.write_text('')
        # Poison old output: discovery must ignore it and clean only its own unique files.
        output = sandbox / '.tmp/device'
        output.mkdir(parents=True, exist_ok=True)
        sentinel = output / 'devices.json'
        sentinel.write_text(json.dumps({'result': {'devices': [device(state='connected')]}}))
        environment = dict(os.environ, PATH=f'{binaries}:/usr/bin:/bin', B4_SCENARIO=str(spec_path), B4_ARGV=str(argv_path), FOLIO_DEVICE='', FOLIO_DEVICE_TYPE='')
        environment.update(spec.get('env', {}))
        result = subprocess.run(['bash', str(scripts / 'device-build.sh')], env=environment, text=True, capture_output=True, timeout=25)
        try:
            assert result.returncode == status, (result.returncode, status, result.stderr)
            calls = [json.loads(line) for line in argv_path.read_text().splitlines()]
            assert calls[0][0:2] == ['xcodegen', ['generate', '--spec', 'apps/ios/project.yml']]
            assert all(c[2] == '/Applications/Xcode.app/Contents/Developer' for c in calls)
            builds = [c[1] for c in calls if c[0] == 'xcodebuild']
            devcalls = [c[1][1:] for c in calls if c[0] == 'xcrun']
            detail_calls = [c for c in devcalls if c[:3] == ['device', 'info', 'details']]
            if probes is not None:
                assert [c[c.index('--device') + 1] for c in detail_calls] == probes
            for c in devcalls:
                assert '--timeout' in c
                if '--json-output' in c:
                    if c[:2] == ['list', 'devices']:
                        assert c[:4] == ['list', 'devices', '--timeout', '10'] and len(c) == 6
                    else:
                        assert c[:2] == ['device', 'info'] and c[2] in ['details', 'lockState', 'files', 'processes', 'apps']
                        assert c[3] == '--device'
                        assert c[-4:-1] == ['--timeout', '10', '--json-output']
                    assert str(output) in c[c.index('--json-output') + 1]
            installs = [c for c in devcalls if c[:3] == ['device', 'install', 'app']]
            launches = [c for c in devcalls if c[:3] == ['device', 'process', 'launch']]
            if spec.get('generate_status'):
                assert not builds and not devcalls
            elif status in (2, 3) and not selected:
                assert not builds
            else:
                assert len(builds) == 1
                build = builds[0]
                destination = f'platform=iOS,id=UDID-{selected}' if selected else 'generic/platform=iOS'
                assert build == ['-project', 'apps/ios/Folio.xcodeproj', '-scheme', 'Folio', '-configuration', 'Debug', '-destination', destination, '-derivedDataPath', str(output / 'DerivedData'), '-jobs', '1', '-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration', 'build'], build
            should_install = selected and not spec.get('build_status')
            assert len(installs) == int(bool(should_install))
            if should_install:
                assert installs[0] == ['device', 'install', 'app', '--device', f'CORE-{selected}', '--timeout', '120', str(output / 'DerivedData/Build/Products/Debug-iphoneos/Folio.app')]
            should_launch = should_install and not spec.get('install_status') and not spec.get('crashes_status') and name != 'wrong crash evidence device'
            assert len(launches) == int(bool(should_launch))
            if should_launch:
                assert launches[0] == ['device', 'process', 'launch', '--device', f'CORE-{selected}', '--timeout', '120', spec.get('bundle_id', 'app.foliodesign.folio')]
            if should_launch and not spec.get('launch_status') and not spec.get('crashes_status') and not spec.get('apps_status'):
                assert any(c[:3] == ['device', 'info', 'processes'] for c in devcalls)
            if name == 'new bundle alongside old passes':
                assert 'PID 1590' in result.stdout and 'PID 508' not in result.stdout
            if label:
                assert label in result.stderr, result.stderr
            assert sentinel.exists() and not list(output.glob('b4-discovery-*'))
            print('PASS', name)
        except AssertionError:
            print('FAIL', name, result.stdout, result.stderr, file=sys.stderr)
            raise
print(f'PASS {len(cases)} scenarios; no real CLI operations; temporary mock repo removed.')
