"""Copy an external folder into a self-contained library. Never modify sources."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile


def emit(**data):
    print(json.dumps(data, ensure_ascii=True), flush=True)


def inventory(source):
    files = []
    for parent, dirs, names in os.walk(source, followlinks=False):
        for name in dirs + names:
            path = Path(parent) / name
            if path.is_symlink() or path.is_junction():
                raise ValueError(f'Linked folder/file must be imported separately: {path}')
        for name in sorted(names):
            path = Path(parent) / name
            st = path.stat()
            files.append((str(path.relative_to(source)), st.st_size, st.st_mtime_ns))
    return sorted(files)


def copy_cached_analysis(source, dest, files):
    # Cached model vectors can be copied cheaply, leaving the source cache usable.
    try:
        from mtag.dataset import CACHE_ROOT, _key_parts
        for rel, size, mtime in files:
            if Path(rel).suffix.lower() not in {'.wav', '.mp3', '.flac', '.ogg', '.m4a', '.aac', '.opus'}:
                continue
            old = _key_parts(source / rel, size, mtime / 1e9)
            new = _key_parts(dest / rel, size, mtime / 1e9)
            for folder in CACHE_ROOT.iterdir():
                src, dst = folder / (old+'.npy'), folder / (new+'.npy')
                if src.is_file() and not dst.exists():
                    shutil.copy2(src, dst)
        map_path = Path(__file__).parent / 'model' / 'soundmap.json'
        if map_path.exists():
            doc = json.loads(map_path.read_text(encoding='utf-8'))
            points = doc.get('points', {})
            for rel, _, _ in files:
                old, new = str(source / rel), str(dest / rel)
                if old in points and new not in points:
                    points[new] = points[old]
            tmp = map_path.with_suffix('.import.tmp')
            tmp.write_text(json.dumps(doc, ensure_ascii=False), encoding='utf-8')
            tmp.replace(map_path)
    except (OSError, ValueError, ImportError):
        # Audio and sidecars are authoritative; derived caches can be rebuilt.
        pass


def import_folder(source, library, effects=False, carry_cache=True):
    source, library = Path(source).resolve(), Path(library).resolve()
    if not source.is_dir() or not library.is_dir():
        raise ValueError('Source and library must both be existing folders.')
    if source == library or source.is_relative_to(library):
        return source
    if library.is_relative_to(source):
        raise ValueError('Cannot import a folder containing the library itself.')
    files = inventory(source)
    if not files:
        raise ValueError('The folder contains no files.')
    effects = effects or any(part.casefold() in {'sfx', 'sound effects', 'sound-effects'} for part in source.parts)
    base = library / 'SFX' / 'Unsorted' if effects else library / 'Untagged'
    base.mkdir(parents=True, exist_ok=True)
    # Receipts live with the library and use relative destinations, so sharing
    # the library does not require this machine's absolute destination path.
    receipts = library / '.music-tagger-imports'
    receipts.mkdir(exist_ok=True)
    key = hashlib.sha256(str(source).casefold().encode()).hexdigest()
    receipt = receipts / (key+'.json')
    signature = hashlib.sha256(json.dumps(files).encode()).hexdigest()
    if receipt.exists():
        try:
            previous = json.loads(receipt.read_text())
            dest = (library / previous['destination']).resolve()
            if dest.is_relative_to(library) and previous['signature'] == signature and all(
                (dest / rel).is_file() and (dest / rel).stat().st_size == size
                and (dest / rel).stat().st_mtime_ns == mtime for rel, size, mtime in files):
                return dest
        except (OSError, ValueError, KeyError):
            pass
    staging = Path(tempfile.mkdtemp(prefix='copy-', dir=receipts))
    try:
        for i, (rel, size, mtime) in enumerate(files, 1):
            src, dst = source / rel, staging / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            if (src.stat().st_size, src.stat().st_mtime_ns) != (size, mtime):
                raise ValueError(f'Source changed while copying: {src}')
            emit(event='progress', done=i, total=len(files))
        for number in range(1, 10000):
            dest = base / (source.name if number == 1 else f'{source.name} ({number})')
            if dest.exists():
                continue
            try:
                staging.rename(dest)
                break
            except FileExistsError:
                continue
        else:
            raise ValueError('Could not choose a free destination folder.')
        if carry_cache:
            copy_cached_analysis(source, dest, files)
        tmp = receipt.with_suffix('.tmp')
        tmp.write_text(json.dumps(dict(signature=signature, destination=str(dest.relative_to(library)))), encoding='utf-8')
        tmp.replace(receipt)
        return dest
    finally:
        # This path is generated by mkdtemp and owned exclusively by this job.
        if staging.exists() and staging.resolve().is_relative_to(receipts.resolve()):
            shutil.rmtree(staging)


def main():
    # UTF-8 output, and background priority when the app started this job.
    from mtag import console
    console.init()
    ap = argparse.ArgumentParser()
    ap.add_argument('--source', required=True)
    ap.add_argument('--library', required=True)
    ap.add_argument('--effects', action='store_true')
    args = ap.parse_args()
    try:
        folder = import_folder(args.source, args.library, args.effects)
        emit(event='done', folder=str(folder))
        return 0
    except Exception as e:
        emit(event='error', message=str(e))
        return 1

if __name__ == '__main__':
    raise SystemExit(main())
