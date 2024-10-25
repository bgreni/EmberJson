#!/bin/bash

CONDA_BLD_PATH="output"

(magic run clean ; magic run update_and_build) || exit 1

for file in "$CONDA_BLD_PATH"/**/*.conda; do
    rattler-build upload prefix -c "mojo-community-nightly" "$file" --api-key=$PREFIX_API_KEY || (echo "upload failed" ; exit 1)
done

magic run clean
