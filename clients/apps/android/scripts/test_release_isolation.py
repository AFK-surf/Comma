"""Regression controls for obfuscated, merged and inlined isolation violations."""
import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('isolation', Path(__file__).with_name('verify-release-isolation.py'))
isolation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(isolation)


class MappingTests(unittest.TestCase):
    def mapping(self, body):
        return isolation.Mapping('# pg_map_id: abc123\n' + body)

    def test_obfuscated_leaks_and_merged_classes_keep_all_origins(self):
        mapping = self.mapping('surf.comma.android.fixture.Leak -> a:\n'
                               'surf.comma.android.tasks.demo.Leak -> a:\n'
                               'surf.comma.android.settings.NetworkLogPage -> b:\n')
        names = mapping.original_descriptors({'La;', 'Lb;'})
        for name in ('fixture/Leak;', 'tasks/demo/Leak;', 'settings/NetworkLogPage;'):
            self.assertIn(isolation.PREFIX + name, names)

    def test_inlined_and_moved_code_cannot_hide_a_leak(self):
        mapping = self.mapping('surf.comma.android.MainActivity -> a:\n'
                               '    1:2:void surf.comma.android.fixture.Leak.run():3:4 -> a\n'
                               '    void surf.comma.android.media.demo.Leak.run() -> b\n')
        names = mapping.original_descriptors({'La;'})
        self.assertIn(isolation.PREFIX + 'fixture/Leak;', names)
        self.assertIn(isolation.PREFIX + 'media/demo/Leak;', names)

    def test_only_code_in_dex_is_a_positive_control(self):
        mapping = self.mapping('surf.comma.android.tasks.TaskRepository -> a:\n')
        self.assertNotIn(isolation.PREFIX + 'tasks/TaskRepository;', mapping.original_descriptors({'Lb;'}))

    def test_missing_empty_and_wrong_mapping_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'mapping.txt'
            with self.assertRaisesRegex(AssertionError, 'missing'):
                isolation.load_mapping(path, [])
            path.write_text('')
            with self.assertRaisesRegex(AssertionError, 'mapping hash'):
                isolation.load_mapping(path, [])
            body = 'surf.comma.android.MainActivity -> a:\n'
            digest = hashlib.sha256(body.encode()).hexdigest()
            content = f'# pg_map_id: {digest}\n# pg_map_hash: SHA-256 {digest}\n' + body
            path.write_text(content)
            def dex(id=digest, mode='full'):
                return b'~~R8' + json.dumps({'pg-map-id': id, 'r8-mode': mode,
                                            'compilation-mode': 'release'}).encode()
            for data in (b'no R8 marker', dex(id='wrong')):
                with self.assertRaisesRegex(AssertionError, 'does not match'):
                    isolation.load_mapping(path, [data])
            with self.assertRaisesRegex(AssertionError, 'full mode'):
                isolation.load_mapping(path, [dex(mode='compatibility')])
            self.assertEqual(isolation.load_mapping(path, [dex()]).id, digest)
            path.write_text(content.replace('MainActivity', 'OtherActivity'))
            with self.assertRaisesRegex(AssertionError, 'incomplete or modified'):
                isolation.load_mapping(path, [dex()])

    def test_build_config_fields_are_resolved_after_renaming(self):
        mapping = self.mapping('surf.comma.android.BuildConfig -> c:\n'
                               '    java.lang.String DOUBAO_ASR_API_KEY -> a\n')
        dump = "Class descriptor : 'Lc;'\nname : 'a'\ntype : 'Ljava/lang/String;'\naccess : PUBLIC STATIC FINAL\nvalue : \"\"\n"
        self.assertEqual(isolation.build_config_values(dump, mapping), {'DOUBAO_ASR_API_KEY': ''})


if __name__ == '__main__':
    unittest.main()
