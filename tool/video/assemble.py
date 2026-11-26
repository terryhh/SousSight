#!/usr/bin/env python3
"""Assemble the SousSight demo draft from an edit decision list (EDL).

    python3 -I tool/video/assemble.py [--edl tool/video/edl.json] [--dry-run]

Standard library only. Shells out to ffmpeg/ffprobe, to node for the cards
(tool/video/titles.mjs: title cards, caption overlays, placeholder cards and
the contact sheet) and to macOS `say` for the DRAFT voice-over.

Per segment, in EDL order:
  capture  build/video/capture/<viewport>/<journey_step>.mp4 (from capture.mjs),
           trimmed to the segment, or held on its last frame when short. A
           missing clip becomes a "Capture missing" card.
  terry    tool/video/input/terry/<slot>.mp4|.mov when Terry has dropped it in,
           otherwise a "Terry clip: <slot> — <instructions>" card. Its own sound
           is kept quietly under the voice-over.
  title    the title card PNG.
Captions are burned in as PNG overlays (the Homebrew ffmpeg has neither
drawtext nor subtitles). Voice-over: tool/video/input/voiceover.wav|.m4a if
present, otherwise one `say` clip per segment placed at the segment's start
and clearly a draft. Output: build/video/soussight-demo-draft.mp4 (H.264/AAC,
1920x1080, 30 fps, hard limit 3:00) and a contact sheet with one frame per
segment.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

VIDEO_DIR = Path(__file__).resolve().parent
REPO = VIDEO_DIR.parent.parent

WIDTH, HEIGHT, FPS = 1920, 1080, 30
MAX_EDL_SECONDS = 175.0
HARD_MAX_SECONDS = 180.0
START_TOLERANCE_S = 0.5
SOURCES = ("capture", "terry", "title")
NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
CLIP_EXTENSIONS = (".mp4", ".mov", ".MP4", ".MOV", ".m4v")
VOICEOVER_NAMES = ("voiceover.wav", "voiceover.m4a")
TERRY_AUDIO_VOLUME = 0.35
DRAFT_VOICE = "Samantha"
DRAFT_RATE_WPM = 170
MAX_RATE_WPM = 215
PAPER = "0xf5f1e8"
X264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p", "-r", str(FPS)]


def load_journey(path: Path = VIDEO_DIR / "journey_steps.json") -> Tuple[Tuple[str, ...], Tuple[str, ...]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    return tuple(data["steps"]), tuple(data["viewports"])


# --------------------------------------------------------------------------- timeline


def parse_timecode(value) -> float:
    """Seconds from a number, "SS(.s)", "M:SS(.s)" or "H:MM:SS(.s)"."""
    if isinstance(value, bool):
        raise ValueError(f"not a timecode: {value!r}")
    if isinstance(value, (int, float)):
        if value < 0:
            raise ValueError(f"negative timecode: {value!r}")
        return float(value)
    if not isinstance(value, str) or not re.fullmatch(r"\d+(:\d{1,2}){0,2}(\.\d+)?", value.strip()):
        raise ValueError(f"not a timecode: {value!r}")
    parts = value.strip().split(":")
    seconds = 0.0
    for i, part in enumerate(parts):
        number = float(part)
        if i > 0 and number >= 60:
            raise ValueError(f"not a timecode: {value!r}")
        seconds = seconds * 60 + number
    return seconds


def format_timecode(seconds: float) -> str:
    minutes, rest = divmod(max(0.0, seconds), 60)
    return f"{int(minutes)}:{rest:04.1f}"


def frames_for(duration_s: float) -> int:
    return max(1, int(round(duration_s * FPS)))


@dataclass(frozen=True)
class Placed:
    """A segment placed on the timeline. Times are frame-exact at FPS."""

    index: int
    seg: dict
    start_frame: int
    frames: int

    @property
    def id(self) -> str:
        return str(self.seg["id"])

    @property
    def start(self) -> float:
        return self.start_frame / FPS

    @property
    def duration(self) -> float:
        return self.frames / FPS

    @property
    def end(self) -> float:
        return (self.start_frame + self.frames) / FPS


def build_timeline(segments: Sequence[dict]) -> List[Placed]:
    """Places segments back to back. Each duration is rounded to whole frames,
    and starts come from the running frame count (declared starts are only
    checked, never trusted), so the cut never drifts."""
    placed, cursor = [], 0
    for i, seg in enumerate(segments):
        frames = frames_for(float(seg["duration_s"]))
        placed.append(Placed(i, seg, cursor, frames))
        cursor += frames
    return placed


def total_seconds(timeline: Sequence[Placed]) -> float:
    return timeline[-1].end if timeline else 0.0


# --------------------------------------------------------------------------- validation


def _text(seg: dict, key: str) -> Optional[str]:
    value = seg.get(key)
    return value.strip() if isinstance(value, str) and value.strip() else None


def validate_edl(data, steps: Sequence[str], viewports: Sequence[str]) -> Tuple[List[str], List[str]]:
    """Returns (errors, warnings). Any error means the EDL must not be used."""
    errors: List[str] = []
    warnings: List[str] = []
    if not isinstance(data, list) or not data:
        return ["the EDL must be a non-empty JSON array of segments"], warnings
    seen_ids = set()
    total = 0.0
    for i, seg in enumerate(data):
        where = f"segment {i + 1}"
        if not isinstance(seg, dict):
            errors.append(f"{where}: must be an object")
            continue
        seg_id = seg.get("id")
        if not isinstance(seg_id, str) or not NAME_RE.match(seg_id):
            errors.append(f"{where}: id must be letters, digits, '.', '_' or '-' (got {seg_id!r})")
        else:
            where = f"segment {seg_id}"
            if seg_id in seen_ids:
                errors.append(f"{where}: duplicate id")
            seen_ids.add(seg_id)
        duration = seg.get("duration_s")
        if isinstance(duration, bool) or not isinstance(duration, (int, float)) or not duration > 0:
            errors.append(f"{where}: duration_s must be a positive number (got {duration!r})")
            duration = 0.0
        elif duration > 60:
            warnings.append(f"{where}: {duration} s is a very long single segment")
        source = seg.get("source")
        if source not in SOURCES:
            errors.append(f"{where}: source must be one of {', '.join(SOURCES)} (got {source!r})")
        elif source == "capture":
            cap = seg.get("capture")
            if not isinstance(cap, dict):
                errors.append(f"{where}: capture segments need capture: {{journey_step, viewport}}")
            else:
                if cap.get("journey_step") not in steps:
                    errors.append(f"{where}: unknown journey_step {cap.get('journey_step')!r} (known: {', '.join(steps)})")
                if cap.get("viewport") not in viewports:
                    errors.append(f"{where}: viewport must be one of {', '.join(viewports)} (got {cap.get('viewport')!r})")
                in_s = cap.get("in_s", 0)
                if isinstance(in_s, bool) or not isinstance(in_s, (int, float)) or in_s < 0:
                    errors.append(f"{where}: capture.in_s must be a number >= 0 (got {in_s!r})")
        elif source == "terry":
            slot = seg.get("terry_clip")
            if not isinstance(slot, str) or not NAME_RE.match(slot):
                errors.append(f"{where}: terry_clip must be a slot name of letters, digits, '.', '_' or '-' (got {slot!r})")
            if not _text(seg, "terry_instructions"):
                errors.append(f"{where}: terry_instructions must say what Terry records")
        elif source == "title":
            title = seg.get("title")
            if not isinstance(title, dict) or not isinstance(title.get("text"), str) or not title["text"].strip():
                errors.append(f"{where}: title segments need title: {{text, sub}} with non-empty text")
            elif "sub" in title and not isinstance(title["sub"], (str, type(None))):
                errors.append(f"{where}: title.sub must be text")
        for key in ("caption", "voiceover", "gate"):
            if key in seg and not isinstance(seg[key], (str, type(None))):
                errors.append(f"{where}: {key} must be text")
        if "start" in seg and seg["start"] not in (None, ""):
            try:
                declared = parse_timecode(seg["start"])
            except ValueError as error:
                errors.append(f"{where}: {error}")
            else:
                if abs(declared - total) > START_TOLERANCE_S:
                    warnings.append(
                        f"{where}: declared start {seg['start']} but the durations before it put it at "
                        f"{format_timecode(total)}; the durations win"
                    )
        total += float(duration)
    if total > MAX_EDL_SECONDS:
        errors.append(f"total duration {total:.1f} s is over the {MAX_EDL_SECONDS:.0f} s budget (3:00 hard limit minus slack)")
    return errors, warnings


# --------------------------------------------------------------------------- sources


def find_terry_clip(input_dir: Path, slot: str) -> Optional[Path]:
    for ext in CLIP_EXTENSIONS:
        candidate = input_dir / "terry" / f"{slot}{ext}"
        if candidate.is_file():
            return candidate
    return None


def find_voiceover(input_dir: Path) -> Optional[Path]:
    for name in VOICEOVER_NAMES:
        if (input_dir / name).is_file():
            return input_dir / name
    return None


@dataclass(frozen=True)
class Plan:
    """What one segment is built from. kind: clip | still."""

    placed: Placed
    kind: str
    path: Path
    in_s: float
    caption: Optional[Path]
    keep_audio: bool
    note: str


def plan_segments(timeline: Sequence[Placed], *, capture_dir: Path, input_dir: Path, cards_dir: Path) -> List[Plan]:
    plans = []
    for p in timeline:
        seg = p.seg
        caption = cards_dir / f"caption-{p.id}.png" if _text(seg, "caption") else None
        placeholder = cards_dir / f"placeholder-{p.id}.png"
        if seg["source"] == "title":
            plans.append(Plan(p, "still", cards_dir / f"title-{p.id}.png", 0.0, caption, False, "title card"))
        elif seg["source"] == "capture":
            cap = seg["capture"]
            clip = capture_dir / cap["viewport"] / f"{cap['journey_step']}.mp4"
            if clip.is_file():
                plans.append(Plan(p, "clip", clip, float(cap.get("in_s", 0)), caption, False, f"capture {cap['viewport']}/{cap['journey_step']}"))
            else:
                plans.append(Plan(p, "still", placeholder, 0.0, caption, False, f"MISSING capture {cap['viewport']}/{cap['journey_step']}"))
        else:
            clip = find_terry_clip(input_dir, seg["terry_clip"])
            if clip:
                plans.append(Plan(p, "clip", clip, 0.0, caption, True, f"terry clip {clip.name}"))
            else:
                plans.append(Plan(p, "still", placeholder, 0.0, caption, False, f"PLACEHOLDER terry slot {seg['terry_clip']}"))
    return plans


# --------------------------------------------------------------------------- commands


def segment_cmd(ffmpeg: str, plan: Plan, out: Path) -> List[str]:
    """One video-only 1080p30 H.264 segment of exactly plan.placed.frames frames.
    Stills loop; clips are scaled to fit (letterboxed on paper), trimmed from
    in_s, and held on their last frame when shorter than the segment."""
    frames = plan.placed.frames
    seconds = f"{plan.placed.duration + 1:.3f}"  # input headroom; -frames:v is exact
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y"]
    if plan.kind == "still":
        cmd += ["-loop", "1", "-framerate", str(FPS), "-t", seconds, "-i", str(plan.path)]
    elif plan.kind == "clip":
        if plan.in_s > 0:
            cmd += ["-ss", f"{plan.in_s:.3f}"]
        cmd += ["-i", str(plan.path)]
    else:
        raise ValueError(f"unknown plan kind: {plan.kind}")
    fit = (
        f"fps={FPS},scale={WIDTH}:{HEIGHT}:force_original_aspect_ratio=decrease,"
        f"pad={WIDTH}:{HEIGHT}:(ow-iw)/2:(oh-ih)/2:color={PAPER},setsar=1"
    )
    if plan.kind == "clip":
        fit += f",tpad=stop_mode=clone:stop_duration={plan.placed.duration + 1:.3f}"
    graph = f"[0:v]{fit}[base]"
    if plan.caption:
        cmd += ["-loop", "1", "-framerate", str(FPS), "-t", seconds, "-i", str(plan.caption)]
        graph += ";[base][1:v]overlay=0:0:format=auto[capd];[capd]format=yuv420p[v]"
    else:
        graph += ";[base]format=yuv420p[v]"
    cmd += ["-filter_complex", graph, "-map", "[v]", "-frames:v", str(frames), "-an", *X264, str(out)]
    return cmd


def concat_list_line(segment: Path) -> str:
    """One line of an ffmpeg concat list. ffmpeg resolves relative entries
    against the list file's own directory, not the working directory, so the
    path is made absolute; single quotes are escaped as ffmpeg's concat
    demuxer expects ('\\'' closes the quote, adds a literal ', reopens it)."""
    path = Path(segment).resolve().as_posix()
    return "file '" + path.replace("'", "'\\''") + "'"


def concat_cmd(ffmpeg: str, list_file: Path, out: Path) -> List[str]:
    return [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0",
            "-i", str(list_file), "-c", "copy", str(out)]


@dataclass(frozen=True)
class AudioCue:
    """An audio file placed at [at] seconds, cut to [length] seconds (None =
    whole file), starting [in_s] into the file, at [volume]."""

    path: Path
    at: float
    length: Optional[float] = None
    in_s: float = 0.0
    volume: float = 1.0


def mix_cmd(ffmpeg: str, body: Path, cues: Sequence[AudioCue], total: float, out: Path) -> List[str]:
    """Final mux: the concatenated video plus every audio cue, each delayed to
    its start and mixed over silence of the full length."""
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(body),
           "-f", "lavfi", "-t", f"{total:.3f}", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000"]
    parts, labels = [], ["[1:a]"]
    for n, cue in enumerate(cues):
        if cue.in_s > 0:
            cmd += ["-ss", f"{cue.in_s:.3f}"]
        if cue.length is not None:
            cmd += ["-t", f"{cue.length:.3f}"]
        cmd += ["-i", str(cue.path)]
        delay = int(round(cue.at * 1000))
        parts.append(
            f"[{n + 2}:a]aresample=48000,aformat=channel_layouts=stereo,volume={cue.volume:g},"
            f"adelay={delay}|{delay}[c{n}]"
        )
        labels.append(f"[c{n}]")
    parts.append(f"{''.join(labels)}amix=inputs={len(labels)}:normalize=0:duration=first,alimiter=limit=0.95[aout]")
    cmd += ["-filter_complex", ";".join(parts), "-map", "0:v", "-map", "[aout]", "-c:v", "copy",
            "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-t", f"{total:.3f}", "-movflags", "+faststart", str(out)]
    return cmd


def say_cmd(text_file: Path, out: Path, *, voice: Optional[str], rate: int) -> List[str]:
    cmd = ["say"]
    if voice:
        cmd += ["-v", voice]
    return cmd + ["-r", str(rate), "-f", str(text_file), "-o", str(out)]


def frame_cmd(ffmpeg: str, video: Path, at: float, out: Path) -> List[str]:
    return [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-ss", f"{at:.3f}", "-i", str(video),
            "-frames:v", "1", "-vf", "scale=640:-2", str(out)]


def vo_windows(timeline: Sequence[Placed]) -> Dict[str, float]:
    """Seconds each segment's voice-over may run before the next voice-over
    starts (or the video ends)."""
    voiced = [p for p in timeline if _text(p.seg, "voiceover")]
    end = total_seconds(timeline)
    windows = {}
    for i, p in enumerate(voiced):
        limit = voiced[i + 1].start if i + 1 < len(voiced) else end
        windows[p.id] = limit - p.start
    return windows


def faster_rate(rate: int, spoken: float, window: float) -> Optional[int]:
    """A faster `say` rate that fits [spoken] seconds into [window], or None if
    it already fits. Capped at MAX_RATE_WPM."""
    if spoken <= window or window <= 0:
        return None
    return min(MAX_RATE_WPM, int(rate * spoken / max(window - 0.3, 0.5)) + 1)


def check_output(probe: dict) -> List[str]:
    """Problems with the exported file, from ffprobe's JSON."""
    problems = []
    duration = float(probe.get("format", {}).get("duration", 0) or 0)
    if duration <= 0:
        problems.append("output has no duration")
    if duration > HARD_MAX_SECONDS:
        problems.append(f"output runs {duration:.2f} s, over the 3:00 hard limit")
    streams = probe.get("streams", [])
    video = [s for s in streams if s.get("codec_type") == "video"]
    audio = [s for s in streams if s.get("codec_type") == "audio"]
    if not video or video[0].get("codec_name") != "h264":
        problems.append("video stream is not H.264")
    elif (video[0].get("width"), video[0].get("height")) != (WIDTH, HEIGHT):
        problems.append(f"video is {video[0].get('width')}x{video[0].get('height')}, not {WIDTH}x{HEIGHT}")
    if not audio or audio[0].get("codec_name") != "aac":
        problems.append("audio stream is not AAC")
    return problems


