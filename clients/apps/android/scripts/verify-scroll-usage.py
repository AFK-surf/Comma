#!/usr/bin/env python3
"""Exercise the real Gradle guard with disposable app/src fixtures; never touches devices."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN = (
    'android.widget.ScrollView',
    'android.widget.HorizontalScrollView',
    'androidx.core.widget.NestedScrollView',
    'androidx.recyclerview.widget.RecyclerView',
)


def gradle(*tasks):
    return subprocess.run([str(ROOT / 'gradlew'), *tasks, '--max-workers=2', '--console=plain'],
                          cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def main():
    expected = []
    with tempfile.TemporaryDirectory(prefix='scroll_usage_probe_', dir=ROOT / 'app/src') as directory:
        probe = Path(directory)

        def fixture(name, body, line):
            path = probe / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
            expected.append(f'{path.relative_to(ROOT / "app").as_posix()}:{line}:')

        for i, name in enumerate(FORBIDDEN):
            package, simple = name.rsplit('.', 1)
            fixture(f'java/Import{i}.kt', f'package probe\nimport {name}\n', 2)
            fixture(f'java/Alias{i}.kt', f'package probe\nimport {name} as Banned\n', 2)
            fixture(f'java/Escaped{i}.kt', f'package probe\nimport {package}.`{simple}`\n', 2)
            fixture(f'java/Qualified{i}.kt', f'package probe\nval view = {name}(context)\n', 2)
            fixture(f'java/Import{i}.java', f'package probe;\nimport {name};\n', 2)
            fixture(f'java/Qualified{i}.java', f'package probe;\nclass Probe {{ {name} view; }}\n', 2)
            fixture(f'java/Wildcard{i}.kt', f'import {package}.*\nval view = {simple}(context)\n', 2)
            fixture(f'java/Wildcard{i}.java', f'import {package}.*;\nclass Probe {{ {simple} view; }}\n', 2)
            fixture(f'res/layout/probe_{i}.xml', f'<?xml version="1.0"?>\n<{name} />\n', 2)
            fixture(f'res/layout-land/probe_{i}.xml', f'<?xml version="1.0"?>\n<view\n class="{name}" />\n', 3)
            fixture(f'java/Multiline{i}.kt', 'package probe\nval v = ' + name.replace('.', ' .\n ') + '(context)\n', 2)
            if package == 'android.widget':
                fixture(f'res/layout/short_{i}.xml', f'<?xml version="1.0"?>\n<{simple} />\n', 2)
                fixture(f'res/layout/short_view_{i}.xml', f'<?xml version="1.0"?>\n<view class="{simple}" />\n', 2)
        fixture('java/ModuleAlias.kt',
                'import androidx.recyclerview.widget.*\n'
                'import surf.comma.android.scroll.widget.RecyclerView as CommaList\n'
                'val view = RecyclerView(context)\n', 3)
        # Lint must actually run the guard, not merely declare it as an unrelated task.
        result = gradle(':app:lintDevDebug')
        assert result.returncode != 0, result.stdout
        assert ':app:checkScrollUsage FAILED' in result.stdout, result.stdout
        for diagnostic in expected:
            assert diagnostic in result.stdout, f'Missing {diagnostic}\n{result.stdout}'
        assert 'use :scroll' in result.stdout, result.stdout
        print(f'PASS: lint rejected all {len(expected)} forbidden fixtures with file and line diagnostics')
    with tempfile.TemporaryDirectory(prefix='scroll_usage_probe_', dir=ROOT / 'app/src') as directory:
        path = Path(directory) / 'Allowed.kt'
        path.write_text('''import surf.comma.android.scroll.widget.RecyclerView
import android.widget.*
// android.widget.ScrollView is forbidden.
/* androidx.recyclerview.widget.RecyclerView is forbidden. */
val view = RecyclerView(context)
val editor = EditText(context)
val url = "https://example.test/"
''')
        (Path(directory) / 'AllowedAlias.kt').write_text('''import androidx.recyclerview.widget.*
import surf.comma.android.scroll.widget.RecyclerView as CommaList
val list = CommaList(context)
val another = surf.comma.android.scroll.widget.RecyclerView(context)
''')
        result = gradle(':app:checkScrollUsage')
        assert result.returncode == 0, result.stdout
        print('PASS: module widgets and aliases, EditText and comments are allowed')
    result = gradle(':app:checkScrollUsage')
    assert result.returncode == 0, result.stdout
    print('PASS: clean source tree after removing all temporary fixtures')


if __name__ == '__main__':
    main()
