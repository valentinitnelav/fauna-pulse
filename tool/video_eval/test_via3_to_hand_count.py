"""Tests for via3_to_hand_count.py and prepare_square.py (round 272). Run: python3 -m unittest (in tool/video_eval)."""
import csv
import json
import shutil
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path

import evaluate_track_ids as ev
import prepare_square as ps
import via3_to_hand_count as vh


def video_project(tmp, clip="A_square.mp4"):
    """A project as prepare_square.py writes it, for one video."""
    return ps.via3_project(ps.VIDEO_TEMPLATE, "A", [Path(tmp) / clip], 4)


def segment(insect, t0, t1, **fields):
    """A time segment as VIA3 saves it: attribute ids of the template, option ids as values."""
    ids = {"taxon": "2", "focus": "3", "size": "4", "sure": "5", "edge": "6", "on_flower": "7", "note": "8"}
    av = {"1": insect}
    av.update({ids[k]: v for k, v in fields.items()})
    return {"vid": "1", "flg": 0, "z": [t0, t1], "xy": [], "av": av}


def save(tmp, name, project, metadata):
    project["metadata"] = {f"m{i}": m for i, m in enumerate(metadata)}
    path = Path(tmp) / name
    path.write_text(json.dumps(project))
    return path


def run(argv):
    out, err = StringIO(), StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = vh.main([str(a) for a in argv])
    return code, out.getvalue(), err.getvalue()


