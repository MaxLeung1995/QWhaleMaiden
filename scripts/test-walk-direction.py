#!/usr/bin/env python3
"""Direction checks now run against the full-screen route implementation."""
from pathlib import Path
import runpy
runpy.run_path(str(Path(__file__).with_name('test-fullscreen-walk.py')),run_name='__main__')
