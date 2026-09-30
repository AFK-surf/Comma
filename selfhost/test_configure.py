"""Configuration safety tests; run with python3 -m unittest discover -s selfhost."""
import json
import os
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("configure.py")


class ConfigureTest(unittest.TestCase):
    def run_configure(self, directory, **environment):
        with patch.dict(os.environ, {"COMMA_CONFIG_DIR": directory, **environment}, clear=True):
            with patch("os.chown"):
                runpy.run_path(str(SCRIPT))

    def test_reconfiguration_preserves_database_and_encryption_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            self.run_configure(directory)
            root = Path(directory)
            original = (root / "secrets.json").read_bytes()
            before = json.loads((root / "config.json").read_text())
            self.run_configure(directory, COMMA_LLM_MODEL="new-model")
            after = json.loads((root / "config.json").read_text())
            self.assertEqual((root / "secrets.json").read_bytes(), original)
            self.assertEqual(before["subscription_proxy"], after["subscription_proxy"])
            self.assertEqual(before["comma"]["database"], after["comma"]["database"])
            self.assertEqual(after["llm"]["default_template"]["model"], "new-model")

    def test_public_instance_requires_https_and_keeps_signup_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(SystemExit, "HTTPS"):
                self.run_configure(directory, COMMA_PUBLIC_URL="http://comma.example.com")
            self.run_configure(directory, COMMA_PUBLIC_URL="https://app.example.com",
                               COMMA_API_URL="https://api.example.com",
                               COMMA_ADMIN_URL="https://admin.example.com",
                               COMMA_SALIX_URL="https://salix.example.com",
                               COMMA_OWNER_EMAIL="owner@example.com", COMMA_SMTP_HOST="smtp.example.com")
            config = json.loads((Path(directory) / "config.json").read_text())
            self.assertFalse(config["comma"]["auth"]["auto_create_users"])
            self.assertEqual(config["comma"]["selfhost"]["owner_email"], "owner@example.com")
            self.assertEqual(config["comma"]["email"]["smtp"]["tls"], "always")

    def test_corrupt_secret_store_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "secrets.json"
            path.write_text("broken")
            with self.assertRaises(json.JSONDecodeError):
                self.run_configure(directory)
            self.assertEqual(path.read_text(), "broken")
