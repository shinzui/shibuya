#!/usr/bin/env python3
"""Compatibility entry point; run the maintained repository script."""
from pathlib import Path
import runpy

runpy.run_path(str(Path(__file__).resolve().parents[5] / 'scripts/audit/run-websocket-mutation-controls.py'), run_name='__main__')
