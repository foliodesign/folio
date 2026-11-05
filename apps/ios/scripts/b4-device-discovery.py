#!/usr/bin/env python3
"""Bounded CoreDevice discovery and install evidence; discovery stdout is ID + UDID."""
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlsplit

TIMEOUT = 10
MAX_CANDIDATES = 8


def message(stage, reason):
    advice = {
        'locked': 'Unlock the iPhone/iPad, then rerun. No passcode is entered.',
        'developer-mode': 'Enable Settings > Privacy & Security > Developer Mode, restart and confirm, then rerun.',
        'unsupported-os': 'Update the device to iOS/iPadOS 26 or later, then rerun.',
        'unknown-readiness': 'OS version or Developer Mode could not be verified; inspect Xcode Devices and Simulators.',
        'not-found': 'No matching physical device. Connect by cable and check FOLIO_DEVICE/FOLIO_DEVICE_TYPE.',
        'ambiguous': 'More than one device has that name; use FOLIO_DEVICE=<udid>.',
        'invalid-selector': 'Use FOLIO_DEVICE_TYPE=iPhone or iPad.',
        'trust': 'Connect by cable, unlock, accept Trust This Computer and pair in Xcode Devices and Simulators.',
        'automation': 'Owner must resolve the UI Automation prompt; this is separate from discovery.',
        'timeout': 'Command timed out; check cable/device availability, then rerun.',
        'unavailable': 'Device is unavailable; check cable/device availability, then rerun.',
        'probe-failed': 'Device probe failed; check device services, then rerun.',
        'invalid-json': 'Invalid device JSON; rerun with the supported Xcode CLI.',
        'identity-mismatch': 'Probe identity does not match the candidate; no device selected.',
        'candidate-limit': 'Candidate limit reached; disconnect other devices, then rerun.',
    }
    print(f'{stage}: {reason}. {advice.get(reason, "Command failed; inspect the CLI outcome before retrying.")}', file=sys.stderr)


def reason(text):
    text = text.lower()
    if 'passcode' in text or 'locked' in text:
        return 'locked'
    if 'automation' in text:
        return 'automation'
    if 'developer mode' in text:
        return 'developer-mode'
    if any(word in text for word in ('trust', 'pairing', 'paired')):
        return 'trust'
    if 'timeout' in text or 'timed out' in text:
        return 'timeout'
    return 'probe-failed'


def command(args, timeout=TIMEOUT + 2):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, 'timeout'
    except OSError:
        return 127, 'probe-failed'
    return result.returncode, reason(result.stdout + result.stderr)


def query(args, path):
    # Each query writes a unique file; a failed command can never reuse old JSON.
    status, failure = command(['xcrun', 'devicectl', *args, '--timeout', str(TIMEOUT), '--json-output', str(path)])
    if status:
        return None, failure
    try:
        document = json.loads(path.read_text())
        if document.get('info', {}).get('outcome', 'success') != 'success' or document.get('error'):
            return None, reason(json.dumps(document.get('error', {})))
        result = document['result']
        if not isinstance(result, dict):
            raise ValueError('result')
        return result, None
    except (OSError, ValueError, KeyError, AttributeError, TypeError):
        return None, 'invalid-json'


def fields(device):
    properties = device.get('properties', {})
    if not isinstance(properties, dict):
        raise ValueError('properties')
    # Modern fields are authoritative when present; never merge contradictory records.
    hardware = properties.get('hardware', device.get('hardwareProperties', {}))
    connection = properties.get('connection', device.get('connectionProperties', {}))
    if not isinstance(hardware, dict) or not isinstance(connection, dict):
        raise ValueError('fields')
    return hardware, connection


def identity(device):
    hardware, connection = fields(device)
    identifier, udid = device.get('identifier'), hardware.get('udid')
    if not all(isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9-]+', value) for value in (identifier, udid)):
        return None
    if hardware.get('reality') != 'physical' or hardware.get('deviceType') not in ('iPad', 'iPhone') or connection.get('pairingState') != 'paired':
        return None
    return identifier, udid