# --------------------------------------------------------------------------- running


class Runner:
    """Runs (or, dry, prints) external commands. Tests replace `run`."""

    def __init__(self, dry_run: bool = False):
        self.dry_run = dry_run
        self.log: List[List[str]] = []

    def run(self, cmd: Sequence[str], *, capture: bool = False) -> str:
        self.log.append(list(cmd))
        if self.dry_run:
            print("$ " + " ".join(_quote(c) for c in cmd))
            return ""
        done = subprocess.run(list(cmd), check=False, stdout=subprocess.PIPE if capture else None, text=True)
        if done.returncode != 0:
            raise RuntimeError(f"command failed ({done.returncode}): {' '.join(cmd[:4])} …")
        return done.stdout or ""


def _quote(arg: str) -> str:
    return arg if re.fullmatch(r"[\w@%+=:,./-]+", arg) else "'" + arg.replace("'", "'\\''") + "'"


def probe_duration(runner: Runner, ffprobe: str, path: Path) -> float:
    out = runner.run([ffprobe, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)], capture=True)
    try:
        return float(out.strip())
    except ValueError:
        return 0.0


def has_audio(runner: Runner, ffprobe: str, path: Path) -> bool:
    out = runner.run([ffprobe, "-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", str(path)], capture=True)
    return bool(out.strip())


