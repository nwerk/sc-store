#!/bin/bash
# Downloads GuitarSet (Xi et al., ISMIR 2018, CC BY 4.0, https://zenodo.org/records/3371780) into data/guitarset.
# Only the mono pickup mix + mic audio and the annotations are needed (about 1.4 GB).
set -e
cd "$(dirname "$0")/.."
DEST="${1:-data/guitarset}"
mkdir -p "$DEST"
cd "$DEST"
for f in annotation audio_mono-pickup_mix audio_mono-mic; do
    if [[ ! -d "$f" ]]; then
        [[ -f "$f.zip" ]] || curl -L -C - -o "$f.zip" "https://zenodo.org/api/records/3371780/files/$f.zip/content"
        mkdir -p "$f"
        unzip -q -o "$f.zip" -d "$f"
    fi
done
echo "GuitarSet ready in $(pwd)"
