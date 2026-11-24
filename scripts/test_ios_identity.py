"""Prueba la migración en una copia temporal del proyecto."""

from collections import Counter
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest


REPO = Path(__file__).resolve().parents[1]
SCRIPT = Path(__file__).with_name("ios_identity.py").resolve()
CONFIG = Path("ios/Flutter/Identity.xcconfig")
WIDGET_SERVICE = Path("lib/services/home_widget_service.dart")
EXPECTED_COUNTS = {
    "APP_BUNDLE_ID": 18,
    "WIDGET_BUNDLE_ID": 9,
    "TESTS_BUNDLE_ID": 9,
    "DEVELOPMENT_TEAM_ID": 27,
    "APP_GROUP_ID": 9,
    "ASSOCIATED_DOMAIN": 3,
    "MERCHANT_ID": 2,
    "KEYCHAIN_GROUP": 2,
}


def reported_occurrences(output):
    for row in output.splitlines():
        location, role, value = row.split()
        path, line = location.rsplit(":", 1)
        yield Path(path), int(line), role, value


class IOSIdentityTest(unittest.TestCase):
    def setUp(self):
        temporary = TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        shutil.copytree(REPO / "ios", self.root / "ios")
        service = self.root / WIDGET_SERVICE
        service.parent.mkdir(parents=True)
        shutil.copy2(REPO / WIDGET_SERVICE, service)

    def run_identity(self, *args, status=0):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root), *args],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, status, result.stderr or result.stdout)
        self.assertEqual(result.stderr, "")
        return result.stdout

    def snapshot(self):
        paths = [*self.root.joinpath("ios").rglob("*"), self.root / WIDGET_SERVICE]
        return {path.relative_to(self.root): path.read_bytes() for path in paths if path.is_file()}

    def test_check_accepts_current_identity(self):
        output = self.run_identity("--check")
        counts = Counter(role for _, _, role, _ in reported_occurrences(output))
        self.assertEqual(counts, EXPECTED_COUNTS)
        self.assertEqual(self.run_identity(), output)

    def test_apply_updates_each_value_and_preserves_other_text(self):
        # Los sufijos cambian para probar la revisión después de migrar.
        fake = {
            "APP_BUNDLE_ID": "org.example.app",
            "WIDGET_BUNDLE_ID": "org.example.app.companion",
            "TESTS_BUNDLE_ID": "org.example.app.qa",
            "DEVELOPMENT_TEAM_ID": "TEAMID0000",
            "APP_GROUP_ID": "group.org.example.app",
            "ASSOCIATED_DOMAIN": "example.invalid",
            "MERCHANT_ID": "merchant.org.example.app",
        }
        initial_report = self.run_identity("--check")
        config = self.root / CONFIG
        config.write_text("".join(f"{key} = {value}\n" for key, value in fake.items()), encoding="utf-8")
        original = self.snapshot()
        self.assertEqual(self.run_identity("--check", status=1), initial_report)
        self.assertEqual(self.snapshot(), original)

        fake["KEYCHAIN_GROUP"] = "$(AppIdentifierPrefix)" + fake["APP_BUNDLE_ID"]
        fake["ASSOCIATED_DOMAIN"] = "applinks:" + fake["ASSOCIATED_DOMAIN"]
        changed_files = {}
        expected_report = []
        for path, line, role, current in reported_occurrences(initial_report):
            if path not in changed_files:
                changed_files[path] = original[path].splitlines(keepends=True)
            lines = changed_files[path]
            self.assertEqual(lines[line - 1].count(current.encode()), 1)
            lines[line - 1] = lines[line - 1].replace(current.encode(), fake[role].encode())
            expected_report.append(f"{path}:{line} {role} {fake[role]}")

        summary = self.run_identity("--apply")
        self.assertIn(f"Apariciones actualizadas: {sum(EXPECTED_COUNTS.values())}.", summary)
        self.assertEqual(self.run_identity("--check").splitlines(), expected_report)
        expected = original | {path: b"".join(lines) for path, lines in changed_files.items()}
        self.assertEqual(self.snapshot(), expected)
        self.assertIn("Archivos modificados: 0.", self.run_identity("--apply"))
        self.assertEqual(self.snapshot(), expected)


if __name__ == "__main__":
    unittest.main()