def rows(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


WATCHED = {"vid": "1", "flg": 0, "z": [], "xy": [], "av": {"10": "whole_video"}}


class VideoProjectTest(unittest.TestCase):
    def test_appearances_ignore_and_positions(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = save(tmp, "a_via3.json", video_project(tmp), [
                WATCHED,
                segment("1", 2.0, 5.5, taxon="hoverfly", focus="sharp"),
                segment("1", 9.0, 12.0, focus="soft"),  # taxon filled from the first appearance
                segment("6", 3.0, 4.0, taxon="beetle", note="maybe same as insect 1"),  # a row typed in VIA3
                segment("ignore", 20.0, 25.0, note="camera knocked"),
                {"vid": "1", "flg": 0, "z": [3.0], "xy": [2, 10, 20, 30, 40], "av": {"9": "1"}},
                {"vid": "1", "flg": 0, "z": [3.5], "xy": [1, 50, 60], "av": {"1": "6"}},  # row selected while drawing
            ])
            code, out, err = run([path, "--out", tmp])
            self.assertEqual(code, 0, err)
            hc = rows(Path(tmp) / "hand_count.csv")
            self.assertEqual([(r["insect"], r["start_s"], r["end_s"], r["taxon"], r["focus"]) for r in hc], [
                ("1", "2.000", "5.500", "hoverfly", "sharp"),
                ("6", "3.000", "4.000", "beetle", ""),
                ("1", "9.000", "12.000", "hoverfly", "soft"),
            ])
            self.assertEqual(hc[1]["note"], "maybe same as insect 1")
            ig = rows(Path(tmp) / "ignore_spans.csv")
            self.assertEqual([(r["start_s"], r["end_s"], r["note"]) for r in ig], [("20.000", "25.000", "camera knocked")])
            pos = rows(Path(tmp) / "positions.csv")
            self.assertEqual([(r["insect"], r["x"], r["y"], r["w"]) for r in pos],
                             [("1", "25.000", "40.000", "30.000"), ("6", "50.000", "60.000", "")])
            self.assertIn("2 insects, 3 appearances", out)
            self.assertEqual(err, "")
            # evaluate_track_ids.py reads the hand count as it is
            visits, watched = ev.read_truth([Path(tmp) / "hand_count.csv"], None)
            self.assertEqual([(v[1], v[2], v[3]) for v in visits], [(2.0, 5.5, "hoverfly"), (3.0, 4.0, "beetle"), (9.0, 12.0, "hoverfly")])

    def test_watched_without_insects_and_unfinished(self):
        with tempfile.TemporaryDirectory() as tmp:
            done = save(tmp, "done_via3.json", video_project(tmp, "EMPTY.mp4"), [WATCHED])
            todo = save(tmp, "todo_via3.json", video_project(tmp, "TODO.mp4"), [segment("1", 1.0, 2.0)])
            code, out, err = run([done, todo, "--out", tmp])
            self.assertEqual(code, 0, err)
            hc = rows(Path(tmp) / "hand_count.csv")
            self.assertEqual([(r["clip"], r["start_s"]) for r in hc], [("EMPTY.mp4", "")])
            self.assertIn("TODO.mp4: 'watched' is not 'whole video'", err)
            visits, watched = ev.read_truth([Path(tmp) / "hand_count.csv"], None)
            self.assertEqual((visits, [w[0] for w in watched]), ([], ["EMPTY.mp4"]))
            code, out, err = run([done, todo, "--out", tmp, "--include-unfinished"])
            self.assertEqual([r["clip"] for r in rows(Path(tmp) / "hand_count.csv")], ["EMPTY.mp4", "TODO.mp4"])

    def test_warnings(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = save(tmp, "w_via3.json", video_project(tmp), [
                WATCHED,
                segment("1", 2.0, 5.0, taxon="hoverfly"),
                segment("1", 4.0, 6.0, taxon="other_bee"),
                {"vid": "1", "flg": 0, "z": [30.0], "xy": [1, 5, 5], "av": {"9": "1"}},
                {"vid": "1", "flg": 0, "z": [3.0], "xy": [1, 5, 5], "av": {"9": "7"}},
            ])
            code, out, err = run([path, "--out", tmp])
            self.assertEqual(code, 0)
            self.assertIn("different taxa", err)
            self.assertIn("overlapping appearances", err)
            self.assertIn("outside its appearances", err)
            self.assertIn("insect 7, which has no timeline row", err)

    def test_not_a_template_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = video_project(tmp)
            p["attribute"]["1"]["aname"] = "activity"
            code, out, err = run([save(tmp, "x.json", p, []), "--out", tmp])
            self.assertEqual(code, 1)
            self.assertIn("no timeline attribute 'insect'", err)

    def test_draft_comparison(self):
        with tempfile.TemporaryDirectory() as tmp:
            draft = video_project(tmp)
            draft["metadata"] = {
                "a": segment("1", 1.0, 2.0), "b": segment("2", 3.0, 4.0), "c": segment("3", 5.0, 6.0),
                "p": {"vid": "1", "flg": 0, "z": [1.5], "xy": [1, 5, 5], "av": {"9": "1"}},
            }
            final = json.loads(json.dumps(draft))
            final["metadata"]["b"]["z"] = [3.0, 4.5]  # changed
            del final["metadata"]["c"]  # deleted
            final["metadata"]["d"] = segment("4", 7.0, 8.0)  # added
            final["metadata"]["w"] = WATCHED
            dp, fp = Path(tmp) / "draft.json", Path(tmp) / "final.json"
            dp.write_text(json.dumps(draft))
            fp.write_text(json.dumps(final))
            code, out, err = run([fp, "--draft", dp, "--out", tmp])
            self.assertEqual(code, 0, err)
            self.assertIn("appearances: 1 kept, 1 changed, 1 deleted, 1 added", out)
            self.assertIn("positions: 1 kept, 0 changed, 0 deleted, 0 added", out)


class SnapshotProjectTest(unittest.TestCase):
    def test_counts_only_counted_pictures(self):
        with tempfile.TemporaryDirectory() as tmp:
            names = [ps.snapshot_name("A_square", 3.2, 96), ps.snapshot_name("A_square", 14.0, 420), ps.snapshot_name("A_square", 25.5, 765)]
            p = ps.via3_project(ps.SNAPSHOT_TEMPLATE, "A snapshots", [Path(tmp) / n for n in names], 2)
            path = save(tmp, "s_via3.json", p, [
                {"vid": "1", "flg": 0, "z": [], "xy": [], "av": {"3": "yes"}},  # counted, no insect
                {"vid": "2", "flg": 0, "z": [], "xy": [], "av": {"3": "yes", "4": "two flies"}},
                {"vid": "2", "flg": 0, "z": [], "xy": [1, 10, 10], "av": {"1": "sharp"}},
                {"vid": "2", "flg": 0, "z": [], "xy": [2, 0, 0, 4, 4], "av": {"2": "yes"}},
                {"vid": "3", "flg": 0, "z": [], "xy": [1, 1, 1], "av": {}},  # not marked counted
            ])
            code, out, err = run([path, "--out", tmp])
            self.assertEqual(code, 0, err)
            snaps = rows(Path(tmp) / "snapshots.csv")
            self.assertEqual([(r["clip"], r["t_s"], r["frame"], r["n_insects"], r["n_edge"]) for r in snaps],
                             [("A_square", "3.200", "96", "0", "0"), ("A_square", "14.000", "420", "2", "1")])
            self.assertEqual(snaps[1]["note"], "two flies")
            pts = rows(Path(tmp) / "snapshot_points.csv")
            self.assertEqual([(r["x"], r["y"], r["focus"], r["edge"]) for r in pts],
                             [("10.000", "10.000", "sharp", ""), ("2.000", "2.000", "", "yes")])
            self.assertIn("1 of 3 pictures not marked 'counted'", err)


class PrepareSquareTest(unittest.TestCase):
    def test_snapshot_frames(self):
        times = [i / 30 for i in range(30 * 95)]  # 95 s at 30 fps
        a = ps.snapshot_frames(times, "clip", n=30)
        self.assertEqual(a, ps.snapshot_frames(times, "clip", n=30))  # repeatable
        self.assertNotEqual(a, ps.snapshot_frames(times, "other", n=30))
        self.assertEqual(len(a), 10)  # one per started 10-s block
        for k, f in enumerate(a):
            self.assertTrue(10 * k <= times[f] < 10 * (k + 1))
        self.assertEqual(len(ps.snapshot_frames(times, "clip", n=4)), 4)

    def test_check_square(self):
        ps.check_square(40, 0, 480, 640, 480)
        for bad in ((41, 0, 480), (40, 0, 481), (200, 0, 480), (-2, 0, 100), (0, 2, 480)):
            with self.assertRaises(ps.InputError):
                ps.check_square(*bad, 640, 480)

    def test_project_points_to_files(self):
        p = ps.via3_project(ps.VIDEO_TEMPLATE, "A", ["/data/my videos/A_square.mp4"], 4)
        self.assertEqual(p["project"]["vid_list"], ["1"])
        self.assertEqual(p["view"]["1"], {"fid_list": [1]})
        # the folder once as VIA3's location prefix, only the name per file
        self.assertEqual(p["config"]["file"]["loc_prefix"]["3"], "/data/my%20videos/")
        self.assertEqual(p["file"]["1"]["src"], "A_square.mp4")
        self.assertEqual(ps.file_path(p, p["file"]["1"]), Path("/data/my videos/A_square.mp4"))
        self.assertEqual((p["file"]["1"]["loc"], p["file"]["1"]["type"], p["file"]["1"]["fname"]), (3, 4, "A_square.mp4"))
        # moved: only the prefix changes (typed as a plain folder in VIA3)
        p["config"]["file"]["loc_prefix"]["3"] = "/media/usb/my videos/"
        self.assertEqual(ps.file_path(p, p["file"]["1"]), Path("/media/usb/my videos/A_square.mp4"))
        # files from several folders keep their full paths
        two = ps.via3_project(ps.SQUARES_TEMPLATE, "S", ["/a/A.mp4", "/b/B c.mp4"], 4)
        self.assertEqual(two["config"]["file"]["loc_prefix"]["3"], "")
        self.assertEqual(two["file"]["2"]["src"], "file:///b/B%20c.mp4")
        self.assertEqual(ps.file_path(two, two["file"]["2"]), Path("/b/B c.mp4"))
        self.assertEqual(p["attribute"]["1"]["aname"], "insect")  # the timeline groups by the first attribute
        self.assertEqual(vh.SNAPSHOT_NAME.match(ps.snapshot_name("A_square", 3.2, 96)).groupdict(),
                         {"clip": "A_square", "t": "0003.200", "frame": "00096"})

    def test_square_from_rect(self):
        self.assertEqual(ps.square_from_rect(100, 50, 200, 100, 640, 480), (100, 0, 200))  # longer side, same centre
        self.assertEqual(ps.square_from_rect(0, 0, 600, 500, 640, 480), (60, 0, 480))  # at most the height
        self.assertEqual(ps.square_from_rect(600, 400, 100, 100, 640, 480), (540, 380, 100))  # moved inside
        self.assertEqual(ps.square_from_rect(101.4, 51.2, 201.3, 99.0, 640, 480), (102, 0, 200))  # even numbers
        with self.assertRaises(ps.InputError):
            ps.square_from_rect(5, 5, 1, 1, 640, 480)

    def test_expand_videos_and_default_out(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            for name in ("b.mp4", "A.MOV", "notes.txt", "a_square.mp4"):
                (d / name).write_bytes(b"")
            (d / "eval").mkdir()
            (d / "eval" / "c.mp4").write_bytes(b"")  # subfolders are not searched
            self.assertEqual([f.name for f in ps.expand_videos([d])], ["A.MOV", "b.mp4"])
            self.assertEqual([f.name for f in ps.expand_videos([d / "b.mp4", d])], ["b.mp4", "A.MOV"])  # no doubles
            with self.assertRaises(ps.InputError):
                ps.expand_videos([d / "missing.mp4"])
            with self.assertRaises(ps.InputError):
                ps.expand_videos([d / "eval" / "x"])
            self.assertEqual(ps.default_out(d / "b.mp4"), d.resolve() / "eval")
            self.assertEqual(ps.default_out(d / "eval" / "c.mp4"), d.resolve() / "eval")

    def test_squares_from_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            videos = [Path(tmp) / "A clip.mp4", Path(tmp) / "B.mp4", Path(tmp) / "C.mp4"]
            for v in videos:
                v.write_bytes(b"")
            p = ps.via3_project(ps.SQUARES_TEMPLATE, "Target squares", videos, 4)
            p["metadata"] = {
                "a": {"vid": "1", "flg": 0, "z": [3.2], "xy": [2, 10.5, 20, 300, 280], "av": {}},
                "b": {"vid": "2", "flg": 0, "z": [1.0], "xy": [1, 5, 5], "av": {}},  # a point: not a square
            }
            path = Path(tmp) / "squares.json"
            path.write_text(json.dumps(p))
            got = ps.squares_from_project(path)
            self.assertEqual(got, [(videos[0].resolve(), [10.5, 20, 300, 280]), (videos[1].resolve(), None), (videos[2].resolve(), None)])
            p["metadata"]["c"] = {"vid": "1", "flg": 0, "z": [5.0], "xy": [2, 0, 0, 50, 50], "av": {}}
            path.write_text(json.dumps(p))
            with self.assertRaises(ps.InputError):
                ps.squares_from_project(path)  # two rectangles on one video
            del p["metadata"]["c"]
            p["config"]["file"]["loc_prefix"]["3"] = "/nowhere/"
            path.write_text(json.dumps(p))
            with self.assertRaisesRegex(ps.InputError, "File Location"):
                ps.squares_from_project(path)  # moved videos: says how to fix it in VIA3

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "needs ffmpeg")
    def test_crop_from_via_and_refuse_before_cropping(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "clip.mp4"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=30:duration=3",
                            "-pix_fmt", "yuv420p", str(src)], check=True)
            out = Path(tmp).resolve() / "eval"  # the default: "eval" next to the videos
            with redirect_stdout(StringIO()):
                self.assertEqual(ps.main(["squares", tmp]), 0)
            project = json.loads((out / "squares_via3.json").read_text())
            project["metadata"] = {"r": {"vid": "1", "flg": 0, "z": [1.0], "xy": [2, 30, 10, 90, 60], "av": {}}}
            saved = Path(tmp) / "via_project_saved.json"
            saved.write_text(json.dumps(project))
            buf = StringIO()
            with redirect_stdout(buf):
                self.assertEqual(ps.main(["crop", "--from-via", str(saved)]), 0)
            self.assertIn("→ square x 30, y 0, side 90", buf.getvalue())  # centre y 40, moved inside
            square = out / "clip_square.mp4"
            info = ps.probe(square)
            self.assertEqual((info["width"], info["height"]), (90, 90))
            self.assertTrue((out / "clip_square_preview.jpg").exists())
            # an annotated project stops a new crop before the video is replaced
            annotated = json.loads((out / "clip_square_via3.json").read_text())
            annotated["metadata"] = {"m": segment("1", 1.0, 2.0)}
            (out / "clip_square_via3.json").write_text(json.dumps(annotated))
            before = square.stat().st_mtime_ns
            err = StringIO()
            with redirect_stdout(StringIO()), redirect_stderr(err):
                self.assertEqual(ps.main(["crop", str(src), "--x", "0", "--y", "0", "--side", "100"]), 1)
            self.assertIn("already holds annotations", err.getvalue())
            self.assertEqual(square.stat().st_mtime_ns, before)

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "needs ffmpeg")
    def test_crop_and_annotation_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "clip.mp4"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=30:duration=12",
                            "-pix_fmt", "yuv420p", str(src)], check=True)
            self.assertTrue(ps.range_image(src, tmp).exists())
            self.assertTrue(ps.preview_image(src, tmp, 20, 10, 100).exists())
            square = ps.crop_video(src, tmp, 20, 10, 100)
            info = ps.probe(square)
            self.assertEqual((info["width"], info["height"], len(info["times"])), (100, 100, 360))
            meta = json.loads(square.with_suffix(".json").read_text())
            self.assertEqual((meta["square"], meta["frames"]), ({"x": 20, "y": 10, "side": 100}, 360))
            video_json, snap_json, pictures = ps.annotation_files(square, tmp)
            self.assertEqual(len(pictures), 2)  # 12 s: blocks 0-10 s and 10-12 s
            self.assertTrue(all(p.exists() for p in pictures))
            code, out, err = run([snap_json, "--out", tmp])
            self.assertEqual(code, 0)
            self.assertIn("2 of 2 pictures not marked 'counted'", err)
            proj = json.loads(video_json.read_text())
            self.assertEqual(ps.file_path(proj, proj["file"]["1"]), square.resolve())
            snap = json.loads(snap_json.read_text())
            self.assertEqual(ps.file_path(snap, snap["file"]["1"]), pictures[0].resolve())
            annotated = json.loads(video_json.read_text())
            annotated["metadata"] = {"m": segment("1", 1.0, 2.0)}
            video_json.write_text(json.dumps(annotated))
            with self.assertRaises(ps.InputError):
                ps.annotation_files(square, tmp)  # never overwrites annotations
            self.assertEqual(json.loads(video_json.read_text())["metadata"], annotated["metadata"])


if __name__ == "__main__":
    unittest.main()
