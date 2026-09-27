CF2GUS 0.5 ALPHA - DOS QUICK START
==================================

CF2GUS adds native GF1 music and sound effects to one verified build of
Cannon Fodder 2. It also reserves the low 64 KiB block normally obtained
with LOADFIX. It does not change CANNON.EXE, CAN2.EXE, or game data on disk.

VERIFIED CANNON.EXE / CAN2.EXE
------------------------------

Size:    98791 bytes
SHA-256: bff98b997e893b3bcbe78b8bbdc5dd31e7d378dac0004ffb7de66d42c82fae1b

INSTALL
-------

Copy CF2GUS.COM into the directory containing CANNON.EXE and the AMF/SMP
files. A renamed CAN2.EXE is accepted as a fallback. Set ULTRASND as usual.
Example for base 240h, DMA 7, IRQ 7:

  SET ULTRASND=240,7,7,7,7

First test the GF1 without starting the game:

  CF2GUS /T

Then launch the game without LOADFIX:

  CF2GUS

OPTIONS
-------

  /T          Self-test only
  /P-100..100 Music stereo width; minus reverses left and right
  /M0..100    Music-volume ceiling
  /S0..100    SFX-volume ceiling
  /LON        Keep GUS analog line input enabled (default)
  /LOFF       Mute GUS analog line input after patch installation

The aliases -vp, -vm, and -vs are also accepted.

NOTES
-----

This alpha uses the GF1 only. It does not use ISA DMA or the GUS MAX codec.
It programs 14 active voices for 44.1 kHz output: 4 music, 8 SFX, 2 silent.
The screen prints the base, both DMA values, and both IRQ values parsed from
ULTRASND before the card is probed.

Missing/truncated SFX are listed at startup and only those sounds are silent.
Missing or invalid requested songs are reported when the game exits. The
complete supplied installation's seven AMFs and fourteen SMPs match the
original English CD/floppy media. Game assets are not included with CF2GUS.

Versions through 0.4 could load loader/post-level AMFs successfully but leave
them at the preceding fade-out's zero master volume. Version 0.5 restores the
original game's post-load 64-step fade-in. Version 0.5 is verified on an AMD
386DX-40 with a 1 MiB GUS MAX: loader/post-level music, intro music, Home:Away
music, and gameplay SFX play correctly.

Version 0.4's bounded music-clock fallback remains present. The GF1 timer is
primary when healthy; there is still no PCM software mixer.

The target 386 can still exhibit a mild music tempo sag while loading or during
screen fades. The same behavior was observed after moving the GUS MAX from
DMA/IRQ 7 to DMA/IRQ 3. It is not present on the user's 486/133 system. Version
0.5 keeps the conservative clock-recovery timing because song playback and
transitions are otherwise correct.

After the game exits, "Recovered tracker ticks" shows how many music ticks the
fallback supplied. 0000 is normal when the GF1 IRQ was never starved. A nonzero
value means the fallback kept the tracker moving. Game assets remain unchanged.
