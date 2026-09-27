# Cannon Fodder 2 GUS (CF2GUS)

CF2GUS is a DOS launcher that gives one verified English build of
*Cannon Fodder 2* native Gravis UltraSound GF1 music and sound effects. It also
reserves the same 64 KiB low-memory block as `LOADFIX`, so the verified packed
executable can be started directly with `CF2GUS`.

The game executable and assets are never changed. All compatibility changes
exist only in the child process while it runs.

## Current status

| Item | Status |
|---|---|
| Verified packed `CANNON.EXE` / `CAN2.EXE` | 98,791 bytes; SHA-256 `bff98b997e893b3bcbe78b8bbdc5dd31e7d378dac0004ffb7de66d42c82fae1b` |
| GF1 music path | All seven requested AMFs load in DOSBox-X; title and loader have non-silent captures; v0.5 restores the original post-load fade-in that v0.1–v0.4 omitted |
| GF1 SFX path | Self-tested and integration-tested in DOSBox-X; v0.1 was audible on the target GUS MAX |
| `LOADFIX` replacement | Working in DOSBox-X and on the target 386 with the verified packed executable |
| Real GF1 hardware | v0.5 verified on an AMD 386DX-40 with a 1 MiB GUS MAX: intro, Home:Away, scrolling loader, post-level music, and gameplay SFX play correctly |
| Original English CD/floppy media | Executable and all 21 audio assets match the supplied installed set byte for byte |

Version 0.5 alpha is the first build with the complete music path verified on
the target 386/GUS MAX. Keep the original game installation available and
report the exact on-screen output if testing fails on another configuration.

The target-machine results disproved the earlier v0.3 and v0.4 missing-song
diagnoses. Preserving unmapped selector values in v0.4 remains a valid
compatibility correction, but it did not restore the silent tracks.

Further static analysis verified the omitted operation: after loading and
starting every mapped song, the original selector arms the game's 64-step
music fade-in at level zero. CF2GUS v0.1–v0.4 bypassed that post-load step, so a
valid new AMF could keep running at the preceding fade-out's zero master
volume. Version 0.5 restores that state transition for successful mapped song
loads and restarts only.

The v0.4 386 run reported 0x001B recovered tracker ticks, confirming fallback
activation there. Version 0.5 leaves that bounded clock path unchanged and
targets only the hardware-independent silent-song transition. A 486/133 with
GUS PnP plays the fades without the mild tempo sag heard on the 386, but v0.5
has not yet received a complete PnP retest.

### Known limitation

On the target 386DX-40, music can slow slightly while the game loads or fades
the screen. The same behavior occurs with the GUS MAX changed from DMA/IRQ 7
to DMA/IRQ 3, while the 486/133 does not exhibit it. The bounded recovery path
reduces the interruption but deliberately waits two game ticks before taking
over, avoiding normal GF1/game-clock phase jitter. Version 0.5 keeps that
conservative behavior because playback and all song transitions are otherwise
correct.

## Design

- Keeps a 64 KiB DOS allocation before loading `CANNON.EXE` (falling back to
  `CAN2.EXE`), reproducing the useful placement effect of `LOADFIX`.
- Walks the DOS memory-control-block chain to find the child PSP, then verifies
  all supported runtime locations with numeric CRC fingerprints before making
  an in-memory change.
- Replaces the old software-mixed music and SFX entry points with temporary
  interrupt shims.
- Streams AMF 1.4 instrument data to GF1 RAM and advances four tracker channels
  from the GF1 timer IRQ.
- Treats values absent from the verified song table as no-ops, matching the
  original selector instead of stopping a valid current module.
- Retains the GF1 timer as the primary tracker clock. If it is not serviced for
  two consecutive game ticks, a fractional 50 Hz reference supplies only the
  deficit, with at most four catch-up ticks in one game interrupt.
- Preserves the game's fade-before-song-change ordering. The outgoing tracker
  keeps advancing during the fade, and the replacement AMF starts only after
  the game retires its fade-down state.
