"""Tests for evaluate_visits.py. Run: python3 -m unittest (in tool/video_eval)."""
import csv
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path

import evaluate_visits as ev

VISITS_HEADER = "track_id,clip,start_time,start_s,end_s,duration_s,n_frames,mean_conf,class\n"


def session_folder(tmp, visits_rows, name="visits.csv"):
    """A 'Share results' folder: two clips, one imported as 'VID 1.mp4'."""
    d = Path(tmp)
    (d / "session.jsonl").write_text(
        "\n".join(
            json.dumps(r)
            for r in [
                {"type": "start_of_session", "source": "imported_video"},
                {"type": "video_clip", "file": "videos/VID_1.mp4", "original_name": "VID 1.mp4", "duration_ms": 60000},
                {"type": "video_clip", "file": "videos/VID_2.mp4", "original_name": "VID_2.mp4", "duration_ms": 30000},
            ]
        )
        + "\n"
    )
    (d / "post_tracks.jsonl").write_text(
        json.dumps(
            {
                "type": "post_track_start",
                "clips": ["VID_1.mp4", "VID_2.mp4"],
                "clips_left_out": [],
                "tracker": {"algorithm": "bytetrack"},
                "detection_settings": {"analysis_fps": 15},
            }
        )
        + "\n"
    )
    path = d / name
    path.write_text(VISITS_HEADER + "".join(f"{r}\n" for r in visits_rows))
    return path


def write(tmp, name, text):
    path = Path(tmp) / name
    path.write_text(text)
    return str(path)


class ParseTime(unittest.TestCase):
    def test_formats(self):
        self.assertEqual(ev.parse_time("83.5"), 83.5)
        self.assertEqual(ev.parse_time("1:23.5"), 83.5)
        self.assertEqual(ev.parse_time("0:01:23.5"), 83.5)
        self.assertEqual(ev.parse_time("1,5", decimal_comma=True), 1.5)
        self.assertIsNone(ev.parse_time("NA"))
        self.assertIsNone(ev.parse_time(" "))


class MatchClip(unittest.TestCase):
    def t(self, *spans):
        return [(a, b, "", "") for a, b in spans]

    def test_found_missed_extra(self):
        pairs, split, merged = ev.match_clip(self.t((0, 5), (20, 25)), self.t((1, 4), (40, 41)), 0.5)
        self.assertEqual([(ti, ai) for ti, ai, _ in pairs], [(0, 0)])
        self.assertEqual(pairs[0][2], 3)
        self.assertEqual((split, merged), (0, 0))

    def test_split_and_merged(self):
        # One insect lost halfway (split), two close visitors counted as one (merged).
        _, split, merged = ev.match_clip(self.t((0, 10), (20, 22), (23, 25)), self.t((0, 4), (6, 10), (20, 25)), 0.5)
        self.assertEqual((split, merged), (1, 1))

    def test_longest_overlap_wins(self):
        pairs, _, _ = ev.match_clip(self.t((0, 10)), self.t((0, 2), (3, 10)), 0.5)
        self.assertEqual([(ti, ai) for ti, ai, _ in pairs], [(0, 1)])

    def test_point_event_needs_tolerance(self):
        self.assertEqual(len(ev.match_clip(self.t((10, 10)), self.t((10.3, 12)), 0.5)[0]), 1)
        self.assertEqual(len(ev.match_clip(self.t((10, 10)), self.t((10.3, 12)), 0)[0]), 0)