def metadata(device):
    properties = device.get('properties', {})
    legacy = device.get('deviceProperties', {})
    state = properties.get('state', legacy)
    software = properties.get('software', legacy)
    if not isinstance(state, dict) or not isinstance(software, dict):
        raise ValueError('metadata')
    version = software.get('osVersionNumber')
    if isinstance(version, dict):
        version = version.get('stringValue')
    developer = state.get('developerModeStatus')
    if isinstance(developer, dict):
        developer = 'enabled' if 'enabled' in developer else 'disabled' if 'disabled' in developer else None
    return state.get('name'), version, developer


def discover(output):
    selector = os.environ.get('FOLIO_DEVICE', '')
    requested_type = os.environ.get('FOLIO_DEVICE_TYPE', '')
    if requested_type and requested_type not in ('iPhone', 'iPad'):
        message('discovery', 'invalid-selector')
        return 2
    device_type = requested_type or (None if selector else 'iPad')
    with tempfile.TemporaryDirectory(prefix='b4-discovery-', dir=output) as directory:
        directory = Path(directory)
        result, failure = query(['list', 'devices'], directory / 'list.json')
        if failure:
            message('discovery/list', failure)
            return 2
        devices = result.get('devices')
        if not isinstance(devices, list) or not all(isinstance(d, dict) for d in devices):
            message('discovery/list', 'invalid-json')
            return 2
        candidates = []
        failed = False
        for device in devices:
            try:
                hardware, _ = fields(device)
                name, _, _ = metadata(device)
                if hardware.get('reality') != 'physical' or hardware.get('deviceType') not in ('iPhone', 'iPad'):
                    continue
                if device_type and hardware.get('deviceType') != device_type:
                    continue
                if selector and selector not in (hardware.get('udid'), name, device.get('identifier')):
                    continue
                candidates.append(device)
            except (ValueError, AttributeError, TypeError):
                message('discovery/candidate', 'invalid-json')
                failed = True
        if selector and len(candidates) > 1:
            message('discovery', 'ambiguous')
            return 2
        if not candidates and (selector or requested_type):
            message('discovery', 'not-found')
            return 2
        probes = 0
        locked = False
        for index, device in enumerate(candidates):
            hardware, connection = fields(device)
            if connection.get('pairingState') != 'paired':
                message('discovery/candidate', 'trust')
                failed = True
                continue
            candidate = identity(device)
            if candidate is None:
                message('discovery/candidate', 'identity-mismatch')
                failed = True
                continue
            if probes == MAX_CANDIDATES:
                message('discovery', 'candidate-limit')
                return 2
            probes += 1
            identifier, udid = candidate
            details, failure = query(['device', 'info', 'details', '--device', identifier], directory / f'details-{index}.json')
            if failure:
                message('discovery/details', failure)
                failed = True
                locked |= failure == 'locked'
                continue
            try:
                fresh = identity(details)
                _, connection = fields(details)
                name, version, developer = metadata(details)
            except (ValueError, AttributeError, TypeError):
                fresh = None
            if fresh != candidate or fields(details)[0].get('deviceType') != hardware.get('deviceType'):
                message('discovery/details', 'identity-mismatch')
                failed = True
                continue
            if not isinstance(version, str) or not re.fullmatch(r'\d+(?:\.\d+)*', version) or developer not in ('enabled', 'disabled'):
                message('discovery/details', 'unknown-readiness')
                failed = True
                continue
            if int(version.split('.')[0]) < 26:
                message('discovery/details', 'unsupported-os')
                failed = True
                continue
            if developer != 'enabled':
                message('discovery/details', 'developer-mode')
                failed = True
                continue
            lock, failure = query(['device', 'info', 'lockState', '--device', identifier], directory / f'lock-{index}.json')
            if failure:
                message('discovery/lockState', failure)
                failed = True
                locked |= failure == 'locked'
                continue
            if lock.get('deviceIdentifier') != identifier:
                message('discovery/lockState', 'identity-mismatch')
                failed = True
                continue
            if lock.get('passcodeRequired') is True:
                message('discovery/lockState', 'locked')
                failed = True
                locked = True
                continue
            if lock.get('passcodeRequired') is not False:
                message('discovery/lockState', 'invalid-json')
                failed = True
                continue
            if connection.get('state', connection.get('tunnelState')) != 'connected':
                message('discovery/details', 'unavailable')
                continue
            print(f'Selected {hardware["deviceType"]}: {name}, OS {version}, UDID {udid}', file=sys.stderr)
            print(identifier, udid)
            return 0
        message('discovery', 'unavailable')
        return 3 if locked else 2 if failed or selector or requested_type else 0


