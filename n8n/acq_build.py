#!/usr/bin/env python3
"""Regenerates every ACQ workflow JSON (n8n/acq/*.json). Do not hand-edit the JSON."""
import acq_phase2, acq_phase3, acq_phase4, acq_phase5
from acq_lib import emit
files = {}
for m in (acq_phase2, acq_phase3, acq_phase4, acq_phase5):
    files.update(m.FILES)
emit(files)
