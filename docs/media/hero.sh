#!/usr/bin/env bash
# Draws docs/media/hero.png: four columns of four waveform strips (drums, bass, other, vocals), lit as the share of
# working agents grows: drums only, drums + bass, all but vocals, all four.
#
# Usage: docs/media/hero.sh <dir with stem-drums.wav stem-bass.wav stem-other.wav stem-vocals.wav> [out.png]
#
# The directory is four stereo WAVs of the same stretch of a song, about 30 s. The repo does not write them in one
# step. Its pieces: `stemmix --record <bundle-prefix> <path> <seconds> [skip]` (daemon/Sources/stemmix/Probe.swift)
# writes the player's audio as raw float32, and the separator (separator/stemmix_separator.py, the pipe protocol in
# contract/README.md) turns a window of audio into stems. Writing each stem out as a WAV is up to you.
#
# Needs ffmpeg, which draws the waveforms and composes the picture, and awk, which draws the text as small bitmaps
# (the ffmpeg builds that ship without drawtext cannot print text). Writes only the output file and a temp dir.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <stem dir> [out.png]" >&2
  exit 64
fi
stems_dir=$1
here=$(dirname "$0")
out=${2:-$here/hero.png}

names="drums bass other vocals"
for n in $names; do
  [ -f "$stems_dir/stem-$n.wav" ] || { echo "missing $stems_dir/stem-$n.wav" >&2; exit 66; }
done
command -v ffmpeg >/dev/null || { echo "ffmpeg not found" >&2; exit 69; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Layout, in pixels of the 1440-wide picture (README shows it at 720).
W=1440; H=536
LABEL_X=40; COL_X0=210; COL_W=285; COL_GAP=20
STRIP_H=64; STRIP_GAP=12; TOP=40
PX=4                                  # one font dot is PX pixels
CAPTION_Y=$((TOP + 4 * STRIP_H + 3 * STRIP_GAP + 24))
LINE_H=$((9 * PX + 10))
FOOTER_Y=$((CAPTION_Y + 2 * LINE_H + 12))

BG=0x14161a; PANEL=0x1c1f26; DIM=0x555b66
rgb_drums="255 159 67"; rgb_bass="76 201 240"; rgb_other="167 139 250"; rgb_vocals="255 107 154"
rgb_caption="232 232 234"; rgb_footer="138 144 155"

# 5x9 dot font, lowercase only: a glyph, then its nine rows.
FONT='a ..... ..... .###. ....# .#### #...# .#### ..... .....
b #.... #.... #.##. ##..# #...# ##..# #.##. ..... .....
c ..... ..... .###. #...# #.... #...# .###. ..... .....
d ....# ....# .##.# #..## #...# #..## .##.# ..... .....
e ..... ..... .###. #...# ##### #.... .###. ..... .....
f ..##. .#..# .#... ###.. .#... .#... .#... ..... .....
g ..... ..... .#### #...# #...# #...# .#### ....# .###.
h #.... #.... #.##. ##..# #...# #...# #...# ..... .....
i ..#.. ..... .##.. ..#.. ..#.. ..#.. .###. ..... .....
j ...#. ..... ..##. ...#. ...#. ...#. ...#. #..#. .##..
k #.... #.... #..#. #.#.. ##... #.#.. #..#. ..... .....
l .##.. ..#.. ..#.. ..#.. ..#.. ..#.. .###. ..... .....
m ..... ..... ##.#. #.#.# #.#.# #.#.# #.#.# ..... .....
n ..... ..... #.##. ##..# #...# #...# #...# ..... .....
o ..... ..... .###. #...# #...# #...# .###. ..... .....
p ..... ..... #.##. ##..# #...# #...# ####. #.... #....
q ..... ..... .##.# #..## #...# #...# .#### ....# ....#
r ..... ..... #.##. ##..# #.... #.... #.... ..... .....
s ..... ..... .#### #.... .###. ....# ####. ..... .....
t .#... .#... ###.. .#... .#... .#..# ..##. ..... .....
u ..... ..... #...# #...# #...# #..## .##.# ..... .....
v ..... ..... #...# #...# #...# .#.#. ..#.. ..... .....
w ..... ..... #...# #...# #.#.# #.#.# .#.#. ..... .....
x ..... ..... #...# .#.#. ..#.. .#.#. #...# ..... .....
y ..... ..... #...# #...# #...# .#### ....# #...# .###.
z ..... ..... ##### ...#. ..#.. .#... ##### ..... .....'

# text_ppm <out.ppm> <text> "<r g b>": the text as a 5x9-dot bitmap, black where there is no ink.
text_ppm() {
  FONT="$FONT" awk -v text="$2" -v color="$3" 'BEGIN {
    n = split(ENVIRON["FONT"], lines, "\n")
    for (i = 1; i <= n; i++) {
      split(lines[i], f, " ")
      for (r = 1; r <= 9; r++) glyph[f[1], r] = f[r + 1]
    }
    len = length(text)
    printf "P3\n%d 9\n255\n", len * 6 - 1
    for (r = 1; r <= 9; r++) {
      for (c = 1; c <= len; c++) {
        ch = substr(text, c, 1)
        row = (ch == " ") ? "....." : glyph[ch, r]
        if (row == "") { print "no glyph for \"" ch "\"" > "/dev/stderr"; exit 1 }
        for (x = 1; x <= 5; x++) printf "%s ", (substr(row, x, 1) == "#") ? color : "0 0 0"
        if (c < len) printf "0 0 0 "
      }
      printf "\n"
    }
  }' > "$1"
}

