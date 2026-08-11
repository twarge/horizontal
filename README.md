# Horizontal

Horizontal is a PCB design tool for macOS and iPadOS.

**Horizontal is experimental software and should not be used in any production capacity. It comes with absolutely no warranty, will probably destroy your data, waste your time, and set your computer on fire.**

## Build

```sh
make          # Debug build of the macOS app
make run      # build it, then launch it
make release  # Release build
make ios      # build for the iOS Simulator
make test     # run the test suite
make help     # list every target
```

The first build also compiles the vendored OpenCascade static libraries, which
takes tens of minutes. `make deps` rebuilds them
explicitly. 

## Licensing

Horizontal is Apache 2.0 — see `LICENSE`.

Third-party licence texts ship inside the app at
`Contents/Resources/ThirdPartyLicenses/`, which is where the About panel points.
`Scripts/copy-third-party-licenses.sh` puts them there as a build phase, and a
Release build fails if any is missing.

**Open CASCADE Technology 8.0.0**
(STEP model import) is LGPL 2.1 with the Open CASCADE exception, and is linked
statically, so a release has to let someone rebuild the app against a
modified OCCT. That is what the `Vendor/OCCT` submodule is for: it pins the
`V8_0_0` tag, and `make deps` reproduces the exact static build the app links
(third-party dynamic dependencies off, RapidJSON on).

The other bundled components — RapidJSON (MIT), mapbox/earcut.hpp (ISC), Clipper
(Boost 1.0), and the Hershey stroke font tables generated from OpenCV 4.4.0
(BSD 3-Clause) — need only their notice, which is what ships. The Hershey vector
outlines themselves are the work of Dr A. V. Hershey at the US National Bureau
of Standards and were never subject to copyright; `Vendor/Hersheyish` holds the
generator and the pinned upstream sources.
