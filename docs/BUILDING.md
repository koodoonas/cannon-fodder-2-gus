# Building CF2GUS

## Public build

Requirements:

- NASM 2.x
- GNU Make
- Python 3.10 or newer for tests and the release audit

Build and check from the repository root:

```sh
make clean all
make check
sha256sum dist/CF2GUS.COM
```

NASM's flat-binary output contains no timestamp, so builds made from the same
source with a compatible NASM should be byte-for-byte reproducible.

## Pinned validation environment

The private validation workspace used:

- NASM 2.16.01
- DOSBox-X 2024.03.01, commit `02f36ba`
- emulated 386 CPU at a fixed 12,000 cycles
- 16 MiB RAM
- GUS MAX emulation at 240h, IRQ 7, DMA 7, 1 MiB RAM
- mixer and GUS output at 44.1 kHz
- SB16 emulation at 220h, IRQ 5, DMA 5, high DMA 5

The `ULTRASND` parser was also exercised with GUS emulation moved to base 250h,
IRQ 11, and DMA 3. The displayed and programmed values followed
`ULTRASND=250,3,3,11,11`.

Private game files, unpacked fixtures, emulator captures, and restricted tools
are deliberately outside this repository. The release audit rejects common
game-asset, executable, archive, and capture formats.

## Optional test builds

The source contains compile-time-only diagnostics used in the private test
workspace:

```sh
nasm -Wall -DINTEGRATION_TEST=1 -DSFX_INTEGRATION_TEST=1 \
  -DFADE_INTEGRATION_TEST=1 -DSELECTOR_INTEGRATION_TEST=1 \
  -f bin -o CF2GUS-TEST.COM src/cf2gus.asm
```

These flags are absent from `dist/CF2GUS.COM`. The integration build forces a
short game-timer fade, loads the first requested song, forces a second fade,
checks that GF1 tracker ticks continue, changes to `LOADER.AMF`, and requires
the restored post-load game fade to raise its master from 0 to 64. It then
verifies that an unmapped selector cannot stop or restart loader and injects
one test SFX through the freshly patched game wrapper. It exits after the
loader has run for five seconds so the parent can report the fade and selector
results plus event counters. It must never be distributed as the normal
launcher.

The clock fallback has a destructive test hook that acknowledges GF1 timer
interrupts without delivering them to the tracker. It is valid only with the
game integration build:

```sh
nasm -Wall -DINTEGRATION_TEST=1 -DSFX_INTEGRATION_TEST=1 \
  -DFADE_INTEGRATION_TEST=1 -DSELECTOR_INTEGRATION_TEST=1 \
  -DCLOCK_STARVATION_TEST=1 \
  -f bin -o CF2GUS-STARVATION-TEST.COM src/cf2gus.asm
```

Reaching `Clock-starvation recovery test: PASS` proves that the patched game
timer, rather than GF1 timer delivery, advanced the tracker. This binary is for
automated testing only and must never be distributed.

For a bounded physical-machine trace, build outside the audited release tree:

```sh
nasm -Wall -DTRACE_BUILD=1 -f bin -o /tmp/CF2DIAG.COM src/cf2gus.asm
```

`TRACE_BUILD` adds a fixed 1,024-event memory buffer. Song/fade/volume/fallback
events and one heartbeat per 64 delivered tracker ticks are appended without
DOS calls; the report is printed only after the child exits and vectors are
restored. Building without the flag remains byte-identical to the normal
launcher.

Private validation can select another game-requested song and suppress the SFX
part of `/T` for a music-only capture:

```sh
nasm -Wall -DSELFTEST_SONG_ID=100 -DSELFTEST_NO_SFX=1 \
  -f bin -o CF2GUS-TITLE-TEST.COM src/cf2gus.asm
```

Those flags are test hooks only and are also absent from the release binary.
