#!/bin/bash
#
# afk-ralph.sh — drive an autonomous Claude agent through a PRD, one task per iteration.
#
# Runs `claude-cq` inside an `sbx` sandbox up to <iterations> times. Each iteration,
# the agent reads progress.txt, implements the highest-priority task, runs tests,
# updates the PRD, appends to progress.txt, and commits. The loop stops early when
# the agent reports the PRD is complete by emitting <promise>COMPLETE</promise>.
#
# Usage: ./afk-ralph.sh <iterations>
#
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <iterations>"
  exit 1
fi

# For some reason setting the token with `sbx secret set -g github -t "$(gh auth token)"`
# doesn't seem to work
export GH_TOKEN=$(gh auth token)

for ((i=1; i<=$1; i++)); do
  echo "Running loop $i of $1"

  if claude -p "/usage" | grep -q "100%"; then
      echo "Usage limit reached"
      exit 1
  fi

  result=$(sbx run claude-cyclepay -- --permission-mode acceptEdits -p "@progress.txt \
  1. Find the highest-priority task and implement it. \
  2. Run your tests and type checks. \
  3. Update the PRD with what was done. \
  4. Append your progress to progress.txt. \
  5. Commit your changes. \
  6. Push to origin. \
  ONLY WORK ON A SINGLE TASK. \
  If the PRD is complete, output <promise>COMPLETE</promise>.")

  echo "$result"

  if [[ "$result" == *"<promise>COMPLETE</promise>"* ]]; then
    echo "PRD complete after $i iterations."
    exit 0
  fi
done
