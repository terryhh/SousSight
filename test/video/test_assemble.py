"""Unit tests for tool/video/assemble.py. No ffmpeg, node or `say` needed:
external commands are captured by a fake Runner or mocked subprocess. One
concat regression also runs the real ffmpeg when it is on PATH (skipped
otherwise).

    python3 -I -m unittest discover -s test/video -p 'test_*.py'
"""
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tool" / "video"))

import assemble  # noqa: E402

STEPS, VIEWPORTS = assemble.load_journey()


def cap(seg_id, step="home", viewport="desktop", duration=5, **extra):
    seg = {"id": seg_id, "duration_s": duration, "source": "capture",
           "capture": {"journey_step": step, "viewport": viewport}}
    seg.update(extra)
    return seg


def terry(seg_id, slot="T01-hook", duration=6, **extra):
    seg = {"id": seg_id, "duration_s": duration, "source": "terry", "terry_clip": slot,
           "terry_instructions": "Wide shot of the counter."}
    seg.update(extra)
    return seg


def title(seg_id, text="SousSight", duration=4, **extra):
    seg = {"id": seg_id, "duration_s": duration, "source": "title", "title": {"text": text, "sub": "sub"}}
    seg.update(extra)
    return seg


def validate(data):
    return assemble.validate_edl(data, STEPS, VIEWPORTS)


class FakeRunner(assemble.Runner):
    """Records commands; answers ffprobe/say queries from a table."""

    def __init__(self, answers=None):
        super().__init__(dry_run=False)
        self.answers = answers or {}

    def run(self, cmd, *, capture=False):
        self.log.append(list(cmd))
        for key, value in self.answers.items():
            if key(cmd):
                return value(cmd) if callable(value) else value
        return ""


class JourneyTests(unittest.TestCase):
    def test_journey_matches_the_card(self):
        self.assertEqual(
            STEPS,
            ("home", "type-list", "find-meal", "result-badge", "open-recipe", "cooking-screen",
             "coach-lite-question", "coach-lite-answer", "watch-start", "watch-unsure", "ledger",
             "on-device-sheet", "how-it-works"),
        )
        self.assertEqual(VIEWPORTS, ("desktop", "phone"))


