"""Render a completed or partial benchmark without further model calls."""
import json
import sys
from pathlib import Path

run = Path(sys.argv[1])
rows = [json.loads(line) for line in (run / 'rows.jsonl').read_text().splitlines()]
summary = json.loads((run / 'summary.json').read_text()) if (run / 'summary.json').exists() else {}
manifest = json.loads((run / 'manifest.json').read_text())
variants = manifest['variants']
lines = ['# Mail decision benchmark', '', 'Synthetic policy-defined cases. This is not delivery or UI acceptance.', '',
         '| Variant | Trials | Passed | Missed reminders | False quiet | False notify | Errors | Fact gaps | Jev calls | Router calls |',
         '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|']
for variant, data in summary.items():
    usage = data['usage']
    lines.append(f"| {variant} | {data['total']} | {data['passed']} | {data['missed_reminders']} | {data['false_quiet']} | {data['false_notify']} | {data['errors']} | {data['fact_failures']} | {usage.get('jev', {}).get('calls', 0)} | {usage.get('router', {}).get('calls', 0)} |")
lines += ['', 'Costs are unknown without verified tariffs. Repeated calls may use caches. Failed or missing usage is not zero cost.', '',
          '| Round | Case | Expected | ' + ' | '.join(variants) + ' |',
          '|---:|---|---|' + '---|' * len(variants)]
keys = list(dict.fromkeys((row['round'], row['case_id']) for row in rows))
for number, case_id in keys:
    paired = {r['variant']: r for r in rows if r['round'] == number and r['case_id'] == case_id}
    expected = next(iter(paired.values()))['expected']
    cells = []
    for variant in variants:
        r = paired.get(variant)
        if not r:
            cells.append('not run')
        elif r['status'] == 'error':
            cells.append('ERROR: ' + r['error']['code'])
        else:
            cells.append(r['choice'] + (' ✓' if r['score']['passed'] else ' ✗'))
    lines.append(f'| {number} | {case_id} | {expected} | ' + ' | '.join(cells) + ' |')
lines += ['', '## Draft inspection', '', 'Cards below show the shared output. Model prose is untrusted and is quoted as data.']
for row in rows:
    if row['round'] != 1 or not row.get('output') or not row['output'].get('reminder'):
        continue
    card = row['output']['reminder']
    # JSON quoting prevents arbitrary Markdown in model prose from becoming links.
    lines += ['', f"### {row['case_id']} / {row['variant']}", '', '```json', json.dumps(card, ensure_ascii=False, indent=2), '```']
(run / 'report.md').write_text('\n'.join(lines) + '\n')
print(run / 'report.md')