class Evaluate(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def run_main(self, *args):
        out = StringIO()
        with redirect_stdout(out):
            ev.main([str(a) for a in args])
        return out.getvalue()

    def test_plain_csv_with_names_from_before_the_import(self):
        app = session_folder(
            self.tmp,
            [
                '1,VID_1.mp4,2026-07-01 10:15:02,2.0,6.0,4.0,60,0.8,"bee"',
                "2,VID_1.mp4,,30.0,31.0,1.0,15,0.6,bee",
                "3,VID_2.mp4,,5.0,8.0,3.0,45,0.7,bee",
            ],
        )
        truth = write(
            self.tmp,
            "truth.csv",
            "clip,start_s,end_s,taxon\nVID 1.mp4,0:01.5,0:07,Apis\nVID 1.mp4,50,52,Bombus\nvid_2,,,\n",
        )
        scores_csv = Path(self.tmp) / "scores.csv"
        pairs_csv = Path(self.tmp) / "pairs.csv"
        printed = self.run_main("--truth", truth, "--app", app, "--out", scores_csv, "--pairs", pairs_csv)
        self.assertIn("found 1 (recall 0.500), missed 1, extra 2", printed)

        rows = {r["clip"]: r for r in csv.DictReader(scores_csv.open())}
        self.assertEqual(set(rows), {"VID_1.mp4", "VID_2.mp4", "ALL"})
        a = rows["ALL"]
        self.assertEqual((a["run"], a["tracker"], a["fps"]), ("visits", "bytetrack", "15"))
        self.assertEqual((a["n_true"], a["n_app"], a["found"], a["count_error"]), ("2", "3", "1", "1"))
        self.assertEqual(a["clip_s"], "90.000")
        self.assertEqual(a["mean_duration_error_s"], "-1.500")  # 4 s found vs 5.5 s counted
        self.assertEqual(a["median_start_error_s"], "0.500")
        # The watched clip without visits is scored: its app visit is extra.
        self.assertEqual((rows["VID_2.mp4"]["n_true"], rows["VID_2.mp4"]["extra"]), ("0", "1"))
        self.assertEqual(rows["VID_2.mp4"]["recall"], "NA")

        statuses = sorted(r["status"] for r in csv.DictReader(pairs_csv.open()))
        self.assertEqual(statuses, ["extra", "extra", "found", "missed"])

    def test_sweep_file_names_fill_tracker_and_fps(self):
        sweep = Path(self.tmp) / "fps_sweep"
        sweep.mkdir()
        session_folder(self.tmp, [])
        app = sweep / "visits_cbiou_2.5fps.csv"
        app.write_text(VISITS_HEADER + "1,VID_1.mp4,,2,6,4,10,0.8,bee\n")
        run = ev.Run(app)
        self.assertEqual((run.tracker, run.fps), ("cbiou", "2.5"))
        self.assertEqual(run.length_s["VID_1.mp4"], 60)  # session.jsonl one folder up

    def test_boris_export(self):
        app = session_folder(self.tmp, ["1,VID_1.mp4,,10,14,4,60,0.8,bee"])
        head = "Observation id\tSubject\tBehavior\tBehavior type\tStart (s)\tStop (s)\tMedia file name\n"
        truth = write(
            self.tmp,
            "boris.tsv",
            head
            + "obs1\tNo focal subject\tvisit\tSTATE\t9.5\t14.2\t/home/me/VID 1.mp4\n"
            + "obs1\tBombus\tvisit\tPOINT\t40\tNA\t/home/me/VID 1.mp4\n"
            + "obs1\tBombus\tgrooming\tSTATE\t41\t45\t/home/me/VID 1.mp4\n",
        )
        truth_visits, _ = ev.read_truth([truth], {"visit"})
        self.assertEqual([(v[1], v[2], v[3]) for v in truth_visits], [(9.5, 14.2, "visit"), (40, 40, "Bombus")])
        self.assertIn("found 1 (recall 0.500), missed 1, extra 0", self.run_main("--truth", truth, "--app", app, "--behavior", "visit"))

    def test_boris_observation_with_several_videos_is_refused(self):
        truth = write(
            self.tmp,
            "boris.csv",
            "Observation id,Behavior,Start (s),Stop (s),Media file name\nobs1,visit,1,2,a.mp4\nobs1,visit,70,72,b.mp4\n",
        )
        with self.assertRaisesRegex(ev.InputError, "one observation per video"):
            ev.read_truth([truth], set())

    def test_boris_time_offset_is_refused(self):
        truth = write(self.tmp, "boris.csv", "Observation id,Time offset (s),Start (s),Stop (s),Media file name\nobs1,5,1,2,a.mp4\n")
        with self.assertRaisesRegex(ev.InputError, "time offset"):
            ev.read_truth([truth], set())

    def test_unknown_clip_is_refused(self):
        app = session_folder(self.tmp, [])
        truth = write(self.tmp, "truth.csv", "clip,start_s,end_s\nVID_9.mp4,1,2\n")
        with self.assertRaisesRegex(SystemExit, "VID_9.mp4' is not one of the app's clips"):
            self.run_main("--truth", truth, "--app", app)

    def test_visit_after_the_end_of_the_clip_is_refused(self):
        app = session_folder(self.tmp, [])
        truth = write(self.tmp, "truth.csv", "clip,start_s,end_s\nVID_2.mp4,45,50\n")
        with self.assertRaisesRegex(SystemExit, "after the end of clip"):
            self.run_main("--truth", truth, "--app", app)


if __name__ == "__main__":
    unittest.main()
