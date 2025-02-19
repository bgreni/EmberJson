#!/bin/bash

set -eu

if [[ -z "${PREFIX_API_KEY}" ]]; then
    echo "api key not present in env"
    exit 1
fi

CONDA_BLD_PATH="output"

(magic run clean ; magic run update_and_build) || exit 1

for file in "$CONDA_BLD_PATH"/**/*.conda; do
    magic run rattler-build upload prefix -c "mojo-community-nightly" "$file" || (echo "upload failed" && exit 1)
done
