"""Silence-based SFX splitting. Planning reads audio; applying creates a new folder."""
import argparse
import copy
import json
from pathlib import Path
import re
import subprocess


def run(args):
    p = subprocess.run(args, capture_output=True, text=True, encoding='utf-8', errors='replace',
                       creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    if p.returncode:
        raise RuntimeError(p.stderr[-1500:])
    return p


def regions(duration, silences, padding=0.02, minimum=0.08):
    clips, cursor = [], 0.0
    for start, end in silences + [(duration, duration)]:
        start, end = max(cursor, start), min(duration, end)
        if start - cursor >= minimum:
            clips.append([max(0, cursor - padding), min(duration, start + padding)])
        cursor = max(cursor, end)
    return clips


def plan(path, noise=-40, silence=.35):
    path = Path(path).resolve()
    stat = path.stat()
    duration = float(run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                          '-of', 'default=noprint_wrappers=1:nokey=1', str(path)]).stdout)
    log = run(['ffmpeg', '-hide_banner', '-nostdin', '-threads', '1', '-i', str(path),
               '-af', f'silencedetect=noise={noise}dB:d={silence}', '-f', 'null', '-']).stderr
    intervals, start = [], None
    for kind, value in re.findall(r'silence_(start|end):\s*([\d.eE+-]+)', log):
        if kind == 'start':
            start = float(value)
        elif start is not None:
            intervals.append((start, float(value)))
            start = None
    if start is not None:
        intervals.append((start, duration))
    return dict(path=str(path), size=stat.st_size, mtime=stat.st_mtime_ns,
                noise=noise, silence=silence, clips=regions(duration, intervals))


def apply(data):
    source = Path(data['path'])
    stat = source.stat()
    if (stat.st_size, stat.st_mtime_ns) != (data['size'], data['mtime']):
        raise RuntimeError('Source changed since preview. Analyze silences again.')
    if not data['clips']:
        raise RuntimeError('No sounds were detected at these settings.')
    sidecar = source.parent / '.ts' / (source.name + '.json')
    metadata = json.loads(sidecar.read_text(encoding='utf-8-sig')) if sidecar.exists() else None
    # A fresh sibling directory on every run; neither originals nor prior exports are overwritten.
    for number in range(1, 10000):
        output = source.parent / f'{source.stem}_split_{number:02d}'
        try:
            output.mkdir()
            break
        except FileExistsError:
            continue
    else:
        raise RuntimeError('Could not choose a fresh export folder.')
    for i, (start, end) in enumerate(data['clips'], 1):
        dest = output / f'{source.stem}_{i:03d}.wav'
        run(['ffmpeg', '-v', 'error', '-nostdin', '-n', '-threads', '1', '-ss', str(start),
             '-i', str(source), '-t', str(end-start), '-vn', '-c:a', 'pcm_s24le', str(dest)])
        if metadata is not None:
            doc = copy.deepcopy(metadata)
            doc['musicTaggerMarkers'] = [dict(c, at=c['at']-start)
                for c in doc.get('musicTaggerMarkers', []) if start <= c['at'] <= end]
            (output / '.ts').mkdir(exist_ok=True)
            (output / '.ts' / (dest.name+'.json')).write_text(json.dumps(doc, ensure_ascii=False), encoding='utf-8')
        print(json.dumps(dict(event='progress', done=i, total=len(data['clips']))), flush=True)
    return output


def main():
    # UTF-8 output, and background priority when the app started this job.
    from mtag import console
    console.init()
    ap = argparse.ArgumentParser()
    ap.add_argument('--path')
    ap.add_argument('--plan', required=True)
    ap.add_argument('--noise', type=float, default=-40)
    ap.add_argument('--silence', type=float, default=.35)
    ap.add_argument('--apply', action='store_true')
    args = ap.parse_args()
    try:
        if args.apply:
            output = apply(json.loads(Path(args.plan).read_text(encoding='utf-8')))
            print(json.dumps(dict(event='done', folder=str(output))), flush=True)
        else:
            data = plan(args.path, args.noise, args.silence)
            Path(args.plan).write_text(json.dumps(data), encoding='utf-8')
            print(json.dumps(dict(event='plan', count=len(data['clips']))), flush=True)
        return 0
    except Exception as e:
        print(json.dumps(dict(event='error', message=str(e))), flush=True)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
