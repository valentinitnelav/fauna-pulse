"""Tests for mot_to_cvat.py. Run: python3 -m unittest (in tool/video_eval)."""
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path

import mot_to_cvat


class MotToCvat(unittest.TestCase):
    def test_class_column_from_visits(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "mot").mkdir()
            (d / "mot" / "VID_1.txt").write_text(
                "1,3,10.00,20.00,30.00,40.00,0.9000,-1,-1,-1\n3,7,11.00,21.00,30.00,40.00,0.8000,-1,-1,-1\n"
            )
            (d / "visits.csv").write_text(
                "track_id,clip,start_time,start_s,end_s,duration_s,n_frames,mean_conf,class\n"
                "3,VID_1.mp4,,0,1,1,1,0.9,insect\n7,VID_1.mp4,,0,1,1,1,0.8,bee\n"
            )
            with redirect_stdout(StringIO()):
                mot_to_cvat.main([tmp])
            with zipfile.ZipFile(d / "cvat" / "VID_1.zip") as z:
                self.assertEqual(z.read("gt/labels.txt").decode(), "bee\ninsect\n")
                self.assertEqual(
                    z.read("gt/gt.txt").decode().splitlines(),
                    ["1,3,10.00,20.00,30.00,40.00,1,2,1", "3,7,11.00,21.00,30.00,40.00,1,1,1"],
                )


if __name__ == "__main__":
    unittest.main()