class ValidationTests(unittest.TestCase):
    def test_shipped_edl_is_valid_and_within_budget(self):
        data = json.loads((ROOT / "tool/video/edl.json").read_text())
        errors, warnings = validate(data)
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])
        self.assertLessEqual(sum(s["duration_s"] for s in data), 175)
        # The human hook comes first, and app footage is never a title card.
        self.assertEqual(data[0]["source"], "terry")

    def test_minimal_valid_edl(self):
        self.assertEqual(validate([terry("a"), cap("b"), title("c")]), ([], []))

    def test_rejects_non_list_or_empty(self):
        for data in ({}, [], "x", None):
            errors, _ = validate(data)
            self.assertTrue(errors, data)

    def test_total_over_175_is_rejected(self):
        errors, _ = validate([cap("a", duration=60), cap("b", duration=60), cap("c", duration=55.5)])
        self.assertTrue(any("175" in e for e in errors), errors)

    def test_exactly_175_is_allowed(self):
        errors, _ = validate([cap("a", duration=60), cap("b", duration=60), cap("c", duration=55)])
        self.assertEqual(errors, [])

    def test_unknown_journey_step_rejected(self):
        errors, _ = validate([cap("a", step="dinner-party")])
        self.assertTrue(any("unknown journey_step 'dinner-party'" in e for e in errors), errors)

    def test_unknown_viewport_rejected(self):
        errors, _ = validate([cap("a", viewport="tablet")])
        self.assertTrue(any("viewport" in e for e in errors), errors)

    def test_capture_needs_capture_object(self):
        seg = cap("a")
        del seg["capture"]
        errors, _ = validate([seg])
        self.assertTrue(any("capture segments need" in e for e in errors), errors)

    def test_capture_in_s_must_be_non_negative_number(self):
        for bad in (-1, "2", True):
            seg = cap("a")
            seg["capture"]["in_s"] = bad
            errors, _ = validate([seg])
            self.assertTrue(any("in_s" in e for e in errors), (bad, errors))

    def test_terry_needs_slot_and_instructions(self):
        seg = terry("a")
        del seg["terry_clip"]
        self.assertTrue(any("terry_clip" in e for e in validate([seg])[0]))
        seg = terry("a", terry_instructions="  ")
        self.assertTrue(any("terry_instructions" in e for e in validate([seg])[0]))

    def test_terry_slot_cannot_escape_the_input_folder(self):
        for slot in ("../secrets", "a/b", "", "x y"):
            errors, _ = validate([terry("a", slot=slot)])
            self.assertTrue(any("terry_clip" in e for e in errors), slot)

    def test_title_needs_text(self):
        for bad in ({"sub": "x"}, {"text": ""}, "Title", None):
            seg = title("a")
            seg["title"] = bad
            errors, _ = validate([seg])
            self.assertTrue(any("title" in e for e in errors), bad)
        seg = title("a")
        seg["title"]["sub"] = 5
        self.assertTrue(any("title.sub" in e for e in validate([seg])[0]))

    def test_source_must_be_known(self):
        seg = cap("a")
        seg["source"] = "ai-generated"
        errors, _ = validate([seg])
        self.assertTrue(any("source must be one of" in e for e in errors), errors)

    def test_ids_unique_and_safe(self):
        errors, _ = validate([cap("a"), cap("a")])
        self.assertTrue(any("duplicate" in e for e in errors))
        errors, _ = validate([cap("../x")])
        self.assertTrue(any("id must be" in e for e in errors))

    def test_duration_must_be_positive_number(self):
        for bad in (0, -2, "5", None, True):
            errors, _ = validate([cap("a", duration=bad)])
            self.assertTrue(any("duration_s" in e for e in errors), bad)

    def test_text_fields_must_be_text(self):
        errors, _ = validate([cap("a", caption=3)])
        self.assertTrue(any("caption must be text" in e for e in errors))

    def test_start_mismatch_is_a_warning_and_bad_start_an_error(self):
        errors, warnings = validate([cap("a", start="0:00"), cap("b", start="0:09")])
        self.assertEqual(errors, [])
        self.assertTrue(any("declared start 0:09" in w for w in warnings), warnings)
        errors, _ = validate([cap("a", start="soon")])
        self.assertTrue(any("timecode" in e for e in errors))

    def test_matching_starts_are_quiet(self):
        self.assertEqual(validate([cap("a", start="0:00"), cap("b", start="0:05.2")]), ([], []))

    def test_long_segment_warns(self):
        _, warnings = validate([cap("a", duration=61)])
        self.assertTrue(warnings)


class TimelineTests(unittest.TestCase):
    def test_parse_timecode(self):
        self.assertEqual(assemble.parse_timecode("0:00"), 0.0)
        self.assertEqual(assemble.parse_timecode("1:05.5"), 65.5)
        self.assertEqual(assemble.parse_timecode("1:02:03"), 3723.0)
        self.assertEqual(assemble.parse_timecode("12.25"), 12.25)
        self.assertEqual(assemble.parse_timecode(7), 7.0)
        for bad in ("1:75", "-1", "a:b", True, -3, "1::2"):
            with self.assertRaises(ValueError, msg=bad):
                assemble.parse_timecode(bad)

    def test_format_timecode(self):
        self.assertEqual(assemble.format_timecode(0), "0:00.0")
        self.assertEqual(assemble.format_timecode(65.5), "1:05.5")
        self.assertEqual(assemble.format_timecode(-1), "0:00.0")

    def test_segments_are_placed_back_to_back_in_whole_frames(self):
        tl = assemble.build_timeline([cap("a", duration=6.5), cap("b", duration=1.01), cap("c", duration=2)])
        self.assertEqual([p.frames for p in tl], [195, 30, 60])
        self.assertEqual([p.start_frame for p in tl], [0, 195, 225])
        self.assertAlmostEqual(tl[1].start, 6.5)
        self.assertAlmostEqual(tl[2].end, 9.5)
        self.assertAlmostEqual(assemble.total_seconds(tl), 9.5)
        self.assertEqual(assemble.total_seconds([]), 0.0)

    def test_tiny_segment_gets_at_least_one_frame(self):
        self.assertEqual(assemble.build_timeline([cap("a", duration=0.001)])[0].frames, 1)

    def test_vo_windows_run_to_the_next_voiced_segment(self):
        tl = assemble.build_timeline([
            cap("a", duration=5, voiceover="one"),
            title("b", duration=4),
            cap("c", duration=6, voiceover="two"),
        ])
        self.assertEqual(assemble.vo_windows(tl), {"a": 9.0, "c": 6.0})

    def test_faster_rate(self):
        self.assertIsNone(assemble.faster_rate(170, 4.0, 5.0))
        self.assertIsNone(assemble.faster_rate(170, 4.0, 0))
        self.assertGreater(assemble.faster_rate(170, 6.0, 5.0), 170)
        self.assertEqual(assemble.faster_rate(170, 30.0, 5.0), assemble.MAX_RATE_WPM)


class PlanAndCommandTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.capture = base / "capture"
        self.input = base / "input"
        self.cards = base / "cards"
        (self.capture / "desktop").mkdir(parents=True)
        (self.input / "terry").mkdir(parents=True)
        (self.capture / "desktop" / "home.mp4").write_bytes(b"x")

    def tearDown(self):
        self.tmp.cleanup()

    def plans(self, segs):
        return assemble.plan_segments(assemble.build_timeline(segs), capture_dir=self.capture,
                                      input_dir=self.input, cards_dir=self.cards)

    def test_capture_present_missing_and_terry_placeholder(self):
        segs = [cap("a", caption="Hi"), cap("b", step="ledger"), terry("c", slot="T09-x"), title("d")]
        a, b, c, d = self.plans(segs)
        self.assertEqual((a.kind, a.path.name, a.caption.name), ("clip", "home.mp4", "caption-a.png"))
        self.assertEqual((b.kind, b.path.name), ("still", "placeholder-b.png"))
        self.assertIn("MISSING capture desktop/ledger", b.note)
        self.assertEqual((c.kind, c.path.name, c.keep_audio), ("still", "placeholder-c.png", False))
        self.assertIn("PLACEHOLDER terry slot T09-x", c.note)
        self.assertEqual((d.kind, d.path.name, d.caption), ("still", "title-d.png", None))

    def test_terry_clip_found_as_mp4_or_mov(self):
        (self.input / "terry" / "T09-x.MOV").write_bytes(b"x")
        (c,) = self.plans([terry("c", slot="T09-x")])
        # Case-insensitive file systems (macOS) may report either spelling.
        self.assertEqual((c.kind, c.path.name.lower(), c.keep_audio), ("clip", "t09-x.mov", True))
        self.assertIsNone(assemble.find_terry_clip(self.input, "T10-none"))

    def test_voiceover_lookup(self):
        self.assertIsNone(assemble.find_voiceover(self.input))
        (self.input / "voiceover.m4a").write_bytes(b"x")
        self.assertEqual(assemble.find_voiceover(self.input).name, "voiceover.m4a")

    def test_placeholder_command_loops_the_card_for_exact_frames(self):
        (plan,) = self.plans([terry("c", slot="T09-x", duration=6.5, caption="Cap")])
        cmd = assemble.segment_cmd("ffmpeg", plan, Path("/o/seg.mp4"))
        self.assertEqual(cmd[0], "ffmpeg")
        i = cmd.index("-loop")
        self.assertEqual(cmd[i:i + 7], ["-loop", "1", "-framerate", "30", "-t", "7.500", "-i"])
        self.assertTrue(cmd[i + 7].endswith("placeholder-c.png"))
        self.assertTrue(any(a.endswith("caption-c.png") for a in cmd))
        graph = cmd[cmd.index("-filter_complex") + 1]
        self.assertIn("[base][1:v]overlay=0:0", graph)
        self.assertNotIn("tpad", graph)
        self.assertEqual(cmd[cmd.index("-frames:v") + 1], "195")
        self.assertIn("-an", cmd)
        self.assertIn("libx264", cmd)
        self.assertEqual(cmd[-1], "/o/seg.mp4")

    def test_clip_command_trims_from_in_point_and_holds_last_frame(self):
        segs = [cap("a", duration=4)]
        segs[0]["capture"]["in_s"] = 2.5
        (plan,) = self.plans(segs)
        cmd = assemble.segment_cmd("ffmpeg", plan, Path("/o/a.mp4"))
        self.assertEqual(cmd[cmd.index("-ss") + 1], "2.500")
        self.assertLess(cmd.index("-ss"), cmd.index("-i"))
        graph = cmd[cmd.index("-filter_complex") + 1]
        self.assertIn("tpad=stop_mode=clone", graph)
        self.assertIn("force_original_aspect_ratio=decrease", graph)
        self.assertIn("pad=1920:1080", graph)
        self.assertNotIn("overlay", graph)
        self.assertEqual(cmd[cmd.index("-frames:v") + 1], "120")

    def test_unknown_plan_kind_raises(self):
        (plan,) = self.plans([title("d")])
        bad = assemble.Plan(plan.placed, "hologram", plan.path, 0, None, False, "")
        with self.assertRaises(ValueError):
            assemble.segment_cmd("ffmpeg", bad, Path("/o/x.mp4"))

    def test_mix_command_delays_each_cue_to_its_start(self):
        cues = [
            assemble.AudioCue(Path("/w/vo-a.aiff"), 0.0),
            assemble.AudioCue(Path("/in/T1.mov"), 12.5, 6.0, 1.0, 0.35),
        ]
        cmd = assemble.mix_cmd("ffmpeg", Path("/w/body.mp4"), cues, 30.0, Path("/o/out.mp4"))
        graph = cmd[cmd.index("-filter_complex") + 1]
        self.assertIn("[2:a]aresample=48000,aformat=channel_layouts=stereo,volume=1,adelay=0|0[c0]", graph)
        self.assertIn("volume=0.35,adelay=12500|12500[c1]", graph)
        self.assertIn("[1:a][c0][c1]amix=inputs=3:normalize=0:duration=first", graph)
        # The terry clip is cut to its segment before mixing.
        j = cmd.index("/in/T1.mov")
        self.assertEqual(cmd[j - 5:j], ["-ss", "1.000", "-t", "6.000", "-i"])
        self.assertEqual(cmd[cmd.index("-c:a") + 1], "aac")
        self.assertEqual(cmd[-1], "/o/out.mp4")
        self.assertEqual(cmd[cmd.index("-t", j) + 1], "30.000")

    def test_mix_with_no_cues_is_silence(self):
        cmd = assemble.mix_cmd("ffmpeg", Path("b.mp4"), [], 10.0, Path("o.mp4"))
        self.assertIn("[1:a]amix=inputs=1", cmd[cmd.index("-filter_complex") + 1])

    def test_say_command(self):
        self.assertEqual(
            assemble.say_cmd(Path("t.txt"), Path("o.aiff"), voice="Samantha", rate=170),
            ["say", "-v", "Samantha", "-r", "170", "-f", "t.txt", "-o", "o.aiff"],
        )
        self.assertNotIn("-v", assemble.say_cmd(Path("t.txt"), Path("o.aiff"), voice=None, rate=170))

    def test_concat_and_frame_commands(self):
        self.assertIn("concat", assemble.concat_cmd("ffmpeg", Path("l.txt"), Path("b.mp4")))
        cmd = assemble.frame_cmd("ffmpeg", Path("o.mp4"), 3.25, Path("f.png"))
        self.assertEqual(cmd[cmd.index("-ss") + 1], "3.250")


