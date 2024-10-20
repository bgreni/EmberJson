#!/bin/bash

pwd

CONDA_BLD_PATH="./output"

for file in "$CONDA_BLD_PATH"/**/*.conda; do
    echo "$file"
done