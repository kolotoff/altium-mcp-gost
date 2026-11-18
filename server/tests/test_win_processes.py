"""Tests for the in-process replacement of tasklist."""
import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import win_processes  # noqa: E402


class PidsByNameTest(unittest.TestCase):
    def test_finds_this_process_by_its_executable_name(self):
        name = os.path.basename(win_processes.image_path(os.getpid()))
        self.assertTrue(name)
        self.assertIn(os.getpid(), win_processes.pids_by_name(name))

    def test_name_is_compared_without_case(self):
        name = os.path.basename(win_processes.image_path(os.getpid()))
        self.assertIn(os.getpid(), win_processes.pids_by_name(name.upper()))

    def test_unknown_name_gives_no_pids(self):
        self.assertEqual(win_processes.pids_by_name("no-such-process-7f3a.exe"), [])


class ImagePathTest(unittest.TestCase):
    def test_path_of_this_process(self):
        path = win_processes.image_path(os.getpid())
        self.assertTrue(os.path.isabs(path))
        self.assertTrue(os.path.isfile(path))

    def test_unreadable_process_gives_empty_path(self):
        # PID 0 is the System Idle Process, which cannot be opened
        self.assertEqual(win_processes.image_path(0), "")

    def test_altium_window_owner_requires_the_configured_install(self):
        with patch.object(win_processes, "window_image_path", return_value=r"C:\Old\X2.EXE"):
            self.assertFalse(win_processes.window_belongs_to(1, r"C:\Altium\X2.EXE"))
            self.assertTrue(win_processes.window_belongs_to(1, r"c:\old\x2.exe"))
            self.assertFalse(win_processes.window_belongs_to(1, ""))


if __name__ == "__main__":
    unittest.main()
