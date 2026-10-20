"""Internal build versioning inside a larger repository: only this Android project counts."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('internal_build', Path(__file__).with_name('internal_build.py'))
internal_build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(internal_build)


class MonorepoVersionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.repository = Path(self.directory.name).resolve()
        self.android = self.repository / 'clients/apps/android'
        self.android.mkdir(parents=True)
        (self.repository / 'systems').mkdir()
        self.run_git('init', '-q')
        self.write(self.android / 'version.properties', 'versionCode=300\nversionName=0.2.0\n')
        self.write(self.repository / 'systems/server.ex', 'v1\n')
        self.commit('chore: import')
        self.original_root = internal_build.ROOT
        internal_build.ROOT = self.android

    def tearDown(self):
        internal_build.ROOT = self.original_root
        self.directory.cleanup()

    def run_git(self, *args):
        return subprocess.run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.test',
                               '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false', *args],
                              cwd=self.repository, check=True, capture_output=True, text=True).stdout.strip()

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, subject):
        self.run_git('add', '-A')
        self.run_git('commit', '-q', '-m', subject)
        return self.run_git('rev-parse', 'HEAD')

    def test_other_directories_change_neither_the_version_nor_the_changelog(self):
        start = self.run_git('rev-parse', 'HEAD')
        self.run_git('tag', 'android-internal/300', start)
        self.write(self.repository / 'systems/server.ex', 'v2\n')
        self.commit('fix(server): unrelated backend change')
        self.write(self.repository / 'systems/scratch.ex', 'untracked\n')
        head, code, name, dirty = internal_build.version()
        self.assertEqual((code, dirty), (300, False))
        self.assertEqual(name, f'0.2.0-{self.run_git("rev-parse", "--short", "HEAD")}')
        self.assertEqual(internal_build.changelog_subjects(f'android-internal/300..{head}'), '')

        self.write(self.android / 'version.properties', 'versionCode=301\nversionName=0.2.1\n')
        self.write(self.android / 'app/Feature.kt', 'class Feature\n')
        head = self.commit('feat(android): a feature')
        self.write(self.android / 'app/Feature.kt', 'class Feature2\n')
        _, code, name, dirty = internal_build.version()
        self.assertEqual((code, dirty), (301, True))
        self.assertTrue(name.startswith('0.2.1-') and name.endswith('-dirty'))
        previous = internal_build.previous_tag(head, code)
        self.assertEqual(previous, 'android-internal/300')
        self.assertEqual(internal_build.changelog_subjects(f'{previous}..{head}'), 'feat(android): a feature')

    def test_internal_tags_use_their_own_namespace(self):
        head = self.run_git('rev-parse', 'HEAD')
        # Tags from the standalone repository or other products are not Android internal builds.
        self.run_git('tag', 'internal/999', head)
        self.run_git('tag', 'v1.0.5', head)
        self.assertIsNone(internal_build.latest_tag_code())
        self.assertIsNone(internal_build.previous_tag(head, 300))
        self.run_git('tag', 'android-internal/302', head)
        self.assertEqual(internal_build.latest_tag_code(), 302)

    def test_version_file_must_name_a_positive_code_and_a_name(self):
        for text in ('versionCode=0\nversionName=0.2.0\n', 'versionCode=abc\nversionName=0.2.0\n',
                     'versionCode=300\n'):
            self.write(self.android / 'version.properties', text)
            with self.assertRaisesRegex(ValueError, 'version.properties'):
                internal_build.app_version()

    def test_keystore_must_be_outside_the_whole_repository(self):
        for inside in (self.repository / 'keys/internal.keystore', self.android / 'internal.keystore'):
            with self.assertRaisesRegex(ValueError, 'outside the Git repository'):
                internal_build.outside_repository(inside)
        internal_build.outside_repository(self.repository.parent / 'outside/internal.keystore')


if __name__ == '__main__':
    unittest.main()
