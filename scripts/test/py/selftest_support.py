"""The in-process runner and its helpers (scripts/test/py/run.py, support.py)."""
import subprocess
import support


class Support(support.Case):
    def test_env_is_scrubbed(self):
        "a test sees no factory variable of the real machine: its homes are inside its temp dir"
        import os
        self.assertTrue(os.environ["FACTORY_HOME"].startswith(self.tmp))
        self.assertTrue(os.environ["SHIPFLOOR_HOME"].startswith(self.tmp))

    def test_double_records_calls(self):
        "a double first on PATH records each call's argv and answers what its script prints"
        calls = self.double("gh", "print('hello')")
        out = subprocess.run(["gh", "api", "user"], capture_output=True, text=True).stdout
        self.assertEqual(out, "hello\n")
        self.assertEqual(calls(), [["api", "user"]])
