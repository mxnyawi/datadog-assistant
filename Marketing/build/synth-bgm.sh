#!/usr/bin/env bash
# Synthesize a tasteful ambient/corporate underscore with ffmpeg (offline, deterministic).
# Usage: synth-bgm.sh <mood> <duration> <out.wav>
#   mood: tense | urgent | uplift
set -euo pipefail
MOOD="${1:-uplift}"; DUR="${2:-17}"; OUT="${3:-bed.wav}"

# Chord voicings (Hz) + a rhythmic sub-bass pulse rate (Hz) per mood.
case "$MOOD" in
  tense)   # A minor — watchful, unresolved
    PAD="0.13*sin(2*PI*220*t)+0.12*sin(2*PI*220.5*t)+0.11*sin(2*PI*261.63*t)+0.10*sin(2*PI*329.63*t)+0.07*sin(2*PI*440*t)"
    BASSF=55; PULSE=1.30; LP=3200 ;;
  urgent)  # A minor add9 — driving, anxious
    PAD="0.13*sin(2*PI*220*t)+0.12*sin(2*PI*246.94*t)+0.11*sin(2*PI*293.66*t)+0.10*sin(2*PI*329.63*t)+0.07*sin(2*PI*440*t)"
    BASSF=55; PULSE=2.00; LP=3800 ;;
  uplift|*) # C major add9 — confident, resolved
    PAD="0.12*sin(2*PI*261.63*t)+0.12*sin(2*PI*262.1*t)+0.11*sin(2*PI*329.63*t)+0.10*sin(2*PI*392*t)+0.08*sin(2*PI*523.25*t)+0.06*sin(2*PI*587.33*t)"
    BASSF=65.41; PULSE=1.60; LP=4200 ;;
esac

# slow tremolo on the pad for movement
PAD_EXPR="(${PAD})*(0.80+0.20*sin(2*PI*0.22*t))"
# rhythmic sub-bass: soft pulses on the beat
BASS_EXPR="0.30*sin(2*PI*${BASSF}*t)*pow(max(0\,sin(2*PI*${PULSE}*t))\,3)"
# faint high "air" shimmer
AIR_EXPR="0.04*sin(2*PI*1046.5*t)*(0.5+0.5*sin(2*PI*0.5*t))"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "aevalsrc=${PAD_EXPR}:d=${DUR}:s=44100" \
  -f lavfi -i "aevalsrc=${BASS_EXPR}:d=${DUR}:s=44100" \
  -f lavfi -i "aevalsrc=${AIR_EXPR}:d=${DUR}:s=44100" \
  -filter_complex "[0:a][1:a][2:a]amix=inputs=3:normalize=0[mix];\
[mix]aecho=0.8:0.6:60|140:0.35|0.22,highpass=f=70,lowpass=f=${LP},\
afade=t=in:st=0:d=1.2,afade=t=out:st=$(echo "$DUR-1.6"|bc):d=1.6,\
acompressor=threshold=-18dB:ratio=3:attack=20:release=250,\
volume=1.6,aformat=channel_layouts=stereo" \
  -ar 44100 -ac 2 "$OUT"
echo "wrote $OUT ($MOOD, ${DUR}s)"
