"""Private Fox archive: versioned immutable items, local SQLite, SSH transport.

No device access, source deletion, network listener or AI execution. Serve is a
single bounded RPC per process; the existing pinned SSH identity is the trust boundary.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

FIELDS = {'schema', 'id', 'record_id', 'kind', 'role', 'source', 'tags', 'note',
          'sha256', 'size', 'filename', 'occurred_at', 'derived_from'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def identifier(value):
    require(isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', value), 'Invalid identifier')


def header(request):
    value = json.dumps(request, ensure_ascii=False).encode()+b'\n'
    require(len(value) <= 65536, 'Request header exceeds UTF-8 byte limit')
    return value


def validate(item):
    require(isinstance(item, dict) and set(item) == FIELDS, 'Invalid item fields')
    require(item['schema'] == 'fox.archive.item.v1', 'Unsupported schema')
    for key in ('id', 'record_id'):
        identifier(item[key])
    require(item['kind'] in ('original', 'derived', 'evaluation', 'reference'), 'Invalid kind')
    for key in ('role', 'source', 'note', 'filename'):
        require(isinstance(item[key], str) and len(item[key]) <= 8192, 'Invalid text')
    require(item['role'] and item['source'], 'Missing source or role')
    require(item['filename'] not in ('', '.', '..') and '/' not in item['filename'] and '\\' not in item['filename'], 'Invalid filename')
    require(type(item['size']) is int and 0 <= item['size'] <= 100 * 1024**3, 'Invalid size')
    require(isinstance(item['sha256'], str) and re.fullmatch('[0-9a-f]{64}', item['sha256']), 'Invalid digest')
    require(item['occurred_at'] is None or type(item['occurred_at']) is int, 'Invalid occurrence time')
    for key in ('tags', 'derived_from'):
        require(isinstance(item[key], list) and len(item[key]) <= 100, 'Invalid references/tags')
        for value in item[key]:
            identifier(value)
    if item['kind'] == 'derived':
        require(item['derived_from'], 'Derived item requires evidence references')
    header(dict(action='put', item=item))


def consume(item, stream, output=None):
    h = hashlib.sha256()
    remaining = item['size']
    while remaining:
        block = stream.read(min(1024**2, remaining))
        require(block, 'Interrupted upload')
        if output:
            output.write(block)
        h.update(block)
        remaining -= len(block)
    require(not stream.read(1), 'Extra upload bytes')
    require(h.hexdigest() == item['sha256'], 'Digest mismatch')


def digest(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


class Archive:
    def __init__(self, root):
        self.root = Path(root).absolute()
        require(not any(p.is_symlink() for p in [self.root, *self.root.parents]), 'Symlink root')
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        for name in ('originals', 'metadata', 'staging', 'cache'):
            path = self.root / name
            require(not path.is_symlink(), 'Symlink store')
            path.mkdir(mode=0o700, exist_ok=True)

    @contextlib.contextmanager
    def connection(self):
        for name in ('writer.lock', 'catalog.sqlite'):
            require(not (self.root/'metadata'/name).is_symlink(), 'Symlink metadata')
        with open(self.root/'metadata/writer.lock', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            db = sqlite3.connect(self.root/'metadata/catalog.sqlite')
            try:
                require(db.execute('PRAGMA user_version').fetchone()[0] in (0, 1), 'Unknown database version')
                db.execute('PRAGMA synchronous=FULL')
                db.execute('CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY, record_id TEXT NOT NULL, payload TEXT NOT NULL, imported_ms INTEGER NOT NULL)')
                db.execute('CREATE INDEX IF NOT EXISTS records ON items(record_id)')
                db.execute('PRAGMA user_version=1')
                db.commit()
                yield db
            finally:
                db.close()

    def blob(self, item):
        path = self.root/'originals'/item['sha256'][:2]/item['sha256']
        require(not path.parent.is_symlink() and not path.is_symlink(), 'Symlink blob')
        return path

    def checked_blob(self, item):
        path = self.blob(item)
        require(path.is_file() and path.stat().st_size == item['size'] and digest(path) == item['sha256'], 'Missing/corrupt blob')
        return path

    def put(self, item, stream):
        validate(item)
        payload = json.dumps(item, sort_keys=True, ensure_ascii=False)
        with self.connection() as db:
            old = db.execute('SELECT payload FROM items WHERE id=?', (item['id'],)).fetchone()
            if old:
                require(old[0] == payload, 'ID conflict; originals preserved')
                self.checked_blob(item)
        if old:
            consume(item, stream)
            return dict(id=item['id'], status='already_present', verified=True)
        require(shutil.disk_usage(self.root).free > item['size'] + 256 * 1024**2, 'Insufficient disk space')
        # Stage outside the write lock; only verified complete bytes become visible.
        fd, name = tempfile.mkstemp(dir=self.root/'staging')
        try:
            with os.fdopen(fd, 'wb') as out:
                consume(item, stream, out)
                out.flush()
                os.fsync(out.fileno())
            with self.connection() as db:
                old = db.execute('SELECT payload FROM items WHERE id=?', (item['id'],)).fetchone()
                if old:
                    require(old[0] == payload, 'ID conflict; originals preserved')
                    self.checked_blob(item)
                    return dict(id=item['id'], status='already_present', verified=True)
                for ref in item['derived_from']:
                    require(db.execute('SELECT 1 FROM items WHERE id=?', (ref,)).fetchone(), 'Missing evidence reference')
                path = self.blob(item)
                path.parent.mkdir(mode=0o700, exist_ok=True)
                if path.exists():
                    self.checked_blob(item)
                else:
                    os.rename(name, path)
                    sync_dir(path.parent)
                    sync_dir(path.parent.parent)
                db.execute('INSERT INTO items VALUES(?,?,?,?)', (item['id'], item['record_id'], payload, int(time.time()*1000)))
                db.commit()
            return dict(id=item['id'], status='stored', verified=True)
        finally:
            Path(name).unlink(missing_ok=True)

    def query(self, request):
        with self.connection() as db:
            rows = db.execute('SELECT payload, imported_ms FROM items ORDER BY imported_ms,id').fetchall()
        items = [dict(json.loads(payload), imported_at=stamp) for payload, stamp in rows]
        return [item for item in items if
                (not request.get('id') or item['id'] == request['id']) and
                (not request.get('record_id') or item['record_id'] == request['record_id']) and
                (not request.get('tag') or request['tag'] in item['tags'])]


def serve(root):
    os.umask(0o077)
    line = sys.stdin.buffer.readline(65537)
    require(len(line) <= 65536 and line.endswith(b'\n'), 'Invalid request header')
    request = json.loads(line)
    action = request.get('action')
    require(action in ('put', 'list', 'get', 'verify'), 'Unknown action')
    archive = Archive(root)
    if action == 'put':
        result = archive.put(request['item'], sys.stdin.buffer)
    elif action == 'list':
        result = archive.query(request)
    else:
        identifier(request.get('id'))
        items = archive.query(request)
        require(len(items) == 1, 'Item not found')
        path = archive.checked_blob(items[0])
        if action == 'get':
            with path.open('rb') as source:
                shutil.copyfileobj(source, sys.stdout.buffer)
            return
        result = dict(id=request['id'], verified=True, sha256=items[0]['sha256'])
    print(json.dumps(result, ensure_ascii=False))


def remote(config, request, source=None, output=None):
    encoded = header(request)
    timeout = config.get('timeout_seconds', 1800)
    require(isinstance(timeout, (int, float)) and 0 < timeout <= 86400, 'Invalid timeout')
    command = ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
               '-o', 'ConnectTimeout=8', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2',
               config['host'], shlex.join(['python3', config['script'], 'serve', config['root']])]
    # File-backed output avoids retaining media in Mac memory.
    with tempfile.TemporaryFile() as response, tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=output or response, stderr=errors)
        watchdog = threading.Timer(timeout, process.kill)
        watchdog.start()
        try:
            process.stdin.write(encoded)
            if source:
                shutil.copyfileobj(source, process.stdin)
            process.stdin.close()
            status = process.wait()
        except BaseException:
            process.kill()
            process.wait()
            raise
        finally:
            watchdog.cancel()
            watchdog.join()
        errors.seek(0)
        require(status == 0, errors.read().decode(errors='replace'))
        if output is None:
            response.seek(0)
            return json.load(response)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == 'serve':
        serve(sys.argv[2])
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', default=str(Path.home()/'.config/fox/archive.json'))
    sub = parser.add_subparsers(dest='action', required=True)
    put = sub.add_parser('put')
    put.add_argument('file', type=Path)
    for key in ('id', 'record', 'role', 'source'):
        put.add_argument('--'+key, required=True)
    put.add_argument('--kind', default='original')
    put.add_argument('--tag', action='append', default=[])
    put.add_argument('--derived-from', action='append', default=[])
    put.add_argument('--note', default='')
    put.add_argument('--occurred-at', type=int)
    listing = sub.add_parser('list')
    listing.add_argument('--record', dest='record_id')
    listing.add_argument('--tag')
    for name in ('get', 'verify'):
        command = sub.add_parser(name)
        command.add_argument('id')
        if name == 'get':
            command.add_argument('destination', type=Path)
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text())
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', config['host']), 'Invalid SSH alias')
    if args.action == 'put':
        require(args.file.is_file() and not args.file.is_symlink(), 'Expected regular source file')
        item = dict(schema='fox.archive.item.v1', id=args.id, record_id=args.record,
                    kind=args.kind, role=args.role, source=args.source, tags=args.tag, note=args.note,
                    sha256=digest(args.file), size=args.file.stat().st_size, filename=args.file.name,
                    occurred_at=args.occurred_at, derived_from=args.derived_from)
        validate(item)
        with args.file.open('rb') as source:
            result = remote(config, dict(action='put', item=item), source=source)
    elif args.action == 'get':
        require(not args.destination.exists() and not args.destination.is_symlink(), 'Destination exists; not overwritten')
        items = remote(config, dict(action='list', id=args.id))
        require(len(items) == 1, 'Item not found')
        fd, name = tempfile.mkstemp(dir=args.destination.parent)
        try:
            with os.fdopen(fd, 'wb') as out:
                remote(config, dict(action='get', id=args.id), output=out)
                out.flush()
                os.fsync(out.fileno())
            require(Path(name).stat().st_size == items[0]['size'] and digest(name) == items[0]['sha256'], 'Download digest mismatch')
            os.link(name, args.destination)
            sync_dir(args.destination.parent)
            result = dict(id=args.id, verified=True, destination=str(args.destination))
        finally:
            Path(name).unlink(missing_ok=True)
    else:
        request = dict(action=args.action)
        for key in ('id', 'record_id', 'tag'):
            if getattr(args, key, None):
                request[key] = getattr(args, key)
        result = remote(config, request)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
