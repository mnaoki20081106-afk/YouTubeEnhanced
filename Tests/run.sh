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
         $root/Source/LearningFilter/LFFilter.m
         $root/Source/LearningFilter/LFDiagnostics.m"

if [ "$(uname)" = "Darwin" ]; then
    clang -fobjc-arc -o "$out" $sources -framework Foundation
else
    # GNUstep built against libobjc2 (the non-fragile runtime), which is what
    # gives ARC, keyed subscripting and lightweight generics. Ubuntu's stock
    # libgnustep-base-dev links GCC's fragile libobjc and cannot build these
    # sources; see Tests/README.md for how this toolchain is put together.
    gnustep_include=${GNUSTEP_INCLUDE:-/usr/local/include/GNUstep}
    gnustep_lib=${GNUSTEP_LIB:-/usr/local/lib}
    [ -d "$gnustep_include" ] || {
        echo "GNUstep (libobjc2) headers not found at $gnustep_include" >&2
        echo "See Tests/README.md for the toolchain this needs." >&2
        exit 1
    }
    # __unused is an Apple/BSD spelling that glibc does not provide.
    clang -fobjc-arc -fobjc-runtime=gnustep-2.0 -fblocks \
        "-D__unused=__attribute__((unused))" \
        -I"$root/Tests/linux-compat" -I"$gnustep_include" -I"$(dirname "$gnustep_include")" \
        -o "$out" $sources -L"$gnustep_lib" -lgnustep-base -lobjc
    LD_LIBRARY_PATH="$gnustep_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export LD_LIBRARY_PATH
fi

"$out"
