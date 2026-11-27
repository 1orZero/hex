#!/usr/bin/env python3
"""Runs fork/vocabulary.py against a fake hex that answers like Hex 3.5.1.

  python3 fork/test_vocabulary.py
"""

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vocabulary.py")
UNKNOWN = {"version": 4, "status": "error", "code": "unknown-setting", "message": "unknown setting"}


def setting(key, value):
    return {"version": 4, "status": "settings", "settings": [{"key": key, "value": value, "kind": "choice"}]}


class VocabularySettingsTest(unittest.TestCase):
    def run_script(self, command, boost, model="parakeet_v3", vocabulary="bias"):
        """Runs a vocabulary.py command; boost is vocabulary_boost's value, or an (exit code, body) failure."""
        directory = tempfile.TemporaryDirectory(prefix="qa-vocabulary-")
        self.addCleanup(directory.cleanup)
        answers = {
            "vocabulary list": [0, {"entries": [{"term": "qa-Rune", "sounds_like": []}, {"term": "qa-Hex", "sounds_like": []}]}],
            "status": [0, {"model": {"id": model, "name": model}}],
            "model list": [0, {"models": [{"id": model, "name": model, "vocabulary": vocabulary}]}],
            "history --since 30d --limit 10000": [0, {"entries": []}],
            "settings get vocabulary_boost": list(boost) if isinstance(boost, tuple) else [0, setting("vocabulary_boost", boost)],
        }
        calls_path = os.path.join(directory.name, "calls")
        fake = os.path.join(directory.name, "hex")
        with open(fake, "w", encoding="utf-8") as file:
            file.write(textwrap.dedent(f"""\
                #!{sys.executable}
                import json, sys
                answers = json.loads({json.dumps(json.dumps(answers))})
                unknown = json.loads({json.dumps(json.dumps(UNKNOWN))})
                args = [arg for arg in sys.argv[1:] if arg != "--json"]
                with open({json.dumps(calls_path)}, "a") as calls:
                    calls.write(" ".join(args) + "\\n")
                code, body = answers.get(" ".join(args), [1, unknown])
                print(json.dumps(body))
                sys.exit(code)
            """))
        os.chmod(fake, 0o700)
        support = os.path.join(directory.name, "support")
        os.makedirs(support)
        env = {**os.environ, "HEX_FORK_HEX": fake, "HEX_FORK_HOME": os.path.join(directory.name, "fork"), "HEX_APPLICATION_SUPPORT_DIR": support}
        proc = subprocess.run([sys.executable, SCRIPT, command], capture_output=True, text=True, env=env)
        with open(calls_path, encoding="utf-8") as calls:
            return proc, calls.read().splitlines()

    def test_plan_and_apply_read_vocabulary_boost_and_never_the_retired_lab(self):
        for command in ("plan", "apply"):
            proc, calls = self.run_script(command, "normal")
            self.assertEqual(proc.returncode, 0, proc.stderr)
            plan = json.loads(proc.stdout)
            self.assertTrue(plan["biasing"])
            self.assertEqual(plan["vocabulary_boost"], "normal")
            self.assertEqual(plan["front_rule"], {"unit": "terms", "limit": 64})
            self.assertFalse(plan["write"])
            self.assertNotIn("settings get labs.vocabulary_biasing", calls)

    def test_boost_off_leaves_parakeet_reading_no_terms(self):
        proc, _ = self.run_script("plan", "off")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        plan = json.loads(proc.stdout)
        self.assertFalse(plan["biasing"])
        self.assertIsNone(plan["front_rule"])

    def test_a_missing_boost_setting_falls_back_to_normal(self):
        proc, _ = self.run_script("plan", (1, UNKNOWN))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        plan = json.loads(proc.stdout)
        self.assertIsNone(plan["vocabulary_boost"])
        self.assertTrue(plan["biasing"])
        self.assertEqual(plan["front_rule"], {"unit": "terms", "limit": 64})

    def test_other_hex_failures_still_stop(self):
        proc, _ = self.run_script("plan", (1, {"version": 4, "status": "error", "code": "qa-not-running", "message": "Hex isn't running"}))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("hex settings get vocabulary_boost exited 1", proc.stderr)

    def test_prompt_models_ignore_the_boost(self):
        proc, _ = self.run_script("plan", "off", model="qa-qwen3_asr", vocabulary="prompt")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["front_rule"], {"unit": "characters", "limit": 1000})


if __name__ == "__main__":
    unittest.main()
