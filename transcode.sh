#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat << 'EOF'
Usage: 
  ./transcode.sh -i <input_video> [options]    # Transcode video
  ./transcode.sh -c <file_to_check>           # Verify file compatibility only

Options:
  -i <file>        Input video file (any container: .mkv, .avi, .mov, .webm, etc.)
  -o <file>        Output MP4 path (default: <input_dir>/<input_name>_web.mp4)
  -s <file>        Burn external subtitles file (.srt, .ass, .vtt)
  -e [index]       Burn embedded subtitle track (default: 0 = first subtitle stream)
  -c, --check <f>  Verify web compatibility of an existing video file and exit
  -h, --help       Show this help message

Examples:
  ./transcode.sh -i movie.mkv                          # Standard conversion
  ./transcode.sh -i movie.mkv -s subs.srt              # Burn external subtitles
  ./transcode.sh -i movie.mkv -e                       # Burn first embedded subtitle track
  ./transcode.sh -i movie.mkv -e 1 -o stream.mp4       # Burn embedded track 1 to custom file
  ./transcode.sh -c ~/Videos/stream.mp4                # Check compatibility of any file
EOF
  exit 1
}

# Verify web streaming compliance using ffprobe
verify_file() {
  local target="$1"

  if ! command -v ffprobe >/dev/null 2>&1; then
    echo "Error: 'ffprobe' is not installed or not in PATH." >&2
    return 1
  fi

  if [[ ! -f "$target" ]]; then
    echo "Error: File does not exist: $target" >&2
    return 1
  fi

  echo "=================================================="
  echo " Verifying Web Compatibility: $(basename "$target")"
  echo "=================================================="

  local probe_v probe_a
  probe_v=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,pix_fmt -of default=noprintwrappers=1 "$target" 2>/dev/null || true)
  probe_a=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,channels -of default=noprintwrappers=1 "$target" 2>/dev/null || true)

  local v_codec pix_fmt a_codec channels
  v_codec=$(echo "$probe_v" | grep '^codec_name=' | head -n1 | cut -d= -f2 || true)
  pix_fmt=$(echo "$probe_v" | grep '^pix_fmt=' | head -n1 | cut -d= -f2 || true)
  a_codec=$(echo "$probe_a" | grep '^codec_name=' | head -n1 | cut -d= -f2 || true)
  channels=$(echo "$probe_a" | grep '^channels=' | head -n1 | cut -d= -f2 || true)

  local pass=true

  printf "  • Video Codec:  %-10s (Required: h264)\n" "${v_codec:-none}"
  [[ "${v_codec:-}" != "h264" ]] && pass=false

  printf "  • Pixel Format: %-10s (Required: yuv420p)\n" "${pix_fmt:-none}"
  [[ "${pix_fmt:-}" != "yuv420p" ]] && pass=false

  printf "  • Audio Codec:  %-10s (Required: aac)\n" "${a_codec:-none}"
  [[ "${a_codec:-}" != "aac" ]] && pass=false

  printf "  • Channels:     %-10s (Required: 2)\n" "${channels:-none}"
  [[ "${channels:-}" != "2" ]] && pass=false

  echo "--------------------------------------------------"
  if [[ "$pass" == true ]]; then
    echo " Status: READY (Matches universal web streaming standard)"
    echo "=================================================="
    return 0
  else
    echo " Status: INCOMPATIBLE (Will fail or trigger black screen in browsers)"
    echo "=================================================="
    return 1
  fi
}

INPUT=""
OUTPUT=""
SUB_FILE=""
EMBEDDED_INDEX=""
CHECK_ONLY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i)
      [[ $# -ge 2 ]] || { echo "Error: -i requires a file argument." >&2; usage; }
      INPUT="$2"
      shift 2
      ;;
    -o)
      [[ $# -ge 2 ]] || { echo "Error: -o requires a file argument." >&2; usage; }
      OUTPUT="$2"
      shift 2
      ;;
    -s)
      [[ $# -ge 2 ]] || { echo "Error: -s requires a file argument." >&2; usage; }
      SUB_FILE="$2"
      shift 2
      ;;
    -e)
      if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        EMBEDDED_INDEX="$2"
        shift 2
      else
        EMBEDDED_INDEX="0"
        shift 1
      fi
      ;;
    -c|--check)
      [[ $# -ge 2 ]] || { echo "Error: $1 requires a file argument." >&2; usage; }
      CHECK_ONLY="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

# Standalone check mode
if [[ -n "$CHECK_ONLY" ]]; then
  if verify_file "$CHECK_ONLY"; then
    exit 0
  else
    exit 1
  fi
fi

# Validation for transcoding mode
if [[ -z "$INPUT" ]]; then
  echo "Error: Missing input file (-i) or check target (-c)." >&2
  usage
fi

if [[ ! -f "$INPUT" ]]; then
  echo "Error: Input file does not exist: $INPUT" >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: 'ffmpeg' is not installed or not in PATH." >&2
  exit 1
fi

# Determine default output name (<dir>/<name>_web.mp4)
if [[ -z "$OUTPUT" ]]; then
  DIRNAME=$(dirname "$INPUT")
  FILENAME=$(basename "$INPUT")
  BASENAME="${FILENAME%.*}"
  OUTPUT="${DIRNAME}/${BASENAME}_web.mp4"
fi

# Build subtitle filter
SUB_FILTER=""
if [[ -n "$SUB_FILE" ]]; then
  if [[ ! -f "$SUB_FILE" ]]; then
    echo "Error: Subtitle file not found: $SUB_FILE" >&2
    exit 1
  fi
  ESCAPED_SUB=$(echo "$SUB_FILE" | sed -e 's/\\/\\\\/g' -e "s/'/'\\\\''/g" -e 's/:/\\:/g')
  SUB_FILTER="subtitles='${ESCAPED_SUB}'"
elif [[ -n "$EMBEDDED_INDEX" ]]; then
  ESCAPED_IN=$(echo "$INPUT" | sed -e 's/\\/\\\\/g' -e "s/'/'\\\\''/g" -e 's/:/\\:/g')
  SUB_FILTER="subtitles='${ESCAPED_IN}':si=${EMBEDDED_INDEX}"
fi

# Assemble FFmpeg execution arguments
FFMPEG_CMD=(
  ffmpeg -y
  -i "$INPUT"
  -map 0:v:0
  -map 0:a:0?
)

if [[ -n "$SUB_FILTER" ]]; then
  FFMPEG_CMD+=(-vf "$SUB_FILTER")
fi

FFMPEG_CMD+=(
  -c:v libx264
  -pix_fmt yuv420p
  -preset fast
  -crf 22
  -c:a aac
  -ac 2
  -b:a 192k
  -movflags +faststart
  "$OUTPUT"
)

echo "==> Transcoding: $INPUT"
echo "==> Output destination: $OUTPUT"
[[ -n "$SUB_FILTER" ]] && echo "==> Burning subtitles: $SUB_FILTER"

"${FFMPEG_CMD[@]}"

echo "==> Transcode complete. Running automatic verification..."
if verify_file "$OUTPUT"; then
  exit 0
else
  exit 1
fi
