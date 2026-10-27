"""Task-local adapter: pinned private tests, marked disposable homes only."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_flow import Flow, SOURCE
from test_adaptation import Adaptation

OriginalTemporaryDirectory = tempfile.TemporaryDirectory


def marked_temp(*args, **kwargs):
    temp = OriginalTemporaryDirectory(*args, **kwargs)
    home = Path(temp.name).resolve() / 'home'
    subprocess.run(['/bin/bash', str(SOURCE / 'bin/fm-lab-home.sh'), 'create', str(home)],
                   check=True, capture_output=True)
    return temp


class LabSetup:
    def setUp(self):
        with patch('tempfile.TemporaryDirectory', marked_temp):
            super().setUp()
        # Match the stock-home allowance; never set the test bypass.
        self.env['FM_ROOT_OVERRIDE'] = str(SOURCE)
        for key in ('FM_DATA_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
            self.env.pop(key, None)

    def tearDown(self):
        evidence = Path(os.environ['TEST_EVIDENCE']) / self._testMethodName
        evidence.mkdir(parents=True, exist_ok=True)
        # Persist exact synthetic journal receipts, not private implementation bytes.
        for journal in self.js:
            tables = [row[0] for row in journal.db.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
            receipts = {table: [dict(row) for row in journal.db.execute('SELECT * FROM "' + table + '"')]
                        for table in tables}
            (evidence / (journal.path.stem + '.json')).write_text(json.dumps(receipts, indent=2))
        super().tearDown()


class LabFlow(LabSetup, Flow):
    pass


class LabAdaptation(LabSetup, Adaptation):
    pass


suite = unittest.TestSuite([
    LabFlow('test_complete_simulated_request_parent_route_progress_decision_final_original_thread'),
    LabAdaptation('test_actual_current_spawn_capacity_exit_does_not_consume_permit'),
])
result = unittest.TextTestRunner(verbosity=2).run(suite)
raise SystemExit(not result.wasSuccessful())
