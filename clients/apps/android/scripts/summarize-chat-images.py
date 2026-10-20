#!/usr/bin/env python3
"""FrameMetrics totals in ms; cold means cleared Coil caches before drafting, not OS page cache."""
import argparse
import csv
import pathlib
import statistics

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=pathlib.Path)
args = parser.parse_args()
def percentile(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int((len(values) - 1) * p))]
print('case,frames,p50_ms,p95_ms,max_ms,over_8.33,over_16.67,over_33.33,max_layout_ms,max_draw_ms,max_gpu_ms,dropped_reports')
for file in sorted(args.directory.glob('*.csv')):
    if not file.stem.startswith(('cold-', 'warm-')):
        continue
    lines = file.read_text().splitlines()
    metadata = dict(part.split('=') for part in lines[0].removeprefix('# ').split(','))
    rows = [row for row in csv.DictReader(lines[1:]) if int(metadata['start']) <= int(row['vsync']) <= int(metadata['end'])]
    values = [int(row['total']) / 1e6 for row in rows]
    if not values:
        raise ValueError(f'{file}: no measured frames')
    fields = [file.stem, len(values), round(statistics.median(values), 3), round(percentile(values, .95), 3), round(max(values), 3)]
    fields += [sum(t > threshold for t in values) for threshold in (1000 / 120, 1000 / 60, 1000 / 30)]
    fields += [round(max(int(row[key]) for row in rows) / 1e6, 3) for key in ('layout', 'draw', 'gpu')]
    fields += [sum(int(row['dropped']) for row in rows)]
    print(','.join(map(str, fields)))
