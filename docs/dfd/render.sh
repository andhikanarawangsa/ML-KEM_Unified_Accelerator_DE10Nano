#!/usr/bin/env bash
# Render every DFD *.dot in this folder to out/*.png (200 dpi) and out/*.svg
set -e
cd "$(dirname "$0")"
mkdir -p out
for f in *.dot; do
    n="${f%.dot}"
    dot -Tpng -Gdpi=200 "$f" -o "out/$n.png"
    dot -Tsvg           "$f" -o "out/$n.svg"
    echo "rendered $n"
done
