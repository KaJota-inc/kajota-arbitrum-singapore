#!/usr/bin/env bash
# dryrun.sh — exercise the full recording pipeline against dummy inputs
# before the user records anything real.
#
# Pipeline design:
#  - User records 6 silent scene captures (any length ≥ target) + 1 continuous VO take.
#  - We detect speech beats in the VO via silencedetect.
#  - Each scene is held across its beat *and* the silence that follows,
#    so final-video length == VO length. Audio needs no trimming.
#  - Captions overlay in the VO timeline, from beat_start to beat_end.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$ROOT/dryrun"
rm -rf "$WORK" && mkdir -p "$WORK"/{scenes,vo,caps,out}

say_line() {
  local text="$1" out="$2"
  say -v Samantha -r 180 -o "$out.aiff" "$text"
  ffmpeg -y -i "$out.aiff" -c:a aac -b:a 192k "$out.m4a" >/dev/null 2>&1
  rm -f "$out.aiff"
}

LINES=(
  "Kajota Mesh is an atomic settlement primitive for commerce agents on Arbitrum."
  "USDC or USDG in, N-party split out, in one atomic release. The on-chain registry becomes the coordination surface two agents can both trust."
  "Here is the three-party happy path against the live contracts. Register, approve, deposit, release. One USDC in, split exactly twenty, thirty, fifty, atomically. Zero dust."
  "Live and verified on both Arbitrum Sepolia and Robinhood Chain testnet. The reserved-slot lane is claimed."
  "Paxos USDG wired to the same primitive on both chains, ERC-8004 agent-identity binding on top, x402 gasless deposits via EIP-3009. Seventeen contracts across two chains."
  "Everything reproducible. Primitive-first, agent-safe. Kajota Mesh, the settlement primitive for commerce agents on Arbitrum."
)

echo "=== 1. Generate 6 dummy scene captures (silent, 1920x1080, 30fps) ==="
# Deliberately recorded LONGER than target — pipeline must handle trimming.
TARGETS=(14 16 29 14 18 14)
COLORS=(blue green orange navy purple black)
for i in {0..5}; do
  ffmpeg -y -f lavfi \
    -i "color=c=${COLORS[$i]}:size=1920x1080:rate=30:duration=${TARGETS[$i]}" \
    -c:v libx264 -crf 23 -preset ultrafast -pix_fmt yuv420p \
    "$WORK/scenes/scene$((i+1)).mov" >/dev/null 2>&1
  echo "  scene$((i+1)).mov (${TARGETS[$i]}s, ${COLORS[$i]})"
done

echo
echo "=== 2. Generate VO take (6 lines + 1.2s silence between, simulates natural pacing) ==="
for i in {0..5}; do
  say_line "${LINES[$i]}" "$WORK/vo/line$((i+1))"
done
ffmpeg -y -f lavfi -i "anullsrc=channel_layout=mono:sample_rate=44100" \
  -t 1.2 -c:a aac -b:a 192k "$WORK/vo/gap.m4a" >/dev/null 2>&1

: > "$WORK/vo/list.txt"
for i in {1..6}; do
  echo "file '$WORK/vo/line$i.m4a'" >> "$WORK/vo/list.txt"
  [ "$i" -lt 6 ] && echo "file '$WORK/vo/gap.m4a'" >> "$WORK/vo/list.txt"
done
ffmpeg -y -f concat -safe 0 -i "$WORK/vo/list.txt" -c copy \
  "$WORK/vo/vo-take.m4a" >/dev/null 2>&1
VO_DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$WORK/vo/vo-take.m4a")
echo "  VO take: ${VO_DUR}s"

echo
echo "=== 3. Convert VO to 16k mono WAV for whisper + silencedetect ==="
ffmpeg -y -i "$WORK/vo/vo-take.m4a" -ar 16000 -ac 1 -c:a pcm_s16le \
  "$WORK/vo/vo-take.wav" >/dev/null 2>&1

echo
echo "=== 4. Detect silence boundaries (-32dB, >= 0.6s) ==="
ffmpeg -i "$WORK/vo/vo-take.wav" -af "silencedetect=noise=-32dB:d=0.6" -f null - 2>&1 | \
  grep -E "silence_(start|end)" | tee "$WORK/vo/silences.txt"

python3 - <<PY
import re, json, subprocess
lines = open("$WORK/vo/silences.txt").read().splitlines()
starts, ends = [], []
for ln in lines:
    m = re.search(r"silence_start:\s*([\d.]+)", ln)
    if m: starts.append(float(m.group(1)))
    m = re.search(r"silence_end:\s*([\d.]+)", ln)
    if m: ends.append(float(m.group(1)))