@contextlib.contextmanager
def working_directory(path):
    previous = os.getcwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(previous)


def concat_entry_path(line):
    """Undoes concat_list_line: the path ffmpeg reads from one list line."""
    assert line.startswith("file '") and line.endswith("'"), line
    return line[len("file '"):-1].replace("'\\''", "'")


class ConcatListTests(unittest.TestCase):
    def test_relative_segment_paths_become_absolute(self):
        # Regression (PR #225 review): with --work-dir build/work the list held
        # build/work/segments/001-a.mp4, which ffmpeg resolves against the
        # list's own directory (build/work/build/work/segments/...).
        with tempfile.TemporaryDirectory() as tmp, working_directory(tmp):
            line = assemble.concat_list_line(Path("build/work/segments/001-a.mp4"))
            path = Path(concat_entry_path(line))
            self.assertTrue(path.is_absolute())
            self.assertEqual(path, (Path(tmp) / "build/work/segments/001-a.mp4").resolve())

    def test_apostrophes_are_escaped_for_the_concat_demuxer(self):
        line = assemble.concat_list_line(Path("/w/Terry's demo/001-a.mp4"))
        self.assertEqual(line, "file '/w/Terry'\\''s demo/001-a.mp4'")
        self.assertEqual(concat_entry_path(line), "/w/Terry's demo/001-a.mp4")

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg not on PATH")
    def test_real_ffmpeg_concats_from_a_relative_work_dir(self):
        with tempfile.TemporaryDirectory() as tmp, working_directory(tmp):
            work = Path("build/work d'or")
            segdir = work / "segments"
            segdir.mkdir(parents=True)
            lines = []
            for i in range(2):
                out = segdir / f"00{i + 1}-s.mp4"
                subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                                "color=c=black:s=64x64:r=30:d=0.5", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                                str(out)], check=True)
                lines.append(assemble.concat_list_line(out))
            list_file = work / "segments.txt"
            list_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
            body = work / "body.mp4"
            done = subprocess.run(assemble.concat_cmd("ffmpeg", list_file, body), capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            duration = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of",
                                       "csv=p=0", str(body)], capture_output=True, text=True, check=True).stdout
            self.assertAlmostEqual(float(duration), 1.0, delta=0.1)


