import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]/'scripts'))
from stage_release_source import allowed, stage


class SourceStageTests(unittest.TestCase):
    def test_allowlist_excludes_history_config_and_private_fixtures(self):
        for name in ('Sources/App.swift', 'Assets/names.json', 'worker/recognize.py', 'Package.swift'):
            self.assertTrue(allowed(name))
        for name in ('.git/config', '.private/log.txt', 'AGENTS.md', 'packaging/Info.plist',
                     'worker/tests/fixtures/portraits/sample.png', 'Sources/../secret', '/Sources/App.swift',
                     'scripts/build_app.sh', 'README.md'):
            self.assertFalse(allowed(name))

    def test_export_does_not_import_history_or_apply_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root/'source', root/'staged'
            source.mkdir()
            def git(*args):
                return subprocess.run(['git', '-C', str(source), *args], check=True, capture_output=True)
            git('init')
            (source/'Sources').mkdir()
            (source/'Sources/App.swift').write_text('import Foundation\n')
            (source/'AGENTS.md').write_text('private instructions')
            git('add', '.')
            git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'fixture')
            self.assertEqual(stage(source, output)['files'], 1)
            self.assertTrue((output/'Sources/App.swift').is_file())
            self.assertFalse((output/'.git').exists())
            self.assertFalse((output/'AGENTS.md').exists())
            with self.assertRaises(ValueError):
                stage(source, output)
            (source/'Sources/App.swift').write_text('changed')
            with self.assertRaises(ValueError):
                stage(source, root/'dirty')
            self.assertFalse((root/'dirty').exists())
            (source/'Sources/App.swift').write_text('ghp_' + 'x'*30)
            git('add', '.')
            git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'bad fixture')
            with self.assertRaises(ValueError):
                stage(source, root/'private')
            self.assertFalse((root/'private').exists())


if __name__ == '__main__':
    unittest.main()
