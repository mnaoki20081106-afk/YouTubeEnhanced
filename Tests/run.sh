#!/bin/sh
# Runs the off-device Learning Filter tests.
#
# The decision layer (whitelist store, identity normalisation, guide harvester,
# allow/hide predicate) is plain Foundation code with no YouTube dependency, so
# it can be built and run outside the app. The Logos hooks are not covered here;
# they need YouTube itself and are verified on device.
#
#   macOS:  Tests/run.sh
#   Linux:  needs Foundation on a non-fragile Objective-C runtime, i.e. GNUstep
#           built against libobjc2. Ubuntu's stock libgnustep-base-dev links
#           GCC's fragile libobjc, which supports neither keyed subscripting nor
#           synthesized ivars, so it cannot build these sources.
set -e

root=$(cd "$(dirname "$0")/.." && pwd)
out=${TMPDIR:-/tmp}/learningfilter-tests
sources="$root/Tests/LearningFilterTests.m
         $root/Source/LearningFilter/LFSubscriptionStore.m
         $root/Source/LearningFilter/LFMetadata.m
         $root/Source/LearningFilter/LFHarvest.m
         $root/Source/LearningFilter/LFFilter.m"

if [ "$(uname)" = "Darwin" ]; then
    clang -fobjc-arc -o "$out" $sources -framework Foundation
else
    gnustep_include=${GNUSTEP_INCLUDE:-/usr/include/GNUstep}
    [ -d "$gnustep_include" ] || {
        echo "GNUstep headers not found at $gnustep_include" >&2
        exit 1
    }
    clang -fobjc-arc -fobjc-runtime=gnustep-2.0 -fblocks \
        -I"$gnustep_include" \
        -o "$out" $sources -lgnustep-base -lobjc -ldispatch
fi

"$out"
