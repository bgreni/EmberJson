#!/bin/bash

CONDA_BLD_PATH="./output"

(magic run clean ; magic run update_and_build) || exit 1

for file in "$CONDA_BLD_PATH"/**/*.conda; do
    magic run rattler-build upload prefix -c "mojo-community-nightly" "$file" || echo "upload failed"
done

magic run clean