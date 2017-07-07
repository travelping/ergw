#!/bin/sh

if [ -n "$TRAVIS_PULL_REQUEST" -a "$TRAVIS_PULL_REQUEST" != "false" ]; then
   export CI_RUN_SLOW_TESTS=true
fi
