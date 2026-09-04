from __future__ import annotations

import unittest
from pathlib import Path
from unittest.mock import patch

from src.config import load_config


class ConfigDefaultsTests(unittest.TestCase):
    def test_builtin_workflow_defaults_exist(self) -> None:
        with patch.dict("os.environ", {}, clear=True):
            cfg = load_config()

        self.assertEqual(cfg.workflows_dir, Path(__file__).resolve().parents[1] / "comfyui_api_workflows")
        for workflow in (
            cfg.default_txt2img_workflow,
            cfg.default_img2img_workflow,
            cfg.default_txt2video_workflow,
            cfg.default_img2video_workflow,
        ):
            self.assertTrue((cfg.workflows_dir / workflow).is_file(), workflow)