def file_url_path(value):
    if not isinstance(value, str):
        raise ValueError('file URL')
    url = urlsplit(value)
    path = PurePosixPath(unquote(url.path))
    if url.scheme != 'file' or url.netloc not in ('', 'localhost') or url.query or url.fragment or not path.is_absolute() or '..' in path.parts:
        raise ValueError('file URL')
    return path


def evidence(stage, identifier, output, bundle_id=None):
    if stage == 'verify':
        apps, failure = query(['device', 'info', 'apps', '--device', identifier, '--bundle-id', bundle_id], Path(output) / 'apps.json')
        if failure:
            message('verification/apps', failure)
            return 2
        processes, failure = query(['device', 'info', 'processes', '--device', identifier], Path(output) / 'processes.json')
        if failure:
            message('verification/processes', failure)
            return 2
    path = Path(output) / f'{stage}.json'
    args = ['device', 'info', 'files', '--device', identifier, '--domain-type', 'systemCrashLogs']
    result, failure = query(args, path)
    if failure:
        message(stage, failure)
        return 2
    if result.get('deviceIdentifier') != identifier or result.get('domain') != 'systemCrashLogs':
        message(stage, 'identity-mismatch')
        return 2
    if stage == 'crashes-before':
        return 0
    try:
        before = json.loads((Path(output) / 'crashes-before.json').read_text())['result']
        def folio_files(record):
            if record.get('deviceIdentifier') != identifier or record.get('domain') != 'systemCrashLogs':
                raise ValueError('identity')
            files = record['files']
            if not isinstance(files, list) or not all(isinstance(f, dict) and isinstance(f.get('name'), str) for f in files):
                raise ValueError('files')
            return sorted((f for f in files if 'folio' in f['name'].lower() or 'folio' in str(f.get('relativePath', '')).lower()), key=lambda f: (f.get('relativePath', f['name']), f['name']))
        if processes.get('deviceIdentifier') != identifier:
            raise ValueError('process identity')
        running = processes['runningProcesses']
        if not isinstance(running, list) or not all(isinstance(p, dict) for p in running):
            raise ValueError('processes')
        if apps.get('deviceIdentifier') != identifier:
            raise ValueError('app device identity')
        installed = apps['apps']
        if not isinstance(installed, list) or len(installed) != 1 or installed[0]['bundleIdentifier'] != bundle_id:
            raise ValueError('app bundle identity')
        bundle_path = file_url_path(installed[0]['url'])
        matches = []
        for process in running:
            executable = process.get('executable')
            if executable is None:
                continue
            executable_path = file_url_path(executable)
            # The app executable lives directly in the bundle, unlike its Share extension.
            if executable_path.parent == bundle_path and isinstance(process.get('processIdentifier'), int) and process['processIdentifier'] > 0:
                matches.append(process)
        if not matches or folio_files(before) != folio_files(result):
            print('Installed verification: no. Installed bundle is not running or Folio crash records changed.', file=sys.stderr)
            return 2
        print(f'Installed verification: yes. Folio still running after 10 seconds, PID {matches[0]["processIdentifier"]} in {bundle_path} ({bundle_id}); {len(folio_files(result))} Folio crash records unchanged. Evidence: {output}')
        return 0
    except (OSError, KeyError, ValueError, TypeError, AttributeError):
        message('verification', 'invalid-json')
        return 2


if __name__ == '__main__':
    if sys.argv[1] == 'bundle-id':
        with open(sys.argv[2], 'rb') as stream:
            bundle_id = plistlib.load(stream)['CFBundleIdentifier']
        if not isinstance(bundle_id, str) or not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle_id):
            sys.exit('Invalid built app bundle identifier')
        print(bundle_id)
        sys.exit(0)
    if sys.argv[1] == 'discover':
        sys.exit(discover(sys.argv[2]))
    if sys.argv[1] in ('crashes-before', 'verify'):
        sys.exit(evidence(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None))
    # Install/launch errors retain their CLI status and get fixed actionable labels.
    stage = sys.argv[1]
    status, failure = command(sys.argv[2:], timeout=122)
    if status:
        message(stage, failure)
    else:
        print(f'{stage}: complete.')
    sys.exit(status if status >= 0 else 128 - status)