vo_dur = float(subprocess.check_output([
    "ffprobe", "-v", "error", "-show_entries", "format=duration",
    "-of", "default=noprint_wrappers=1:nokey=1", "$WORK/vo/vo-take.wav"
]).strip())

beats = []
prev_end = 0.0
for s, e in zip(starts, ends):
    if s > prev_end + 0.1:
        beats.append({"from": prev_end, "to": s})
    prev_end = e
if vo_dur > prev_end + 0.1:
    beats.append({"from": prev_end, "to": vo_dur})

# Compute scene-boundary timeline so scene i covers beat_i AND the silence after it.
# boundary 0 = 0, boundary N = vo_dur, interior boundaries = midpoint of each gap.
boundaries = [0.0]
for i in range(len(beats) - 1):
    boundaries.append((beats[i]["to"] + beats[i+1]["from"]) / 2)
boundaries.append(vo_dur)

print(f"  Non-silent beats: {len(beats)}  (expect 6)")
for i, b in enumerate(beats):
    scene_dur = boundaries[i+1] - boundaries[i]
    print(f"    beat {i+1}: speech {b['from']:.2f}-{b['to']:.2f}s ({b['to']-b['from']:.2f}s) · scene span {boundaries[i]:.2f}-{boundaries[i+1]:.2f}s ({scene_dur:.2f}s)")

if len(beats) != 6:
    print(f"  ⚠ Found {len(beats)} beats, expected 6. Tune silence threshold or re-record pauses.")

json.dump({"beats": beats, "boundaries": boundaries, "vo_dur": vo_dur},
          open("$WORK/vo/beats.json", "w"), indent=2)
PY

echo
echo "=== 5. Trim each scene to its boundary-span (scene i covers beat i + following silence) ==="
python3 - <<PY
import json, subprocess, pathlib
data = json.load(open("$WORK/vo/beats.json"))
beats, boundaries = data["beats"], data["boundaries"]
scenes_in = sorted(pathlib.Path("$WORK/scenes").glob("scene[1-9].mov"))
if len(scenes_in) != 6 or len(beats) < 6:
    print(f"  ⚠ mismatch: {len(scenes_in)} scenes, {len(beats)} beats"); import sys; sys.exit(1)