- After a successful mapped load or resident restart, re-arms the verified
  game fade-in state at level zero so the new module rises to full game master
  volume instead of remaining silent.
- Converts the game's unsigned 8-bit PCM to the signed representation expected
  by GF1 voices while uploading; no converted asset is written to disk.
- Preloads fourteen game effects and provides eight round-robin GF1 SFX voices.
- Programs 14 active GF1 voices for the card's full 44.1 kHz output rate. Four
  voices carry music, eight carry SFX, and two stay silent.
- Uses programmed I/O only while loading samples. It does not use ISA DMA, the
  GUS MAX codec, or a PCM software mixer; fallback work is tracker/register
  servicing only and is dormant while GF1 timer delivery is healthy.
- Restores interrupt vectors, PIC masks, GF1 voices, and the line-input state
  when the child exits.

## Install and run

Copy `dist/CF2GUS.COM` into the game directory containing `CANNON.EXE` (or the
same verified file renamed `CAN2.EXE`), the AMF files, and the SMP files. Set
the normal GUS environment variable, then run the self-test before starting the
game:

```dos
SET ULTRASND=240,7,7,7,7
CF2GUS /T
CF2GUS
```

The first value in `ULTRASND` is parsed as hexadecimal; the remaining four are
decimal. CF2GUS displays the base, both DMA selections, and both IRQ selections
that it parsed before probing the card. The target machine uses a GUS MAX with
1 MiB at base 240h, DMA 7, and IRQ 7. CF2GUS touches the GF1 and the original
GUS interface only; it does not initialize or depend on the MAX codec. Sample
uploads use programmed I/O, so the selected ISA DMA channel is not used for
streaming audio.

### Options

| Option | Meaning | Default |
|---|---|---:|
| `/T` | GF1 timer/music/SFX self-test; does not launch the game | off |
| `/P-100..100` | Stereo width; a negative value reverses left and right | `+60` |
| `/M0..100` | Music-volume ceiling | `81` |
| `/S0..100` | SFX-volume ceiling | `86` |
| `/LON` | Keep the GUS analog line input enabled during the game | on |
| `/LOFF` | Mute the GUS analog line input after the patch is installed | off |

Open Cubic Player-style `-vp`, `-vm`, and `-vs` spellings are accepted too.

## Required game files

The launcher does not redistribute or synthesize game data. The verified
installation contains these requested songs: `MENU.AMF`, `WINZONE.AMF`,
`WINLEVEL.AMF`, `HELIANIM.AMF`, `LOADER.AMF`, `GAMEOVER.AMF`, and `TITLE.AMF`.
It also contains fourteen SMP effects from `BIRD.SMP` through `ROOK.SMP` as
listed in the source. Those files were compared with the original English CD
and floppy media and matched byte for byte.

Missing SFX are reported at startup and only those effects stay silent. A
requested missing or invalid song stops music and is reported when the game
exits. Supply the files from your own installation; none are included here.

## Build and verify

NASM 2.x and Python 3 are sufficient for the public build checks:

```sh
make clean all
make check
```

`make check` runs unit tests and audits the repository for game executables,
assets, archives, captures, or private unpacked fixtures. See
[`docs/BUILDING.md`](docs/BUILDING.md) and
[`docs/VALIDATION.md`](docs/VALIDATION.md) for the pinned test setup and the
claims that have actually been demonstrated.

## Copyright and provenance

No game routine, game asset, DSMI routine, unpacker, or cracked executable is
included. Runtime guards are numeric fingerprints rather than copied instruction
sequences. The implementation is independently written, with low-level GF1
support adapted from the MIT-licensed PRE2GUS project; the required notice is
preserved in `LICENSE`. Public AMF format documentation and MIT-licensed libxmp
were used to cross-check format behavior, but no libxmp code is linked or copied.

See [`NOTICE.md`](NOTICE.md) for the precise distribution boundary.