def pick_voice(runner: Runner) -> Optional[str]:
    try:
        voices = runner.run(["say", "-v", "?"], capture=True)
    except (RuntimeError, FileNotFoundError):
        return None
    return DRAFT_VOICE if any(line.split()[:1] == [DRAFT_VOICE] for line in voices.splitlines()) else None


def draft_voiceover(runner: Runner, ffprobe: str, timeline: Sequence[Placed], work: Path, warnings: List[str]) -> List[AudioCue]:
    """One `say` clip per voiced segment, placed at the segment's start and sped
    up (to MAX_RATE_WPM at most) when it would run into the next line."""
    if not shutil.which("say") and not runner.dry_run:
        warnings.append("macOS `say` not found: the draft has no voice-over")
        return []
    voice = pick_voice(runner)
    if not voice:
        warnings.append(f"voice {DRAFT_VOICE!r} not installed; using the system default voice")
    windows = vo_windows(timeline)
    cues = []
    for p in timeline:
        text = _text(p.seg, "voiceover")
        if not text:
            continue
        text_file = work / f"vo-{p.id}.txt"
        text_file.write_text(text + "\n", encoding="utf-8")
        audio = work / f"vo-{p.id}.aiff"
        rate = DRAFT_RATE_WPM
        runner.run(say_cmd(text_file, audio, voice=voice, rate=rate))
        spoken = probe_duration(runner, ffprobe, audio)
        faster = faster_rate(rate, spoken, windows[p.id])
        if faster and faster != rate:
            runner.run(say_cmd(text_file, audio, voice=voice, rate=faster))
            spoken = probe_duration(runner, ffprobe, audio)
        if spoken > windows[p.id] + 0.05:
            warnings.append(f"voice-over for {p.id} runs {spoken:.1f} s but has {windows[p.id]:.1f} s before the next line; shorten it")
        cues.append(AudioCue(audio, p.start))
    return cues