hex() { printf '0x%02x%02x%02x' "$@"; }
text_width() { echo $(( (${#1} * 6 - 1) * PX )); }

# The recording can start and end in silence (the separator runs a few seconds behind the music); every strip
# shows the same span, from where the four stems together first sound to where they last do.
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$stems_dir/stem-drums.wav")
span=$(ffmpeg -nostats \
  -i "$stems_dir/stem-drums.wav" -i "$stems_dir/stem-bass.wav" -i "$stems_dir/stem-other.wav" -i "$stems_dir/stem-vocals.wav" \
  -filter_complex "amix=inputs=4:normalize=0,silencedetect=n=-55dB:d=0.3" -f null - 2>&1 |
  awk -v dur="$dur" '
    /silence_start/ { s = $5; if (!seen) first_start = s; last_start = s; seen = 1 }
    /silence_end/   { e = $5; if (!first_end) first_end = e; last_end = e }
    END {
      from = (seen && first_start + 0 == 0) ? first_end : 0
      to = (seen && last_end + 0 >= dur - 0.05) ? last_start : dur
      print from, to
    }')
from=${span% *}; to=${span#* }

# One lit and one dim strip per stem, each scaled so its loudest peak reaches full height.
for n in $names; do
  trim="atrim=start=$from:end=$to,asetpts=PTS-STARTPTS"
  peak=$(ffmpeg -nostats -i "$stems_dir/stem-$n.wav" -af "$trim,volumedetect" -f null - 2>&1 | sed -n 's/.*max_volume: \(-\{0,1\}[0-9.]*\) dB.*/\1/p')
  gain=$(awk -v p="${peak:-0}" 'BEGIN { printf "%.2f", -p }')
  eval "rgb=\$rgb_$n"
  lit=$(hex $rgb)
  for kind in lit dim; do
    if [ "$kind" = lit ]; then color=$lit; else color=$DIM; fi
    ffmpeg -v error -y -i "$stems_dir/stem-$n.wav" \
      -filter_complex "$trim,volume=${gain}dB,showwavespic=s=${COL_W}x${STRIP_H}:colors=${color}|${color}:scale=sqrt" \
      -frames:v 1 "$work/strip-$kind-$n.png"
  done
done

inputs=(-f lavfi -i "color=c=$BG:s=${W}x${H}:d=1")
graph=""
count=0
last="bg"

# Panels behind every strip.
boxes=""
for col in 0 1 2 3; do
  for row in 0 1 2 3; do
    x=$((COL_X0 + col * (COL_W + COL_GAP)))
    y=$((TOP + row * (STRIP_H + STRIP_GAP)))
    boxes="${boxes},drawbox=x=$x:y=$y:w=$COL_W:h=$STRIP_H:color=$PANEL:t=fill"
  done
done
graph="[0:v]format=rgba${boxes}[bg];"

# overlay <input file> <x> <y> [text: scale and key out the black]
overlay() {
  count=$((count + 1))
  inputs+=(-i "$1")
  if [ "${4:-}" = text ]; then
    graph="${graph}[$count:v]format=rgba,scale=iw*$PX:ih*$PX:flags=neighbor,colorkey=0x000000:0.01:0[t$count];"
    graph="${graph}[$last][t$count]overlay=$2:$3[o$count];"
  else
    graph="${graph}[$last][$count:v]overlay=$2:$3[o$count];"
  fi
  last="o$count"
}

# Strips: column c lights the first c+1 stems.
for col in 0 1 2 3; do
  row=0
  for n in $names; do
    if [ "$row" -le "$col" ]; then kind=lit; else kind=dim; fi
    overlay "$work/strip-$kind-$n.png" $((COL_X0 + col * (COL_W + COL_GAP))) $((TOP + row * (STRIP_H + STRIP_GAP)))
    row=$((row + 1))
  done
done

# Row labels, in the stem's colour.
row=0
for n in $names; do
  eval "rgb=\$rgb_$n"
  text_ppm "$work/label-$n.ppm" "$n" "$rgb"
  overlay "$work/label-$n.ppm" "$LABEL_X" $((TOP + row * (STRIP_H + STRIP_GAP) + (STRIP_H - 9 * PX) / 2)) text
  row=$((row + 1))
done

# Column captions, centred on the column; a long one breaks onto two lines.
captions=("a quarter" "half" "three|quarters" "all")
col=0
for caption in "${captions[@]}"; do
  line=0
  IFS='|' read -r -a parts <<< "$caption"
  for part in "${parts[@]}"; do
    text_ppm "$work/caption-$col-$line.ppm" "$part" "$rgb_caption"
    cx=$((COL_X0 + col * (COL_W + COL_GAP) + (COL_W - $(text_width "$part")) / 2))
    overlay "$work/caption-$col-$line.ppm" "$cx" $((CAPTION_Y + line * LINE_H)) text
    line=$((line + 1))
  done
  col=$((col + 1))
done

# One line under all four columns that completes each caption.
footer="of your agents working"
text_ppm "$work/footer.ppm" "$footer" "$rgb_footer"
overlay "$work/footer.ppm" $(( (W - $(text_width "$footer")) / 2 )) "$FOOTER_Y" text

mkdir -p "$(dirname "$out")"
ffmpeg -v error -y "${inputs[@]}" -filter_complex "${graph%;}" -map "[$last]" -frames:v 1 "$out"
echo "wrote $out"
