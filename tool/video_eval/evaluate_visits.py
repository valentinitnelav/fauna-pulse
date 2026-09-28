#!/usr/bin/env python3
"""Old name of evaluate_track_ids.py (renamed in round 248, when the app's visits.csv became
track_ids.csv). Kept so existing commands keep working; it runs evaluate_track_ids.py with the
same arguments. See that file for what it does."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from evaluate_track_ids import main  # noqa: E402

if __name__ == "__main__":
    main()