for i, scene in enumerate(scenes_in):
    dur = boundaries[i+1] - boundaries[i]
    out = pathlib.Path("$WORK/scenes") / f"beat{i+1}-cut.mp4"
    cmd = ["ffmpeg", "-y", "-i", str(scene),
        "-vf", f"fps=30,trim=0:{dur:.3f},setpts=PTS-STARTPTS,"
               f"scale=1920:1080:force_original_aspect_ratio=decrease,"
               f"pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=0x0E0E11,setsar=1,format=yuv420p",
        "-an", "-c:v", "libx264", "-crf", "20", "-preset", "fast", str(out)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  ✗ scene {i+1} failed: {r.stderr[-200:]}"); import sys; sys.exit(1)
    probe = float(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", str(out)]).strip())
    print(f"  ✓ scene {i+1}: target {dur:.2f}s, cut {probe:.2f}s")
PY

echo
echo "=== 6. Concat scenes into one timeline (should match VO duration) ==="
: > "$WORK/concat.txt"
for i in {1..6}; do
  echo "file '$WORK/scenes/beat$i-cut.mp4'" >> "$WORK/concat.txt"
done
ffmpeg -y -f concat -safe 0 -i "$WORK/concat.txt" \
  -c:v libx264 -crf 20 -preset fast -pix_fmt yuv420p \
  "$WORK/out/video-only.mp4" >/dev/null 2>&1
VIDLEN=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$WORK/out/video-only.mp4")
echo "  Concat video length: ${VIDLEN}s  (VO was ${VO_DUR}s — should match within ~0.1s)"

echo
echo "=== 7. Transcribe + apply ASR term-fix dictionary ==="
MODEL=~/.cache/whisper-cpp/ggml-base.en.bin
whisper-cli -m "$MODEL" -f "$WORK/vo/vo-take.wav" -oj --output-file "$WORK/vo/vo-take" --no-prints 2>&1 | tail -1

python3 - <<PY
import json
FIXES = {
    "Kajodamesh": "Kajota Mesh",
    "Kajota mesh": "Kajota Mesh",
    "USDGN": "USDG",
    "USDG N": "USDG",
    "ERK 8004": "ERC-8004",
    "ERC 8004": "ERC-8004",
    "Birk 8004": "ERC-8004",
    "Erk 8004": "ERC-8004",
    "Erc 8004": "ERC-8004",
    "EKE 3009": "EIP-3009",
    "EIP 3009": "EIP-3009",
    "X402": "x402",
    "end-party": "N-party",
    "Paxis": "Paxos",
    "Paxus": "Paxos",
}
data = json.load(open("$WORK/vo/beats.json"))
beats = data["beats"]
w = json.load(open("$WORK/vo/vo-take.json"))["transcription"]
for b in beats:
    bf, bt = b["from"] * 1000, b["to"] * 1000
    txt = [s["text"].strip() for s in w if bf <= (s["offsets"]["from"]+s["offsets"]["to"])/2 <= bt]
    joined = " ".join(txt)
    for bad, good in FIXES.items():
        joined = joined.replace(bad, good)
    b["text"] = joined.strip()
    print(f"  beat {beats.index(b)+1}: \"{joined[:72]}\"")
data["beats"] = beats
json.dump(data, open("$WORK/vo/beats.json", "w"), indent=2)
PY

echo
echo "=== 8. Render PIL caption PNGs ==="
python3 - <<PY
import json, textwrap
from PIL import Image, ImageDraw, ImageFont
data = json.load(open("$WORK/vo/beats.json"))
font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 34)
for i, b in enumerate(data["beats"][:6]):
    img = Image.new("RGBA", (1920, 1080), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    lines = textwrap.wrap(b["text"] or f"beat {i+1}", width=72)
    pad_x, pad_y, line_h = 42, 20, 46
    text_widths = [draw.textlength(l, font=font) for l in lines]
    bar_w = min(1800, int(max(text_widths)) + pad_x * 2)
    bar_h = pad_y * 2 + line_h * len(lines)
    x0 = (1920 - bar_w) // 2
    y0 = 1080 - bar_h - 70
    draw.rounded_rectangle([x0, y0, x0+bar_w, y0+bar_h], radius=18, fill=(14,14,17,220))
    for j, line in enumerate(lines):
        lw = draw.textlength(line, font=font)
        draw.text(((1920-lw)//2, y0+pad_y+j*line_h), line, font=font, fill=(255,255,255,255))
    img.save(f"$WORK/caps/cap{i+1}.png")
    print(f"  cap{i+1}.png")
PY

echo
echo "=== 9. Build caption overlay filter graph + mux VO ==="
# Captions enable from beat.from to beat.to in the VO timeline, which == final video timeline.
python3 - > "$WORK/filter.txt" <<PY
import json
data = json.load(open("$WORK/vo/beats.json"))
beats = data["beats"][:6]
parts, prev = [], "0:v"
for i, b in enumerate(beats):
    nxt = f"v{i+1}"
    parts.append(f"[{i+1}:v]format=rgba[c{i+1}];"
                 f"[{prev}][c{i+1}]overlay=0:0:enable='between(t,{b['from']:.3f},{b['to']:.3f})'[{nxt}]")
    prev = nxt
print(";".join(parts) + f";[{prev}]null[vout]")
PY
FILTER=$(cat "$WORK/filter.txt")
echo "  filter graph: $(echo "$FILTER" | wc -c | tr -d ' ') chars"

INPUTS=(-i "$WORK/out/video-only.mp4")
for i in {1..6}; do
  INPUTS+=(-loop 1 -t 2 -i "$WORK/caps/cap$i.png")
done
INPUTS+=(-i "$WORK/vo/vo-take.m4a")

ffmpeg -y "${INPUTS[@]}" \
  -filter_complex "$FILTER" \
  -map "[vout]" -map 7:a \
  -c:v libx264 -crf 20 -preset fast -pix_fmt yuv420p \
  -c:a aac -b:a 192k \
  -t "$VIDLEN" \
  "$WORK/out/final.mp4" 2>&1 | tail -3

echo
echo "=== 10. Verify final ==="
if [ -f "$WORK/out/final.mp4" ]; then
  FINAL_DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$WORK/out/final.mp4")
  FINAL_SIZE=$(du -h "$WORK/out/final.mp4" | awk '{print $1}')
  echo "  File:     $WORK/out/final.mp4"
  echo "  Duration: ${FINAL_DUR}s"
  echo "  Size:     $FINAL_SIZE"
  if python3 -c "import sys; sys.exit(0 if float('$FINAL_DUR') <= 90 else 1)"; then
    echo "  ✅ under 90s cap"
  else
    echo "  ⚠ over 90s cap — content trim needed, NOT atempo"
  fi
else
  echo "  ✗ final.mp4 was not produced"
  exit 1
fi
