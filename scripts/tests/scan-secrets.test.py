"""Offline regression checks; fixtures never contain actual credentials."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

SCANNER = Path(__file__).resolve().parents[1] / 'scan-secrets.sh'


class ScannerTest(unittest.TestCase):
    def test_working_files_script_and_external_denylist(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'scripts'
            scripts.mkdir()
            scanner = scripts / SCANNER.name
            shutil.copyfile(SCANNER, scanner)
            (scripts / 'scan-denylist.example.txt').write_text('SYNTHETIC_BLOCKED_[M]ARKER\n')
            local = scripts / 'scan-denylist.local.txt'
            local.write_text('# private input\nSYNTHETIC_BLOCKED_[M]ARKER\n')
            env = {**os.environ}
            env.pop('SCAN_DENYLIST_FILE', None)

            def run():
                return subprocess.run(['bash', str(scanner)], env=env, capture_output=True)

            self.assertEqual(run().returncode, 0)
            target = root / 'new-file.txt'
            target.write_text('SYNTHETIC_BLOCKED_MARKER\n')
            result = run()
            self.assertEqual(result.returncode, 1)
            self.assertNotIn(b'SYNTHETIC_BLOCKED_MARKER', result.stderr)
            target.unlink()
            with scanner.open('a') as file:
                file.write('\n# SYNTHETIC_BLOCKED_MARKER\n')
            self.assertEqual(run().returncode, 1)
            external = root / 'custom-patterns.txt'
            external.write_text('ANOTHER_SYNTHETIC_MARKER\n')
            env['SCAN_DENYLIST_FILE'] = str(external)
            self.assertEqual(run().returncode, 0)
            external.unlink()
            self.assertEqual(run().returncode, 1)
            env.pop('SCAN_DENYLIST_FILE')
            scanner.write_bytes(SCANNER.read_bytes())
            local.unlink()
            self.assertEqual(run().returncode, 0)


if __name__ == '__main__':
    unittest.main()
