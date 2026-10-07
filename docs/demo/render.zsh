#!/usr/bin/env zsh
# vhs renders PNG frames; ffmpeg composites and encodes them here,
# because some vhs releases finish without ever running their own encoder.
emulate -L zsh
setopt err_return
cd "${0:A:h:h:h}"
(( $+commands[vhs] && $+commands[ffmpeg] )) || { print -u2 "need vhs and ffmpeg on PATH"; exit 1; }
local -a names; names=("$@"); (( $#names )) || names=(create ai status remove)
local name frames
for name in $names; do
  frames="${WORKYTREE_DEMO_FRAMES:-${TMPDIR:-/tmp}/workytree-demo-frames}/$name"; rm -rf "$frames" "$frames.tape"
  print "recording $name"
  # vhs writes frames only through an Output line in the tape, into a directory it creates.
  { print -r -- "Source docs/demo/common.tape"; print -r -- "Output \"$frames/\""
    grep -v '^Source ' "docs/demo/$name.tape"; } > "$frames.tape"
  # Under vhs, fzf sometimes reads the terminal's reply to its startup query as keystrokes and
  # cancels or garbles that picker; each tape's Wait lines then time out, so record again.
  local -i try
  for try in 1 2 3; do
    rm -rf "$frames"
    vhs -q "$frames.tape" && break
    (( try < 3 )) || { print -u2 "$name: recording failed 3 times"; return 1; }
    print -u2 "$name: retrying"
  done
  # 50 fps is vhs's capture rate; the text and cursor layers come out as separate PNGs.
  ffmpeg -loglevel error -y -framerate 50 -i "$frames/frame-text-%05d.png" \
    -framerate 50 -i "$frames/frame-cursor-%05d.png" -filter_complex \
    "[0][1]overlay,pad=iw+48:ih+48:24:24:color=0x1e1e2e,fps=25,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=none" \
    "docs/demo/$name.gif"
  rm -rf "$frames" "$frames.tape"
done
