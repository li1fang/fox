"""Capture-time sensor intake over the existing pinned SSH archive boundary.

Canonical streams are an interchange contract, NOT vendor adapters or fusion.
Raw inbox files stay separate; only eligible, validated samples enter SQLite.
"""
import argparse
import contextlib
import fcntl
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import shutil
import sqlite3
import sys
import tempfile
import time

from archive import Archive, digest, header, identifier, remote, require

SAFE_INT = 2**53 - 1
MAX_STREAM = 256 * 1024**2
KINDS = ('controller_6dof', 'depth', 'resistance')


def encoded(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, allow_nan=False)


def fields(value, expected):
    require(isinstance(value, dict) and set(value) == set(expected.split()), 'Invalid fields')


def integer(value, low=0, high=SAFE_INT):
    require(type(value) is int and low <= value <= high, 'Invalid integer')


def finite(value):
    require(type(value) in (int, float) and math.isfinite(value), 'Non-finite or non-numeric value')


def tick(value):
    require(isinstance(value, str) and re.fullmatch(r'0|[1-9][0-9]{0,24}', value), 'Invalid source tick')
    return int(value)


def text(value):
    require(isinstance(value, str) and 0 < len(value) <= 512, 'Missing/oversized text')


def validate_session(value):
    fields(value, 'schema id activity_id start_us end_us data_class')
    require(value['schema'] == 'fox.training.capture.v1', 'Unsupported capture schema')
    identifier(value['id'])
    identifier(value['activity_id'])
    integer(value['start_us'])
    integer(value['end_us'])
    require(value['end_us'] > value['start_us'], 'Empty capture window')
    require(value['data_class'] in ('synthetic', 'recorded'), 'Invalid data class')


def validate_stream(value):
    fields(value, 'schema id session_id kind source clock frame size sha256')
    require(value['schema'] == 'fox.training.stream.v1', 'Unsupported stream schema')
    for key in ('id', 'session_id'): identifier(value[key])
    require(value['kind'] in KINDS, 'Unsupported sensor kind')
    text(value['source'])
    integer(value['size'], 1, MAX_STREAM)
    require(isinstance(value['sha256'], str) and re.fullmatch('[0-9a-f]{64}', value['sha256']), 'Invalid digest')
    clock = value['clock']
    fields(clock, 'id origin_tick origin_utc_us ticks_per_second uncertainty_us method')
    identifier(clock['id'])
    tick(clock['origin_tick'])
    integer(clock['origin_utc_us'])
    integer(clock['ticks_per_second'], 1, 10**12)
    integer(clock['uncertainty_us'], 0, 86400 * 1000000)
    text(clock['method'])
    frame = value['frame']
    fields(frame, 'id axes handedness measurement_point calibration_archive_id')
    identifier(frame['id'])
    for key in ('axes', 'measurement_point'): text(frame[key])
    require(frame['handedness'] in ('left', 'right', 'not_applicable'), 'Invalid handedness')
    if frame['calibration_archive_id'] is not None: identifier(frame['calibration_archive_id'])