class OutputCheckTests(unittest.TestCase):
    def probe(self, duration=170.0, vcodec="h264", acodec="aac", size=(1920, 1080)):
        return {"format": {"duration": str(duration)}, "streams": [
            {"codec_type": "video", "codec_name": vcodec, "width": size[0], "height": size[1]},
            {"codec_type": "audio", "codec_name": acodec}]}

    def test_good_output(self):
        self.assertEqual(assemble.check_output(self.probe()), [])

    def test_hard_three_minute_limit(self):
        self.assertEqual(assemble.check_output(self.probe(duration=180.0)), [])
        self.assertTrue(any("3:00" in p for p in assemble.check_output(self.probe(duration=180.01))))

    def test_codec_size_and_empty(self):
        self.assertTrue(assemble.check_output(self.probe(vcodec="vp9")))
        self.assertTrue(assemble.check_output(self.probe(acodec="opus")))
        self.assertTrue(assemble.check_output(self.probe(size=(1280, 720))))
        self.assertTrue(assemble.check_output({}))


class DraftVoiceoverTests(unittest.TestCase):
    def test_uses_samantha_and_speeds_up_long_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            tl = assemble.build_timeline([cap("a", duration=4, voiceover="A long line"), cap("b", duration=4, voiceover="Short")])
            durations = {"vo-a.aiff": [6.0, 3.9], "vo-b.aiff": [2.0]}

            def probe(cmd):
                return str(durations[Path(cmd[-1]).name].pop(0))

            runner = FakeRunner({
                (lambda c: c[:3] == ["say", "-v", "?"]): "Alex  en_US # hi\nSamantha  en_US    # Hello",
                (lambda c: c[0] == "ffprobe"): probe,
            })
            warnings = []
            with mock.patch.object(assemble.shutil, "which", return_value="/usr/bin/say"):
                cues = assemble.draft_voiceover(runner, "ffprobe", tl, Path(tmp), warnings)
            says = [c for c in runner.log if c[0] == "say" and c[1:3] != ["-v", "?"]]
            self.assertEqual(len(says), 3)
            self.assertTrue(all(c[1:3] == ["-v", "Samantha"] for c in says))
            self.assertEqual(says[0][says[0].index("-r") + 1], "170")
            self.assertGreater(int(says[1][says[1].index("-r") + 1]), 170)
            self.assertEqual([(c.path.name, c.at) for c in cues], [("vo-a.aiff", 0.0), ("vo-b.aiff", 4.0)])
            self.assertEqual(warnings, [])
            self.assertEqual((Path(tmp) / "vo-a.txt").read_text(), "A long line\n")

    def test_warns_without_samantha_and_when_still_too_long(self):
        with tempfile.TemporaryDirectory() as tmp:
            tl = assemble.build_timeline([cap("a", duration=2, voiceover="Far too long")])
            runner = FakeRunner({
                (lambda c: c[:3] == ["say", "-v", "?"]): "Alex  en_US # hi",
                (lambda c: c[0] == "ffprobe"): "9.0",
            })
            warnings = []
            with mock.patch.object(assemble.shutil, "which", return_value="/usr/bin/say"):
                assemble.draft_voiceover(runner, "ffprobe", tl, Path(tmp), warnings)
            self.assertTrue(any("Samantha" in w for w in warnings))
            self.assertTrue(any("shorten it" in w for w in warnings))
            self.assertTrue(all("-v" not in c[1:2] for c in runner.log if c[0] == "say" and c[1:3] != ["-v", "?"]))

    def test_no_say_means_no_voiceover(self):
        warnings = []
        with mock.patch.object(assemble.shutil, "which", return_value=None):
            cues = assemble.draft_voiceover(FakeRunner(), "ffprobe", [], Path("."), warnings)
        self.assertEqual(cues, [])
        self.assertTrue(warnings)


