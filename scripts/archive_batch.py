"""Inventory explicit private roots, deduplicate bytes, retain every source association."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import archive


def stable(value):
    return hashlib.sha256(value.encode()).hexdigest()


def no_symlinks(path):
    return not any(p.is_symlink() for p in [path, *path.parents])


def inventory(roots):
    objects, groups, issues = {}, {}, []
    for spec in roots:
        root = Path(spec['path']).absolute()
        if not root.is_dir() or not no_symlinks(root):
            issues.append(dict(path=str(root), reason='missing_or_symlink_root'))
            continue
        files = []
        def walk_error(error):
            issues.append(dict(path=str(error.filename), reason='walk_error', detail=str(error)))
        for directory, dirs, names in os.walk(root, followlinks=False, onerror=walk_error):
            for d in dirs:
                if (Path(directory)/d).is_symlink():
                    issues.append(dict(path=str(Path(directory)/d), reason='symlink_directory_excluded'))
            dirs[:] = sorted(d for d in dirs if not (Path(directory)/d).is_symlink())
            for name in sorted(names):
                path = Path(directory)/name
                if path.is_symlink():
                    issues.append(dict(path=str(path), reason='symlink_excluded'))
                elif path.is_file() and name != '.DS_Store':
                    files.append(path)
        hashes = {str(path): archive.digest(path) for path in files}
        blocked = set()
        for path in files:
            if path.name != 'manifest.json':
                continue
            try:
                manifest = json.loads(path.read_text())
                schema = manifest.get('schema') if isinstance(manifest, dict) else None
                if schema == 'fox.vision_diagnostic_manifest.v1':
                    references = manifest['files']
                elif schema == 'fox.video_corpus.v1':
                    references = [dict(path=manifest['asset'], sha256=manifest['sha256'], bytes=manifest.get('bytes'))]
                else:
                    continue
                for reference in references:
                    target = path.parent/reference['path']
                    valid = (target.resolve().is_relative_to(path.parent.resolve()) and
                             str(target) in hashes and hashes[str(target)] == reference['sha256'] and
                             (reference.get('bytes') is None or target.stat().st_size == reference['bytes']))
                    if not valid:
                        blocked.add(path.parent)
                        issues.append(dict(path=str(path), target=reference['path'], reason='manifest_reference_mismatch_or_missing'))
            except (ValueError, KeyError, TypeError, OSError) as error:
                blocked.add(path.parent)
                issues.append(dict(path=str(path), reason='invalid_manifest', detail=str(error)))
        for path in files:
            if any(path.is_relative_to(parent) for parent in blocked):
                continue
            relative = str(path.relative_to(root))
            group_id = 'group-'+stable(str(root)+'/'+spec['label']+'/'+str(path.relative_to(root).parent))[:24]
            group = groups.setdefault(group_id, dict(id=group_id, label=spec['label'], directory=str(path.parent),
                                                     tags=spec['tags'], files=[]))
            sha = hashes[str(path)]
            item_id = 'object-'+sha
            group['files'].append(dict(filename=path.name, item_id=item_id))
            obj = objects.setdefault(sha, dict(id=item_id, sha256=sha, size=path.stat().st_size, locations=[]))
            obj['locations'].append(dict(path=str(path), group_id=group_id, relative_path=relative, tags=spec['tags']))
    return dict(schema='fox.archive.inventory.v1', roots=roots, objects=list(objects.values()),
                groups=list(groups.values()), issues=issues,
                boundary='Explicit local roots only; duplicates are bytes, not merged events; no live device claim')


def source_for(obj):
    # All copies are evidence: fail rather than silently falling back after drift.
    for location in obj['locations']:
        path = Path(location['path'])
        archive.require(path.is_file() and no_symlinks(path) and path.stat().st_size == obj['size'] and
                        archive.digest(path) == obj['sha256'], 'Source changed: '+str(path))
    return Path(obj['locations'][0]['path'])


def item_for(obj):
    return dict(schema='fox.archive.item.v1', id=obj['id'], record_id='content-objects', kind='original',
                role='source-file', source='batch-inventory', tags=['archive-object'], note='',
                sha256=obj['sha256'], size=obj['size'], filename=obj['sha256'], occurred_at=None, derived_from=[])


def upload(plan_path, receipt_path, config):
    frozen = plan_path.read_bytes()
    plan = json.loads(frozen)
    archive.require(plan['schema'] == 'fox.archive.inventory.v1', 'Unknown inventory')
    receipt_path = receipt_path.absolute()
    archive.require(no_symlinks(receipt_path) and not receipt_path.exists(), 'Receipt requires a fresh non-symlink path')
    protected = [plan_path.absolute()] + [Path(l['path']).absolute() for o in plan['objects'] for l in o['locations']]
    archive.require(receipt_path not in protected, 'Receipt aliases input')
    receipts = []
    existing = {item['id']: item for item in archive.remote(config, dict(action='list'))}
    # Exclusive creation prevents an output race from overwriting any prior file.
    with receipt_path.open('x') as log:
        for index, obj in enumerate(plan['objects']):
            path = source_for(obj)
            item = item_for(obj)
            if item['id'] in existing:
                old = {k: v for k, v in existing[item['id']].items() if k != 'imported_at'}
                archive.require(old == item, 'Remote metadata conflict')
                result = archive.remote(config, dict(action='verify', id=item['id']))
            else:
                with path.open('rb') as stream:
                    result = archive.remote(config, dict(action='put', item=item), source=stream)
                archive.require(archive.digest(path) == obj['sha256'], 'Source changed during upload')
                result['readback'] = archive.remote(config, dict(action='verify', id=item['id']))
            result['item_id'] = item['id']
            log.write(json.dumps(result)+'\n')
            log.flush()
            os.fsync(log.fileno())
            receipts.append(result)
            if index % 20 == 0:
                print(f'verified {index+1}/{len(plan["objects"])}', flush=True)
        # Publish the relationship map only after all accepted objects are verified.
        sha = hashlib.sha256(frozen).hexdigest()
        meta = dict(schema='fox.archive.item.v1', id='inventory-'+sha, record_id='archive-inventories', kind='reference',
                    role='inventory', source='batch-inventory', tags=['vision','journal','inventory'], note='',
                    sha256=sha, size=len(frozen), filename='inventory.json', occurred_at=None, derived_from=[])
        with io.BytesIO(frozen) as stream:
            result = archive.remote(config, dict(action='put', item=meta), source=stream)
        log.write(json.dumps(dict(inventory=result, objects=len(receipts), excluded_issues=plan['issues']))+'\n')
        log.flush()
        os.fsync(log.fileno())
    print(json.dumps(dict(inventory_id=meta['id'], objects=len(receipts), excluded_issues=len(plan['issues']))))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    scan = sub.add_parser('inventory')
    scan.add_argument('roots', type=Path)
    scan.add_argument('output', type=Path)
    put = sub.add_parser('upload')
    put.add_argument('plan', type=Path)
    put.add_argument('receipt', type=Path)
    put.add_argument('--config', type=Path, default=Path.home()/'.config/fox/archive.json')
    show = sub.add_parser('groups')
    show.add_argument('plan', type=Path)
    show.add_argument('--contains', default='')
    args = parser.parse_args()
    if args.action == 'inventory':
        value = inventory(json.loads(args.roots.read_text()))
        with args.output.open('x') as out:
            json.dump(value, out, ensure_ascii=False, indent=2)
        print(json.dumps(dict(objects=len(value['objects']), groups=len(value['groups']),
                             bytes=sum(o['size'] for o in value['objects']), issues=value['issues']),ensure_ascii=False))
    elif args.action == 'upload':
        upload(args.plan, args.receipt, json.loads(args.config.read_text()))
    else:
        value = json.loads(args.plan.read_text())
        print(json.dumps([g for g in value['groups'] if args.contains.lower() in json.dumps(g).lower()],ensure_ascii=False,indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
