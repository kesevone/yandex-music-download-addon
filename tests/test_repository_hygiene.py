"""Keep installed user data and third-party application artifacts out of the repo."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RepositoryHygieneTests(unittest.TestCase):
    def test_source_tree_contains_no_user_data(self):
        sensitive_names = {'downloads.json', 'config.json', 'button-helper.json',
                           'button-helper-stop.json', 'launcher-error.txt'}
        sensitive_suffixes = {'.dpapi', '.mp3', '.flac', '.m4a', '.mp4', '.asar', '.exe', '.log'}
        for directory in ('src', 'installer', 'scripts', 'tests'):
            for file in (ROOT / directory).rglob('*'):
                if not file.is_file() or '__pycache__' in file.parts:
                    continue
                self.assertNotIn(file.name, sensitive_names, str(file.relative_to(ROOT)))
                self.assertNotIn(file.suffix.lower(), sensitive_suffixes, str(file.relative_to(ROOT)))

    def test_sources_have_no_credential_values_or_author_paths(self):
        patterns = [r'y0_[A-Za-z0-9_-]{24,}', r'gh[pousr]_[A-Za-z0-9]{20,}',
                    r'github_pat_[A-Za-z0-9_]{30,}',
                    r'C:[/\\]Users[/\\]user[/\\]Documents[/\\]Codex',
                    r'E:[/\\]Загрузки']
        for directory in ('src', 'installer', 'scripts', 'tests'):
            for file in (ROOT / directory).rglob('*'):
                if not file.is_file() or '__pycache__' in file.parts:
                    continue
                text = file.read_text(encoding='utf-8-sig')
                for pattern in patterns:
                    self.assertIsNone(re.search(pattern, text), str(file.relative_to(ROOT)))


if __name__ == '__main__':
    unittest.main()