def default_edl() -> Path:
    return VIDEO_DIR / "edl.json"


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--edl", type=Path, default=None, help="EDL JSON (default: tool/video/edl.json)")
    ap.add_argument("--capture-dir", type=Path, default=REPO / "build/video/capture")
    ap.add_argument("--input-dir", type=Path, default=VIDEO_DIR / "input")
    ap.add_argument("--work-dir", type=Path, default=REPO / "build/video/work")
    ap.add_argument("--out", type=Path, default=REPO / "build/video/soussight-demo-draft.mp4")
    ap.add_argument("--contact-sheet", type=Path, default=REPO / "build/video/soussight-demo-contact-sheet.png")
    ap.add_argument("--skip-cards", action="store_true", help="reuse cards already in <work-dir>/cards")
    ap.add_argument("--no-voiceover", action="store_true", help="no voice-over at all (not even the draft)")
    ap.add_argument("--validate-only", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="print the commands instead of running them")
    ap.add_argument("--ffmpeg", default="ffmpeg")
    ap.add_argument("--ffprobe", default="ffprobe")
    ap.add_argument("--node", default="node")
    return ap.parse_args(list(argv))


def assemble(args: argparse.Namespace, runner: Runner) -> int:
    edl_path = args.edl or default_edl()
    steps, viewports = load_journey()
    try:
        segments = json.loads(edl_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"cannot read EDL {edl_path}: {error}", file=sys.stderr)
        return 2
    errors, warnings = validate_edl(segments, steps, viewports)
    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)
    if errors:
        print(f"EDL {edl_path} is invalid:\n  " + "\n  ".join(errors), file=sys.stderr)
        return 2
    timeline = build_timeline(segments)
    total = total_seconds(timeline)
    print(f"EDL {edl_path}: {len(timeline)} segments, {format_timecode(total)}")
    if args.validate_only:
        return 0
    for tool in (args.ffmpeg, args.ffprobe, args.node):
        if not runner.dry_run and not shutil.which(tool):
            print(f"{tool} not found on PATH", file=sys.stderr)
            return 127

    work = args.work_dir
    cards = work / "cards"
    segdir = work / "segments"
    for d in (work, cards, segdir, args.out.parent, args.contact_sheet.parent):
        d.mkdir(parents=True, exist_ok=True)
    if not args.skip_cards:
        runner.run([args.node, str(VIDEO_DIR / "titles.mjs"), "--edl", str(edl_path), "--out", str(cards)])

    plans = plan_segments(timeline, capture_dir=args.capture_dir, input_dir=args.input_dir, cards_dir=cards)
    list_lines = []
    for plan in plans:
        out = segdir / f"{plan.placed.index + 1:03d}-{plan.placed.id}.mp4"
        runner.run(segment_cmd(args.ffmpeg, plan, out))
        list_lines.append(concat_list_line(out))
    list_file = work / "segments.txt"
    list_file.write_text("\n".join(list_lines) + "\n", encoding="utf-8")
    body = work / "body.mp4"
    runner.run(concat_cmd(args.ffmpeg, list_file, body))

    cues: List[AudioCue] = []
    for plan in plans:
        if plan.keep_audio and (runner.dry_run or has_audio(runner, args.ffprobe, plan.path)):
            cues.append(AudioCue(plan.path, plan.placed.start, plan.placed.duration, plan.in_s, TERRY_AUDIO_VOLUME))
    supplied = find_voiceover(args.input_dir)
    if args.no_voiceover:
        vo_source = "none"
    elif supplied:
        vo_source = f"supplied ({supplied.name})"
        cues.append(AudioCue(supplied, 0.0, total))
    else:
        vo_source = "DRAFT macOS say"
        cues += draft_voiceover(runner, args.ffprobe, timeline, work, warnings)
    runner.run(mix_cmd(args.ffmpeg, body, cues, total, args.out))

    problems: List[str] = []
    if not runner.dry_run:
        probe = json.loads(runner.run([args.ffprobe, "-v", "error", "-show_entries",
                                       "format=duration:stream=codec_type,codec_name,width,height",
                                       "-of", "json", str(args.out)], capture=True) or "{}")
        problems = check_output(probe)

    frames = []
    for plan in plans:
        p = plan.placed
        image = work / "frames" / f"{p.index + 1:03d}-{p.id}.png"
        image.parent.mkdir(parents=True, exist_ok=True)
        runner.run(frame_cmd(args.ffmpeg, args.out, p.start + p.duration / 2, image))
        frames.append({"image": str(image), "label": f"{p.id} · {format_timecode(p.start)} · {p.duration:.1f} s",
                       "detail": plan.note + (f" — “{p.seg.get('caption')}”" if _text(p.seg, "caption") else "")})
    frames_json = work / "contact-frames.json"
    frames_json.write_text(json.dumps(frames, indent=1), encoding="utf-8")
    runner.run([args.node, str(VIDEO_DIR / "titles.mjs"), "--contact-sheet", str(frames_json), "--out", str(args.contact_sheet),
                "--title", f"SousSight demo draft — {format_timecode(total)} — voice-over: {vo_source}"])

    report = {
        "edl": str(edl_path),
        "output": str(args.out),
        "contact_sheet": str(args.contact_sheet),
        "total_seconds": round(total, 3),
        "voiceover": vo_source,
        "segments": [{"id": pl.placed.id, "start": format_timecode(pl.placed.start), "duration_s": pl.placed.duration,
                      "built_from": pl.note} for pl in plans],
        "missing_terry_clips": [pl.placed.seg["terry_clip"] for pl in plans if pl.note.startswith("PLACEHOLDER")],
        "missing_captures": [pl.note.split(" ", 2)[2] for pl in plans if pl.note.startswith("MISSING")],
        "warnings": warnings,
        "problems": problems,
    }
    (args.out.parent / "assembly-report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"draft: {args.out}\ncontact sheet: {args.contact_sheet}\nvoice-over: {vo_source}")
    for w in warnings:
        print(f"warning: {w}")
    if report["missing_terry_clips"]:
        print("Terry clips still needed (drop into tool/video/input/terry/<slot>.mp4|.mov): " + ", ".join(report["missing_terry_clips"]))
    if report["missing_captures"]:
        print("captures missing (placeholder cards used): " + ", ".join(report["missing_captures"]))
    if problems:
        print("OUTPUT CHECK FAILED:\n  " + "\n  ".join(problems), file=sys.stderr)
        return 3
    return 0


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    try:
        return assemble(args, Runner(dry_run=args.dry_run))
    except RuntimeError as error:
        print(f"assemble.py: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