def normalized_values(kind, raw):
    require(isinstance(raw, dict), 'Values must be an object')
    allowed = {
        'controller_6dof': {'position_m', 'orientation_xyzw', 'tracking', 'buttons'},
        'depth': {'asset_id', 'width', 'height', 'encoding', 'meters_per_unit', 'intrinsics'},
        'resistance': {'force_n', 'position_m', 'velocity_m_s', 'power_w'},
    }[kind]
    value = {k: v for k, v in raw.items() if k in allowed}
    dropped = len(raw) - len(value)
    if kind == 'controller_6dof':
        require(value.get('tracking') in ('tracked', 'lost'), 'Missing tracking state')
        pose = {'position_m', 'orientation_xyzw'}
        if value['tracking'] == 'lost':
            require(not pose.intersection(value), 'Lost tracking cannot carry an inherited pose')
        else:
            require(pose <= value.keys(), 'Tracked sample needs a complete pose')
            for name, length in (('position_m', 3), ('orientation_xyzw', 4)):
                require(isinstance(value[name], list) and len(value[name]) == length, 'Invalid vector')
                for component in value[name]: finite(component)
            require(abs(sum(x*x for x in value['orientation_xyzw']) - 1) <= 0.02, 'Quaternion must be unit xyzw')
        if 'buttons' in value:
            buttons = value['buttons']
            require(isinstance(buttons, dict), 'Invalid buttons')
            require(set(buttons) <= {'A', 'B', 'X', 'Y', 'trigger', 'grip'}, 'Unknown button')
            for key, component in buttons.items():
                if key in ('trigger', 'grip'):
                    finite(component)
                    require(0 <= component <= 1, 'Invalid analog button')
                else: require(type(component) is bool, 'Digital button must be boolean')
    elif kind == 'depth':
        require(set(value) == allowed, 'Incomplete depth descriptor')
        identifier(value['asset_id'])
        for name in ('width', 'height'): integer(value[name], 1, 16384)
        require(value['encoding'] in ('uint16_le', 'float32_le'), 'Unknown depth encoding')
        finite(value['meters_per_unit'])
        require(value['meters_per_unit'] > 0, 'Invalid depth scale')
        fields(value['intrinsics'], 'fx fy cx cy')
        for component in value['intrinsics'].values(): finite(component)
        require(value['intrinsics']['fx'] > 0 and value['intrinsics']['fy'] > 0, 'Invalid focal length')
    else:
        require(value, 'No supported resistance fields; do not guess units')
        for component in value.values(): finite(component)
    return value, dropped


