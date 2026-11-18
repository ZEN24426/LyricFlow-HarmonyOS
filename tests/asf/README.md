# Restricted ASF tests

These tests exercise the candidate application's ASF services. The test runner generates
short synthetic FFmpeg WMAv2 files and a PNG, writes them only in a new system temporary
directory, and removes that directory when it exits normally or throws. An interrupted
process or machine crash can leave the temporary directory behind. No fixture binaries
or FFmpeg binaries are included here.

Install the existing test dependency once with `npm ci` in `tests`. Provide independently
installed FFmpeg and FFprobe executables that support the WMAv2 encoder/decoder, ASF,
the lavfi sine source and PNG. Then run, for example in PowerShell:

```powershell
$env:ASF_TEST_FFMPEG = 'C:\path\to\ffmpeg.exe'
$env:ASF_TEST_FFPROBE = 'C:\path\to\ffprobe.exe'
cd tests
npm run test:asf
```

`npm test` runs the existing non-ASF suite; it does not include the ASF suite.

The runner tests the candidate service files directly and creates an edited fixture
using `AsfHeaderEditor`. FFmpeg and FFprobe are external test tools, not application
runtime dependencies. Their availability, features, versions, and licenses are the
responsibility of the environment running the tests. The scripts were exercised with
Node.js 24 and FFmpeg/FFprobe 9.0.2; other versions may differ.

These are restricted-format tests, not proof of general WMA compatibility. Several
tests use simulated HarmonyOS APIs; Node's TypeScript transpilation is not ArkTS
compilation and simulated ImageKit/MediaKit results do not establish device behavior.
The synthetic samples do not represent protected files or a broad real-world corpus.

## References

The research implementation and fixture generator were independently designed while
consulting the following publicly licensed source files; no source text or implementation
was intentionally copied. This is not a formal clean-room process and this note is not a
legal determination of derivation.

- Mutagen, GPL-2.0-or-later, copyright Joe Wreschnig and Lukas Lalinsky: [ASF object
  definitions](https://github.com/quodlibet/mutagen/blob/48b3463d0ed70ba2b797ac9cc83983066ecf076a/mutagen/asf/_objects.py)
  and [attribute encodings](https://github.com/quodlibet/mutagen/blob/48b3463d0ed70ba2b797ac9cc83983066ecf076a/mutagen/asf/_attrs.py).
- FFmpeg, LGPL-2.1-or-later, copyright Fabrice Bellard: [ASF demuxer](https://github.com/FFmpeg/FFmpeg/blob/a5ed44135fa4d2b205d93795da32e449055faf0b/libavformat/asfdec_f.c)
  and [ASF tag mapping](https://github.com/FFmpeg/FFmpeg/blob/a5ed44135fa4d2b205d93795da32e449055faf0b/libavformat/asf.c).

Microsoft's restricted ASF specification was not used. Distribution must independently
assess copyright, license and source obligations for any actual derivative work.
