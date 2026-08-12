#!/bin/zsh
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  print -u2 "Usage: ./run.sh INPUT_FOLDER [OUTPUT_FOLDER]"
  exit 2
fi

project_dir="${0:A:h}"
swift run --package-path "$project_dir" -c release daily-select "$@"