class TrainingStore:
    def __init__(self, root):
        self.archive = Archive(root)
        self.root = self.archive.root

    @contextlib.contextmanager
    def connection(self):
        for name in ('training.lock', 'training.sqlite', 'training.sqlite-journal', 'training.sqlite-wal', 'training.sqlite-shm'):
            require(not (self.root/'metadata'/name).is_symlink(), 'Symlink training metadata')
        with open(self.root/'metadata/training.lock', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            db = sqlite3.connect(self.root/'metadata/training.sqlite')
            try:
                version = db.execute('PRAGMA user_version').fetchone()[0]
                require(version in (0, 1), 'Unknown training database version')
                db.execute('PRAGMA foreign_keys=ON')
                db.execute('PRAGMA synchronous=FULL')
                if version == 0:
                    db.executescript('''
                    CREATE TABLE IF NOT EXISTS captures(id TEXT PRIMARY KEY, payload TEXT NOT NULL);
                    CREATE TABLE IF NOT EXISTS streams(id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES captures(id),
                        payload TEXT NOT NULL, receipt TEXT NOT NULL, received_us INTEGER NOT NULL);
                    CREATE TABLE IF NOT EXISTS samples(session_id TEXT NOT NULL REFERENCES captures(id),
                        stream_id TEXT NOT NULL REFERENCES streams(id), seq INTEGER NOT NULL,
                        captured_us INTEGER NOT NULL, tick TEXT NOT NULL, value TEXT NOT NULL,
                        PRIMARY KEY(stream_id,seq));
                    CREATE INDEX IF NOT EXISTS capture_time ON samples(session_id,captured_us,stream_id,seq);
                    CREATE TABLE IF NOT EXISTS links(id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES captures(id), payload TEXT NOT NULL);
                    PRAGMA user_version=1;
                ''')
                with db:
                    yield db
            finally:
                db.close()

    def reserve(self, capture_id):
        identifier(capture_id)
        folder = self.root/'incoming'/'training'/capture_id
        for part in [self.root/'incoming', self.root/'incoming'/'training', folder]:
            require(not part.is_symlink(), 'Symlink inbox')
            part.mkdir(mode=0o700, exist_ok=True)
        for kind in (*KINDS, 'video', 'reports'):
            target = folder/kind
            require(not target.is_symlink(), 'Symlink inbox')
            target.mkdir(mode=0o700, exist_ok=True)
        draft = dict(schema='fox.training.capture.draft.v1', id=capture_id, activity_id=None,
                     start_us=None, end_us=None, data_class='recorded')
        destination = folder/'capture-draft.json'
        require(not destination.is_symlink(), 'Symlink draft')
        try:
            with destination.open('x') as out: out.write(encoded(draft)+'\n')
        except FileExistsError:
            require(destination.is_file(), 'Invalid draft location')
        return dict(directory=str(folder), draft=str(destination), accepted=False,
                    retention='manual_only', kinds=list(KINDS))

    def create(self, session):
        validate_session(session)
        payload = encoded(session)
        with self.connection() as db:
            old = db.execute('SELECT payload FROM captures WHERE id=?', (session['id'],)).fetchone()
            if old: require(old[0] == payload, 'Capture ID conflict; originals preserved')
            else: db.execute('INSERT INTO captures VALUES(?,?)', (session['id'], payload))
        return dict(id=session['id'], status='already_present' if old else 'stored')

    def sessions(self, after='', limit=100):
        if after: identifier(after)
        integer(limit, 1, 100)
        with self.connection() as db:
            return [json.loads(r[0]) for r in db.execute('SELECT payload FROM captures WHERE id>? ORDER BY id LIMIT ?', (after, limit))]

    def describe(self, capture_id):
        identifier(capture_id)
        with self.connection() as db:
            row = db.execute('SELECT payload FROM captures WHERE id=?', (capture_id,)).fetchone()
            require(row, 'Capture not found')
            streams = [dict(descriptor=json.loads(p), receipt=json.loads(r), received_us=t) for p, r, t in db.execute('SELECT payload,receipt,received_us FROM streams WHERE session_id=? ORDER BY id', (capture_id,))]
            links = [json.loads(r[0]) for r in db.execute('SELECT payload FROM links WHERE session_id=? ORDER BY id', (capture_id,))]
        return dict(session=json.loads(row[0]), streams=streams, links=links)

    def checked_asset(self, archive_id):
        items = self.archive.query(dict(id=archive_id))
        require(len(items) == 1, 'Missing archive asset')
        self.archive.checked_blob(items[0])
        return items[0]

    def link(self, value):
        fields(value, 'id session_id archive_id role offset_us')
        for key in ('id', 'session_id', 'archive_id'): identifier(value[key])
        require(value['role'] in ('video', 'report', 'reference', 'calibration'), 'Invalid evidence role')
        if value['offset_us'] is not None: integer(value['offset_us'], -SAFE_INT)
        payload = encoded(value)
        with self.connection() as db:
            require(db.execute('SELECT 1 FROM captures WHERE id=?', (value['session_id'],)).fetchone(), 'Capture not found')
            self.checked_asset(value['archive_id'])
            old = db.execute('SELECT payload FROM links WHERE id=?', (value['id'],)).fetchone()
            if old: require(old[0] == payload, 'Link ID conflict')
            else:
                require(db.execute('SELECT count(*) FROM links WHERE session_id=?', (value['session_id'],)).fetchone()[0] < 256, 'Link limit reached')
                db.execute('INSERT INTO links VALUES(?,?,?)', (value['id'], value['session_id'], payload))
        return dict(id=value['id'], status='already_present' if old else 'stored')

    def ingest(self, descriptor, stream):
        validate_stream(descriptor)
        payload = encoded(descriptor)
        with self.connection() as db:
            row = db.execute('SELECT payload FROM captures WHERE id=?', (descriptor['session_id'],)).fetchone()
            require(row, 'Capture not found')
            session = json.loads(row[0])
            old = db.execute('SELECT payload FROM streams WHERE id=?', (descriptor['id'],)).fetchone()
            if old: require(old[0] == payload, 'Stream ID conflict; originals preserved')
            else:
                require(shutil.disk_usage(self.root).free > descriptor['size'] * 4 + 256 * 1024**2, 'Insufficient disk space')
                require(db.execute('SELECT count(*) FROM streams WHERE session_id=?', (session['id'],)).fetchone()[0] < 64, 'Stream limit reached')
                db.execute('INSERT INTO streams VALUES(?,?,?,?,?)', (descriptor['id'], session['id'], payload, '{}', time.time_ns()//1000))
            calibration = descriptor['frame']['calibration_archive_id']
            if calibration is not None: self.checked_asset(calibration)
            stats = dict(accepted=0, outside=0, ambiguous=0, dropped_fields=0, total=0)
            h, size, prev_seq, prev_tick = hashlib.sha256(), 0, -1, -1
            clock = descriptor['clock']
            # No upload time, filename time or inferred phase enters this mapping.
            while True:
                line = stream.readline(65537)
                if not line: break
                size += len(line)
                require(size <= descriptor['size'] and len(line) <= 65536 and line.endswith(b'\n'), 'Interrupted/oversized sample line')
                h.update(line)
                sample = json.loads(line)
                fields(sample, 'seq tick values')
                integer(sample['seq'])
                source_tick = tick(sample['tick'])
                require(sample['seq'] > prev_seq and source_tick >= prev_tick, 'Sequence or clock reset: start a new stream')
                prev_seq, prev_tick = sample['seq'], source_tick
                stats['total'] += 1
                require(stats['total'] <= 1000000, 'Sample count limit reached')
                numerator = (source_tick - tick(clock['origin_tick'])) * 1000000
                delta, remainder = divmod(numerator, clock['ticks_per_second'])
                captured = clock['origin_utc_us'] + delta
                integer(captured)
                uncertainty = clock['uncertainty_us'] + (1 if remainder else 0)
                if captured + uncertainty < session['start_us'] or captured - uncertainty >= session['end_us']:
                    stats['outside'] += 1
                    continue
                if captured - uncertainty < session['start_us'] or captured + uncertainty >= session['end_us']:
                    stats['ambiguous'] += 1
                    continue
                value, dropped = normalized_values(descriptor['kind'], sample['values'])
                stats['dropped_fields'] += dropped
                if descriptor['kind'] == 'depth':
                    asset = self.checked_asset(value['asset_id'])
                    expected = value['width'] * value['height'] * (2 if value['encoding'] == 'uint16_le' else 4)
                    require(asset['size'] == expected, 'Depth frame byte dimensions mismatch')
                if not old:
                    db.execute('INSERT INTO samples VALUES(?,?,?,?,?,?)', (session['id'], descriptor['id'], sample['seq'], captured, sample['tick'], encoded(value)))
                stats['accepted'] += 1
            require(size == descriptor['size'] and h.hexdigest() == descriptor['sha256'], 'Interrupted stream or digest mismatch')
            result = dict(id=descriptor['id'], status='already_present' if old else 'stored', **stats)
            if not old: db.execute('UPDATE streams SET receipt=? WHERE id=?', (encoded(result), descriptor['id']))
        return result

    def timeline(self, capture_id, *, limit=100, after=None):
        identifier(capture_id)
        integer(limit, 1, 100)
        cursor = (-1, '', -1)
        if after is not None:
            fields(after, 'captured_us stream_id seq revision')
            integer(after['captured_us'])
            identifier(after['stream_id'])
            integer(after['seq'])
            cursor = (after['captured_us'], after['stream_id'], after['seq'])
        with self.connection() as db:
            require(db.execute('SELECT 1 FROM captures WHERE id=?', (capture_id,)).fetchone(), 'Capture not found')
            revision = hashlib.sha256(encoded([r[0] for r in db.execute('SELECT payload FROM streams WHERE session_id=? ORDER BY id', (capture_id,))]).encode()).hexdigest()
            if after is not None:
                require(after['revision'] == revision, 'Capture streams changed; restart pagination')
            rows = db.execute('''SELECT s.captured_us,s.stream_id,s.seq,s.tick,s.value,t.received_us FROM samples s
                JOIN streams t ON t.id=s.stream_id WHERE s.session_id=? AND (s.captured_us,s.stream_id,s.seq)>(?,?,?)
                ORDER BY s.captured_us,s.stream_id,s.seq LIMIT ?''', (capture_id, *cursor, limit+1)).fetchall()
        samples = [dict(captured_us=t, stream_id=i, seq=n, tick=k, values=json.loads(v), received_us=r) for t, i, n, k, v, r in rows[:limit]]
        next_cursor = dict(**{k:samples[-1][k] for k in ('captured_us', 'stream_id', 'seq')}, revision=revision) if len(rows)>limit else None
        return dict(session_id=capture_id, samples=samples, next=next_cursor, revision=revision)


def serve(root):
    os.umask(0o077)
    line = sys.stdin.buffer.readline(65537)
    require(len(line) <= 65536 and line.endswith(b'\n'), 'Invalid request header')
    request = json.loads(line)
    store = TrainingStore(root)
    action = request.get('action')
    if action == 'reserve': result = store.reserve(request['id'])
    elif action == 'create': result = store.create(request['session'])
    elif action == 'ingest': result = store.ingest(request['descriptor'], sys.stdin.buffer)
    elif action == 'list': result = store.sessions(request.get('after', ''), request.get('limit', 100))
    elif action == 'describe': result = store.describe(request['id'])
    elif action == 'timeline': result = store.timeline(request['id'], limit=request.get('limit', 100), after=request.get('after'))
    elif action == 'link': result = store.link(request['link'])
    else: raise ValueError('Unknown training action')
    print(encoded(result))


def synthetic_session(capture_id):
    return dict(schema='fox.training.capture.v1', id=capture_id, activity_id='synthetic-only',
                start_us=1700000001000000, end_us=1700000003000000, data_class='synthetic')


def synthetic_stream(session, kind, ticks=(0, 1000, 2000, 3000)):
    values = {
        'controller_6dof': dict(tracking='tracked', position_m=[0, 1, 0], orientation_xyzw=[0, 0, 0, 1], buttons={'A': False, 'trigger': 0.5}),
        'resistance': dict(force_n=12.0, position_m=0.2),
        'depth': dict(asset_id='depth-frame', width=2, height=2, encoding='uint16_le', meters_per_unit=0.001, intrinsics=dict(fx=1, fy=1, cx=1, cy=1)),
    }[kind]
    data = b''.join((encoded(dict(seq=i, tick=str(t), values=values))+'\n').encode() for i, t in enumerate(ticks))
    descriptor = dict(schema='fox.training.stream.v1', id=session['id']+'-'+kind, session_id=session['id'], kind=kind,
        source='synthetic-v1', size=len(data), sha256=hashlib.sha256(data).hexdigest(),
        clock=dict(id='synthetic-clock', origin_tick='0', origin_utc_us=1700000000000000, ticks_per_second=1000, uncertainty_us=0, method='synthetic exact clock'),
        frame=dict(id='synthetic-frame', axes='x right, y up, z forward', handedness='left', measurement_point='synthetic reference', calibration_archive_id=None))
    return descriptor, data


def smoke(config, archive_config, capture_id):
    """Retained synthetic evidence only; never uses a device or existing capture."""
    identifier(capture_id)
    require(capture_id.startswith('synthetic-') and len(capture_id) <= 80, 'Smoke requires a short synthetic- ID')
    before = remote(archive_config, dict(action='list'))
    session = synthetic_session(capture_id)
    remote(config, dict(action='create', session=session))
    frame = b'\x01\x00' * 4
    asset = dict(schema='fox.archive.item.v1', id=capture_id+'-depth-frame', record_id=capture_id,
        kind='reference', role='synthetic-depth-frame', source='synthetic-v1', tags=['synthetic'], note='Not recorded sensor data',
        sha256=hashlib.sha256(frame).hexdigest(), size=len(frame), filename='synthetic-depth.bin', occurred_at=None, derived_from=[])
    remote(archive_config, dict(action='put', item=asset), source=io.BytesIO(frame))
    receipts = []
    for kind in KINDS:
        descriptor, data = synthetic_stream(session, kind)
        if kind == 'depth':
            rows = [json.loads(line) for line in data.splitlines()]
            for row in rows: row['values']['asset_id'] = asset['id']
            data = b''.join((encoded(row)+'\n').encode() for row in rows)
            descriptor.update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
        request = dict(action='ingest', descriptor=descriptor)
        result = remote(config, request, source=io.BytesIO(data))
        require(result['accepted'] == 2 and result['outside'] == 2 and result['ambiguous'] == 0, 'Synthetic time filtering mismatch')
        retry = remote(config, request, source=io.BytesIO(data))
        require(retry['status'] == 'already_present', 'Idempotency failed')
        receipts.append(result)
    remote(config, dict(action='link', link=dict(id=capture_id+'-reference', session_id=capture_id, archive_id=asset['id'], role='reference', offset_us=None)))
    description = remote(config, dict(action='describe', id=capture_id))
    timeline = remote(config, dict(action='timeline', id=capture_id))
    require(len(description['streams']) == 3 and len(description['links']) == 1 and len(timeline['samples']) == 6, 'Synthetic relation mismatch')
    require(all(session['start_us'] <= r['captured_us'] < session['end_us'] and r['received_us'] > session['end_us'] for r in timeline['samples']), 'Event time confused with arrival time')
    with tempfile.TemporaryFile() as output:
        remote(archive_config, dict(action='get', id=asset['id']), output=output)
        output.seek(0)
        require(output.read() == frame, 'Archive readback mismatch')
    after = {item['id']:item for item in remote(archive_config, dict(action='list'))}
    require(all(after.get(item['id']) == item for item in before), 'Existing archive metadata changed')
    return dict(schema='fox.training_storage_smoke.v1', status='synthetic_storage_passed', capture_id=capture_id,
        streams=receipts, accepted_samples=6, asset_readback_verified=True, prior_archive_items_preserved=len(before),
        real_format_verified=False, device_accessed=False, originals_deleted=False, timeline=timeline)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == 'serve':
        serve(sys.argv[2])
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=Path.home()/'.config/fox/training-store.json')
    sub = parser.add_subparsers(dest='action', required=True)
    for action in ('reserve', 'describe', 'timeline'):
        p = sub.add_parser(action)
        p.add_argument('id')
        if action == 'timeline':
            p.add_argument('--limit', type=int, default=100)
            p.add_argument('--after', help='JSON next cursor from the previous page')
    p = sub.add_parser('list')
    p.add_argument('--after', default='')
    p.add_argument('--limit', type=int, default=100)
    for action in ('create', 'link'):
        sub.add_parser(action).add_argument('file', type=Path)
    p = sub.add_parser('ingest')
    p.add_argument('descriptor', type=Path)
    p.add_argument('file', type=Path)
    p = sub.add_parser('example')
    p.add_argument('directory', type=Path)
    p = sub.add_parser('smoke')
    p.add_argument('id')
    p.add_argument('--archive-config', type=Path, default=Path.home()/'.config/fox/archive.json')
    args = parser.parse_args()
    if args.action == 'example':
        args.directory.mkdir(mode=0o700, parents=True, exist_ok=False)
        session = synthetic_session('synthetic-example')
        (args.directory/'capture.json').write_text(encoded(session)+'\n')
        for kind in KINDS:
            descriptor, data = synthetic_stream(session, kind)
            (args.directory/f'{kind}.json').write_text(encoded(descriptor)+'\n')
            (args.directory/f'{kind}.ndjson').write_bytes(data)
        print(encoded(dict(directory=str(args.directory), data_class='synthetic', depth_note='Archive a 2x2 uint16_le synthetic frame as depth-frame before depth import')))
        return
    config = json.loads(args.config.read_text())
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', config['host']), 'Invalid SSH alias')
    if args.action == 'smoke':
        archive_config = json.loads(args.archive_config.read_text())
        require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', archive_config['host']), 'Invalid SSH alias')
        require(config['host'] == archive_config['host'] and config['root'] == archive_config['root'], 'Training and archive must share the same library')
        print(encoded(smoke(config, archive_config, args.id)))
        return
    request = dict(action=args.action)
    if args.action in ('reserve', 'describe', 'timeline'): request['id'] = args.id
    if args.action in ('timeline', 'list'):
        request['limit'] = args.limit
        if args.after: request['after'] = json.loads(args.after) if args.action == 'timeline' else args.after
    if args.action in ('create', 'link'): request['session' if args.action == 'create' else 'link'] = json.loads(args.file.read_text())
    if args.action == 'ingest':
        require(args.file.is_file() and not args.file.is_symlink(), 'Expected regular NDJSON source')
        request['descriptor'] = json.loads(args.descriptor.read_text())
        validate_stream(request['descriptor'])
        require(args.file.stat().st_size == request['descriptor']['size'] and digest(args.file) == request['descriptor']['sha256'], 'Local source digest mismatch')
        with args.file.open('rb') as source: result = remote(config, request, source=source)
    else: result = remote(config, request)
    print(encoded(result))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, sqlite3.Error) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
