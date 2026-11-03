"""Offline lab capture verification/export. Never accesses devices or a database."""
import argparse
from fractions import Fraction
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tempfile
import uuid
import zipfile

MAX_FILE = 512 * 1024 * 1024
MAX_TOTAL = 2 * 1024 * 1024 * 1024
MAX_MANIFEST = 1024 * 1024
MAX_LINE = 1024 * 1024
KINDS = {'video', 'camera_frames', 'pose2d', 'pose3d', 'pump_raw', 'pump_parsed', 'events'}
STATES = {'complete', 'interrupted', 'failed', 'unavailable', 'not_requested'}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def fields(value, required, optional=''):
    require(isinstance(value, dict), 'Expected object')
    required, optional = set(required.split()), set(optional.split())
    require(required <= value.keys() and value.keys() <= required | optional, 'Missing or unknown fields')


def text(value):
    require(isinstance(value, str) and 0 < len(value) <= 512, 'Invalid text')


def identifier(value):
    require(isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', value), 'Invalid identity')


def integer(value, minimum=0, maximum=9007199254740991):
    require(type(value) is int and minimum <= value <= maximum, 'Invalid integer')
    return value


def decimal(value):
    require(isinstance(value, str) and re.fullmatch(r'0|[1-9][0-9]{0,24}', value), 'Invalid decimal timestamp')
    return int(value)


def rational(value):
    fields(value, 'value timescale', 'epoch')
    raw = value['value']
    require(isinstance(raw, str) and re.fullmatch(r'0|-?[1-9][0-9]{0,18}', raw), 'PTS value must be an integer string')
    require(-(2**63) <= int(raw) < 2**63, 'PTS outside Int64')
    if 'epoch' in value:
        epoch = value['epoch']
        require(isinstance(epoch, str) and re.fullmatch(r'0|-?[1-9][0-9]{0,18}', epoch) and -(2**63) <= int(epoch) < 2**63, 'Invalid PTS epoch')
    return Fraction(int(raw), integer(value['timescale'], 1, 2**31-1))


def video_seconds(pts, origin):
    result = rational(pts) - rational(origin)
    require(pts.get('epoch') == origin.get('epoch'), 'PTS epoch differs or is unknown; cannot normalize')
    require(result >= 0, 'PTS before video origin')
    return float(result)


def relative(value):
    text(value)
    require('\\' not in value and '\x00' not in value, 'Invalid path')
    path = PurePosixPath(value)
    require(not path.is_absolute() and all(p not in ('', '.', '..') for p in value.split('/')), 'Unsafe relative path')
    require(value != 'manifest.json', 'Manifest cannot hash itself')
    return value


def no_symlinks(path):
    for part in (path, *path.parents):
        require(not part.is_symlink(), 'Symlink path rejected')


def load_json(data):
    def unique(pairs):
        out = {}
        for k, v in pairs:
            require(k not in out, 'Duplicate JSON key')
            out[k] = v
        return out
    def nonfinite(_):
        raise ValueError('Nonfinite JSON number')
    try:
        return json.loads(data, object_pairs_hook=unique, parse_constant=nonfinite)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError('Invalid JSON') from error


def validate_manifest(m):
    fields(m, 'schema capture_id mode host_clock_id started_host_ns ended_host_ns streams files', 'action side strategy utc_anchor')
    require(m['schema'] == 'fox.lab_capture.v1', 'Unsupported capture schema')
    identifier(m['capture_id']); identifier(m['host_clock_id'])
    require(m['mode'] in ('free_capture', 'exercise_evaluation'), 'Invalid capture mode')
    for key in ('action', 'strategy'):
        if m.get(key) is not None:
            text(m[key])
    require(m.get('side') in (None, 'left', 'right', 'both', 'not_applicable'), 'Invalid anatomical side')
    require(m['mode'] != 'exercise_evaluation' or (m.get('action') is not None and m.get('strategy') is not None), 'Evaluation requires action and strategy')
    start, end = decimal(m['started_host_ns']), decimal(m['ended_host_ns'])
    require(end >= start, 'End precedes start')
    if m.get('utc_anchor') is not None:
        a = m['utc_anchor']; fields(a, 'host_ns utc_us uncertainty_us method')
        decimal(a['host_ns']); decimal(a['utc_us']); decimal(a['uncertainty_us']); text(a['method'])
    require(isinstance(m['streams'], list) and len(m['streams']) <= 64, 'Too many streams')
    streams = {}
    for s in m['streams']:
        fields(s, 'id kind state record_schema source', 'reason')
        identifier(s['id']); require(s['id'] not in streams, 'Duplicate stream identity')
        require(s['kind'] in KINDS and s['state'] in STATES, 'Unsupported stream kind or state')
        text(s['record_schema'])
        if s.get('reason') is not None:
            text(s['reason'])
        require(s['state'] not in ('interrupted', 'failed', 'unavailable') or s.get('reason') is not None, 'Failure reason required')
        src = s['source']; fields(src, 'producer version clock_id', 'device_alias coordinate_system unit source_id')
        for key in ('producer', 'version', 'clock_id'):
            text(src[key])
        for key in ('device_alias', 'coordinate_system', 'unit'):
            if src.get(key) is not None:
                text(src[key])
        if src.get('source_id') is not None:
            identifier(src['source_id'])
        require(src['clock_id'] == m['host_clock_id'], 'Stream receive clock differs from capture host clock')
        streams[s['id']] = s
    require(isinstance(m['files'], list) and len(m['files']) <= 256, 'Too many files')
    files, total, counts = {}, 0, {}
    for f in m['files']:
        fields(f, 'path bytes sha256 stream_id')
        name = relative(f['path']); require(name not in files, 'Duplicate file path')
        integer(f['bytes'], 0, MAX_FILE)
        require(isinstance(f['sha256'], str) and re.fullmatch(r'[0-9a-f]{64}', f['sha256']), 'Invalid SHA256')
        require(f['stream_id'] in streams, 'Missing file stream')
        require(streams[f['stream_id']]['state'] not in ('not_requested', 'unavailable'), 'Unavailable stream has data')
        counts[f['stream_id']] = counts.get(f['stream_id'], 0) + 1
        total += f['bytes']; files[name] = f
    require(total <= MAX_TOTAL, 'Package too large')
    require(all(n <= 1 for n in counts.values()), 'v1 requires one asset per stream; chunk ordering is undefined')
    require(all(s['state'] != 'complete' or counts.get(s['id'], 0) > 0 for s in streams.values()), 'Complete stream has no file')
    return streams, files


def verify_rows(open_file, names, streams, m):
    parsed = set()
    for name, f in names.items():
        stream = streams[f['stream_id']]
        if stream['record_schema'] in ('fox.pump_control_event.v1', 'fox.pump_capture_context.v1'):
            require(stream['kind'] == 'events', 'PUMP control context must be an events stream')
            with open_file(name) as source:
                if stream['record_schema'] == 'fox.pump_capture_context.v1':
                    raw = source.read(MAX_LINE + 1); require(len(raw) <= MAX_LINE, 'Oversize PUMP context')
                    context = load_json(raw)
                    fields(context, 'schema session_id capture_id host_clock_id devices events')
                    require(context['schema'] == 'fox.pump_capture_context.v1' and context['capture_id'] == m['capture_id'], 'Wrong PUMP capture context')
                    require(context['host_clock_id'] == m['host_clock_id'], 'Wrong PUMP context clock')
                    identifier(context['session_id'])
                    require(isinstance(context['devices'], list) and len(context['devices']) <= 2, 'Invalid PUMP pair')
                    aliases, device_ids = set(), set()
                    for device in context['devices']:
                        fields(device, 'id name state writable', 'alias heartbeatNS workState')
                        require(device.get('alias') in ('pump-A', 'pump-B') and device['alias'] not in aliases and device['id'] not in device_ids, 'Duplicate PUMP identity')
                        aliases.add(device['alias']); device_ids.add(device['id'])
                    require(isinstance(context['events'], list), 'Invalid PUMP context events')
                    for event in context['events']:
                        verify_control_event(event, stream, m)
                        require(event['session_id'] == context['session_id'], 'Mixed PUMP sessions')
                else:
                    while line := source.readline(MAX_LINE + 1):
                        require(len(line) <= MAX_LINE, 'Oversize PUMP control row')
                        verify_control_event(load_json(line), stream, m)
            parsed.add(f['stream_id'])
            continue
        if stream['record_schema'] == 'fox.lab_pump_events.v1':
            require(stream['kind'] == 'pump_raw', 'PUMP schema kind mismatch')
            with open_file(name) as source:
                verify_pump_rows(source, stream, m)
            parsed.add(f['stream_id'])
            continue
        if stream['record_schema'] != 'fox.lab_frame.v1':
            continue
        require(stream['kind'] == 'camera_frames', 'Frame schema kind mismatch')
        prev_seq, prev_pts, prev_host, origin = -1, None, -1, None
        with open_file(name) as source:
            while line := source.readline(MAX_LINE + 1):
                require(len(line) <= MAX_LINE, 'Oversize row')
                row = load_json(line)
                fields(row, 'schema seq pts origin_pts video_seconds host_received_ns state', 'reason')
                require(row['schema'] == 'fox.lab_frame.v1', 'Wrong row schema')
                seq = integer(row['seq']); pts = rational(row['pts']); current_origin = (rational(row['origin_pts']), row['origin_pts'].get('epoch'))
                require(seq > prev_seq and (prev_pts is None or pts >= prev_pts), 'Out of order camera row')
                require(origin is None or origin == current_origin, 'Video origin changed; start a new stream')
                value = row['video_seconds']; require(type(value) in (int, float) and math.isfinite(value), 'Nonfinite video time')
                require(abs(value - video_seconds(row['pts'], row['origin_pts'])) <= 0.000001, 'Incorrect normalized PTS')
                host = decimal(row['host_received_ns'])
                require(decimal(m['started_host_ns']) <= host <= decimal(m['ended_host_ns']) and host >= prev_host, 'Host receive time outside capture or out of order')
                require(row['state'] in ('observed', 'dropped'), 'Invalid frame state')
                if row.get('reason') is not None:
                    text(row['reason'])
                require(row['state'] != 'dropped' or row.get('reason') is not None, 'Dropped frame requires reason')
                prev_seq, prev_pts, prev_host, origin = seq, pts, host, current_origin
        parsed.add(f['stream_id'])
    return sorted(s['id'] for s in streams.values() if s['id'] not in parsed and any(f['stream_id'] == s['id'] for f in names.values()))


def verify_control_event(event, stream, manifest):
    fields(event, 'schema synthetic event_id session_id host_clock_id host_received_ns utc kind',
           'device_id device_alias request_id request_devices capture_id configuration packet_hex outcomes raw_hex state connection_segment_id')
    require(event['schema'] == 'fox.pump_control_event.v1' and type(event['synthetic']) is bool, 'Wrong PUMP control schema')
    require(event['host_clock_id'] == stream['source']['clock_id'] == manifest['host_clock_id'], 'Wrong PUMP control clock')
    for key in ('event_id', 'session_id'):
        identifier(event[key])
    require(event.get('capture_id', manifest['capture_id']) == manifest['capture_id'], 'Wrong PUMP control capture')
    # Preparation precedes video. Keep its original time as context, not a motion sample.
    require(decimal(event['host_received_ns']) <= decimal(manifest['ended_host_ns']), 'PUMP control comes after this package')
    text(event['kind']); text(event['utc'])
    if 'configuration' in event:
        identifier(event.get('request_id'))
        pair = event.get('request_devices', {})
        require(type(pair) is dict and set(pair) == {'A', 'B'}, 'Missing frozen PUMP request devices')
        for value in pair.values():
            require(type(value) is str and str(uuid.UUID(value)).lower() == value.lower(), 'Invalid PUMP request device')
        require(pair['A'].lower() != pair['B'].lower(), 'Duplicate PUMP request device')
        c = event['configuration']; fields(c, 'mode kg reduction')
        tags = {'standard': 1, 'constant': 7, 'eccentric': 5, 'concentric': 6}
        require(c['mode'] in tags, 'Unknown PUMP mode')
        directional = c['mode'] in ('eccentric', 'concentric')
        kg = c['kg']; require(type(kg) in (int, float) and math.isfinite(kg) and (5 if directional else 2) <= kg <= 20 and abs(kg * 10 - round(kg * 10)) < 1e-8, 'Invalid Pro setpoint')
        require(type(c['reduction']) is int and c['reduction'] in (0, 25, 50) and (directional or c['reduction'] == 0), 'Invalid PUMP reduction')
        packet = [0x54, 7 if directional else 6, 2, tags[c['mode']], round(kg * 10)]
        if directional: packet.append(c['reduction'])
        packet.append(-sum(packet) & 255)
        require(event.get('packet_hex') == bytes(packet).hex(), 'PUMP configuration packet mismatch')
    else:
        require('packet_hex' not in event, 'PUMP packet without configuration')


def verify_pump_rows(source, stream, manifest):
    from pump_telemetry import decode
    segments, last_host = {}, -1
    while line := source.readline(MAX_LINE + 1):
        require(len(line) <= MAX_LINE, 'Oversize PUMP row')
        e = load_json(line)
        common = 'schema capture_id device_alias connection_segment_id host_clock_id host_received_ns'
        if e.get('schema') == 'fox.lab_pump_notification.v1':
            fields(e, common + ' notification_seq decoded', 'device_tick')
        else:
            fields(e, common + ' state', 'reason')
            require(e['schema'] == 'fox.lab_pump_connection.v1', 'Unknown PUMP event schema')
        require(e['capture_id'] == manifest['capture_id'], 'Wrong PUMP capture')
        require(e['device_alias'] == stream['source'].get('device_alias') and e['host_clock_id'] == stream['source']['clock_id'], 'Wrong PUMP device/clock')
        identifier(e['connection_segment_id']); identifier(e['device_alias']); identifier(e['host_clock_id'])
        host = decimal(e['host_received_ns'])
        require(decimal(manifest['started_host_ns']) <= host <= decimal(manifest['ended_host_ns']) and host >= last_host, 'PUMP host clock outside capture/out of order')
        last_host = host
        previous = segments.setdefault(e['connection_segment_id'], {'seq': -1, 'closed': False})
        require(not previous['closed'], 'PUMP data after segment disconnected')
        if e['schema'] == 'fox.lab_pump_notification.v1':
            seq = integer(e['notification_seq']); require(seq > previous['seq'], 'Duplicate/out of order notification')
            require(e.get('device_tick') is None, 'Observed PUMP profile has no device tick')
            d = e['decoded']; fields(d, 'profile state raw_hex kind fields', 'reason checksum_pass')
            require(isinstance(d['raw_hex'], str) and len(d['raw_hex']) <= 131072 and re.fullmatch(r'(?:[0-9a-f]{2})*',d['raw_hex']) is not None, 'Invalid raw notification hex')
            expected = decode(bytes.fromhex(d['raw_hex']))
            normalized = dict(d); normalized.setdefault('reason',None); normalized.setdefault('checksum_pass',None)
            require(normalized == expected, 'Decoded PUMP values disagree with original bytes')
            previous['seq'] = seq
        else:
            require(e['state'] in ('discovering','subscribed_no_data','receiving','failed','disconnected'), 'Unknown PUMP connection state')
            if e['state'] in ('failed','disconnected'):
                text(e.get('reason'))
            previous['closed'] = e['state'] == 'disconnected'


def check_bytes(source, expected):
    size, digest = 0, hashlib.sha256()
    while chunk := source.read(1024 * 1024):
        size += len(chunk); require(size <= expected['bytes'], 'Extra asset bytes')
        digest.update(chunk)
    require(size == expected['bytes'] and digest.hexdigest() == expected['sha256'], 'Asset size or SHA256 mismatch')


def summary(m, raw, unparsed):
    return dict(capture_id=m['capture_id'], stream_states={s['id']:s['state'] for s in m['streams']},
                unparsed_streams=unparsed, manifest_sha256=hashlib.sha256(raw).hexdigest(),
                integrity_verified=True, formal_training_imported=False)


def verify_package(root):
    root = Path(root).absolute(); no_symlinks(root)
    require(root.is_dir(), 'Package directory missing')
    manifest = root / 'manifest.json'; no_symlinks(manifest)
    require(manifest.is_file() and manifest.stat().st_size <= MAX_MANIFEST, 'Missing or oversized manifest')
    raw = manifest.read_bytes(); m = load_json(raw); streams, files = validate_manifest(m)
    actual = set()
    for path in root.rglob('*'):
        no_symlinks(path)
        if path.is_dir():
            continue
        require(path.is_file(), 'Special file rejected')
        actual.add(path.relative_to(root).as_posix())
    require(actual == set(files) | {'manifest.json'}, 'Missing or unlisted package file')
    for name, f in files.items():
        with (root / name).open('rb') as source:
            check_bytes(source, f)
    unparsed = verify_rows(lambda n:(root/n).open('rb'), files, streams, m)
    return summary(m, raw, unparsed)


def verify_export(filename):
    path = Path(filename).absolute(); no_symlinks(path)
    try:
        with zipfile.ZipFile(path) as z:
            infos = z.infolist(); names = [i.filename for i in infos]
            require(len(infos) <= 257 and len(set(names)) == len(names), 'Duplicate or excessive ZIP entries')
            require('manifest.json' in names, 'ZIP manifest missing')
            total = 0
            for info in infos:
                require(info.filename == 'manifest.json' or relative(info.filename), 'Unsafe ZIP path')
                mode = info.external_attr >> 16
                require(not stat.S_ISLNK(mode) and not info.is_dir(), 'ZIP symlink/directory rejected')
                require(not info.flag_bits & 1 and info.file_size <= MAX_FILE, 'Encrypted or oversized ZIP entry')
                total += info.file_size
            require(total <= MAX_TOTAL + MAX_MANIFEST, 'ZIP too large')
            require(z.getinfo('manifest.json').file_size <= MAX_MANIFEST, 'Oversize ZIP manifest')
            raw = z.read('manifest.json'); m = load_json(raw); streams, files = validate_manifest(m)
            require(set(names) == set(files) | {'manifest.json'}, 'ZIP unlisted/missing file')
            for name, f in files.items():
                with z.open(name) as source:
                    check_bytes(source, f)
            return summary(m, raw, verify_rows(z.open, files, streams, m))
    except (zipfile.BadZipFile, RuntimeError, EOFError) as error:
        raise ValueError('Corrupt or unreadable ZIP') from error


def export_package(root, destination):
    root = Path(root).absolute(); no_symlinks(root)
    root = root.resolve(strict=True)
    before = verify_package(root)
    target = Path(destination).absolute(); no_symlinks(target)
    target = target.resolve(strict=False)
    require(not target.exists(), 'Export destination exists')
    require(target.parent.is_dir(), 'Export parent missing')
    require(root not in target.parents, 'Export must be outside source package')
    fd, temp = tempfile.mkstemp(prefix='.fox-lab-export-', dir=target.parent)
    os.close(fd)
    try:
        m = load_json((Path(root)/'manifest.json').read_bytes())
        with zipfile.ZipFile(temp, 'w', compression=zipfile.ZIP_STORED) as z:
            for name in ['manifest.json', *sorted(f['path'] for f in m['files'])]:
                source = Path(root)/name; no_symlinks(source)
                z.write(source, name)
        after = verify_export(temp)
        require(after == before, 'Source changed during export')
        # Exclusive publication: a concurrent destination must never be overwritten.
        with open(temp, 'rb') as f:
            os.fsync(f.fileno())
        os.link(temp, target)
        return after
    except FileExistsError as error:
        raise ValueError('Export destination exists') from error
    finally:
        Path(temp).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['verify', 'export', 'verify-export'])
    parser.add_argument('source'); parser.add_argument('destination', nargs='?')
    args = parser.parse_args()
    require(args.action != 'export' or args.destination is not None, 'Export destination required')
    result = export_package(args.source, args.destination) if args.action == 'export' else (verify_package(args.source) if args.action == 'verify' else verify_export(args.source))
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