class RunnerTests(unittest.TestCase):
    def test_runs_and_raises_on_failure(self):
        runner = assemble.Runner()
        with mock.patch.object(assemble.subprocess, "run") as run:
            run.return_value = mock.Mock(returncode=0, stdout="12.5\n")
            self.assertEqual(runner.run(["ffprobe", "x"], capture=True), "12.5\n")
            run.return_value = mock.Mock(returncode=1, stdout="")
            with self.assertRaises(RuntimeError):
                runner.run(["ffmpeg", "-i", "x"])

    def test_dry_run_prints_without_running(self):
        runner = assemble.Runner(dry_run=True)
        with mock.patch.object(assemble.subprocess, "run") as run, mock.patch("builtins.print") as printed:
            runner.run(["ffmpeg", "-vf", "a b"])
        run.assert_not_called()
        self.assertIn("'a b'", printed.call_args[0][0])


class EndToEndPlanTests(unittest.TestCase):
    """assemble() with every external command faked: checks the pipeline order,
    the report and the exit codes without ffmpeg."""

    def run_assemble(self, segs, *, duration="120.0", extra=()):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        edl = base / "edl.json"
        edl.write_text(json.dumps(segs))
        (base / "input" / "terry").mkdir(parents=True)
        args = assemble.parse_args([
            "--edl", str(edl), "--capture-dir", str(base / "capture"), "--input-dir", str(base / "input"),
            "--work-dir", str(base / "work"), "--out", str(base / "out" / "draft.mp4"),
            "--contact-sheet", str(base / "out" / "sheet.png"), *extra])
        probe = {"format": {"duration": duration}, "streams": [
            {"codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080},
            {"codec_type": "audio", "codec_name": "aac"}]}
        runner = FakeRunner({
            (lambda c: c[:3] == ["say", "-v", "?"]): "Samantha en_US # hi",
            (lambda c: c[0] == "ffprobe" and "json" in c): json.dumps(probe),
            (lambda c: c[0] == "ffprobe"): "1.0",
        })
        with mock.patch.object(assemble.shutil, "which", return_value="/bin/x"), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = assemble.assemble(args, runner)
        report_path = base / "out" / "assembly-report.json"
        report = json.loads(report_path.read_text()) if report_path.exists() else None
        return code, runner.log, report

    def test_full_pipeline_with_placeholders(self):
        code, log, report = self.run_assemble([terry("a", voiceover="Hello"), cap("b", step="ledger"), title("c")])
        self.assertEqual(code, 0)
        tools = [c[0] for c in log]
        self.assertEqual(tools[0], "node")  # cards first
        self.assertIn("--edl", log[0])
        self.assertEqual(log[-1][0], "node")  # contact sheet last
        self.assertIn("--contact-sheet", log[-1])
        self.assertEqual(report["missing_terry_clips"], ["T01-hook"])
        self.assertEqual(report["missing_captures"], ["desktop/ledger"])
        self.assertEqual(report["voiceover"], "DRAFT macOS say")
        self.assertEqual(report["problems"], [])

    def test_over_three_minutes_fails_the_export(self):
        code, _, report = self.run_assemble([title("c")], duration="181.0")
        self.assertEqual(code, 3)
        self.assertTrue(report["problems"])

    def test_invalid_edl_stops_before_any_command(self):
        code, log, report = self.run_assemble([cap("a", step="nope")])
        self.assertEqual((code, log, report), (2, [], None))

    def test_validate_only_and_no_voiceover(self):
        code, log, _ = self.run_assemble([title("c", voiceover="x")], extra=["--validate-only"])
        self.assertEqual((code, log), (0, []))
        code, log, report = self.run_assemble([title("c", voiceover="x")], extra=["--no-voiceover"])
        self.assertEqual(report["voiceover"], "none")
        self.assertFalse(any(c[0] == "say" for c in log))

    def test_supplied_voiceover_is_used_whole(self):
        segs = [title("c", voiceover="x", duration=5)]
        with mock.patch.object(assemble, "find_voiceover", return_value=Path("/in/voiceover.wav")):
            code, log, report = self.run_assemble(segs)
        self.assertEqual(report["voiceover"], "supplied (voiceover.wav)")
        mix = next(c for c in log if "-filter_complex" in c and "amix" in c[c.index("-filter_complex") + 1])
        self.assertIn("/in/voiceover.wav", mix)
        self.assertFalse(any(c[0] == "say" for c in log))

    def test_terry_clip_sound_is_kept_quietly(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        clip = Path(tmp.name) / "T01-hook.mov"
        clip.write_bytes(b"x")
        with mock.patch.object(assemble, "find_terry_clip", return_value=clip):
            code, log, report = self.run_assemble([terry("a", duration=5)], extra=["--no-voiceover"])
        self.assertEqual(code, 0)
        self.assertEqual(report["missing_terry_clips"], [])
        mix = log[[i for i, c in enumerate(log) if "-filter_complex" in c and "amix" in c[c.index("-filter_complex") + 1]][0]]
        self.assertIn(str(clip), mix)
        self.assertIn("volume=0.35", mix[mix.index("-filter_complex") + 1])

    def test_relative_work_dir_writes_a_concat_list_ffmpeg_can_resolve(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name).resolve()
        (base / "edl.json").write_text(json.dumps([title("a"), title("b")]))
        probe = {"format": {"duration": "8.0"}, "streams": [
            {"codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080},
            {"codec_type": "audio", "codec_name": "aac"}]}
        runner = FakeRunner({(lambda c: c[0] == "ffprobe" and "json" in c): json.dumps(probe)})
        with working_directory(base):
            args = assemble.parse_args(["--edl", "edl.json", "--work-dir", "build/work", "--out", "out/draft.mp4",
                                        "--contact-sheet", "out/sheet.png", "--no-voiceover"])
            with mock.patch.object(assemble.shutil, "which", return_value="/bin/x"), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(assemble.assemble(args, runner), 0)
        list_file = base / "build/work/segments.txt"
        entries = [concat_entry_path(l) for l in list_file.read_text().splitlines()]
        rendered = [base / c[-1] for c in runner.log if c[0] == "ffmpeg" and "/segments/" in c[-1]]
        self.assertEqual(len(entries), 2)
        for entry, segment in zip(entries, rendered):
            self.assertTrue(Path(entry).is_absolute(), entry)
            # What ffmpeg opens: the entry joined onto the list file's directory.
            self.assertEqual((list_file.parent / entry).resolve(), segment.resolve())

    def test_missing_tool_exits_127(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        edl = Path(tmp.name) / "edl.json"
        edl.write_text(json.dumps([title("c")]))
        args = assemble.parse_args(["--edl", str(edl), "--work-dir", tmp.name])
        with mock.patch.object(assemble.shutil, "which", return_value=None), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(assemble.assemble(args, FakeRunner()), 127)

    def test_main_reports_command_failures(self):
        with mock.patch.object(assemble, "assemble", side_effect=RuntimeError("boom")), \
                contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(assemble.main(["--validate-only"]), 1)
        self.assertIn("boom", err.getvalue())

    def test_missing_edl_file(self):
        args = assemble.parse_args(["--edl", "/nonexistent/edl.json"])
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(assemble.assemble(args, FakeRunner()), 2)

    def test_default_edl_is_the_shipped_one(self):
        self.assertEqual(assemble.default_edl(), ROOT / "tool/video/edl.json")


if __name__ == "__main__":
    unittest.main()
