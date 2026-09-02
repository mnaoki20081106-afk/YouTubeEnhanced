# Learning Filter tests

`run.sh` builds and runs the filter's decision layer outside the app. That layer
— the whitelist store, identity normalisation, the payload byte scanners, the
guide harvester, the shared allow/hide decision, dry run, the strict-mode safety
valve and the diagnostics buffer — is plain Foundation code with no YouTube
dependency, so it can be exercised without producing an IPA.

The Logos hooks are not covered here. They need YouTube itself.

## Running

On macOS, nothing to set up:

```sh
Tests/run.sh
```

On Linux, Foundation has to sit on a **non-fragile** Objective-C runtime, which
is what gives ARC, keyed subscripting and lightweight generics. Ubuntu's
`libgnustep-base-dev` links GCC's fragile `libobjc` and cannot build these
sources at all. GNUstep on libobjc2 can:

```sh
apt-get install -y cmake ninja-build clang libffi-dev libxml2-dev \
    libgnutls28-dev libicu-dev zlib1g-dev libssl-dev pkg-config

git clone --depth 1 --recurse-submodules https://github.com/gnustep/libobjc2
cmake -S libobjc2 -B libobjc2/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DTESTS=OFF
cmake --build libobjc2/build && cmake --install libobjc2/build && ldconfig

git clone --depth 1 https://github.com/gnustep/tools-make
(cd tools-make && ./configure --with-layout=fhs --enable-native-objc-exceptions \
    --with-library-combo=ng-gnu-gnu && make && make install)

. /usr/local/share/GNUstep/Makefiles/GNUstep.sh
git clone --depth 1 https://github.com/gnustep/libs-base
(cd libs-base && CPPFLAGS=-I/usr/local/include/GNUstep ./configure && make && make install)
ldconfig
```

`Tests/linux-compat/` then supplies the one remaining gap, libdispatch. See the
README in that directory.

## What is covered

- **Identity normalisation** — channel ids out of bare strings and URLs, handles,
  display-name folding, and the rejections that matter: a token that merely
  starts with `UC`, an `@` inside a title.
- **The whitelist store** — harvesting, matching by each identifier form,
  dropping a channel, and staying inert while empty (the signed-out case).
- **Guide harvesting** — pulling ids, handles and titles out of a protobuf text
  dump, and not mistaking navigation labels or canonical URLs for channel names.
- **The acceptance matrix** — two subscribed channels shown and one unsubscribed
  channel hidden, on each of home, search, Shorts and related.
- **Identifier ranking** — a display name cannot override a channel id that is
  present and not subscribed.
- **Payload byte scanning** against binary payloads with non-printable bytes
  around the strings, which is what the device actually hands the scanner.
- **Dry run**, which computes and records decisions but hides nothing.
- **The strict-mode safety valve**, which stops hiding unidentifiable content
  once a long run of it proves nothing can be identified.
- **Diagnostics** recording and counting.
- **Cache invalidation** when the whitelist or a setting moves.
