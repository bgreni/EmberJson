#!/bin/bash
set -e
magic run template
magic run rattler-build build -r recipes  --skip-existing=all