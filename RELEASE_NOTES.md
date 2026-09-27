# CF2GUS 0.5 alpha

- Restores the original selector's post-load fade-in state. The verified game
  routine arms a 64-step fade from master level zero after every successful
  mapped song change; CF2GUS v0.1–v0.4 bypassed that operation.
- Prevents a successfully loaded loader or post-level AMF from remaining at
  the preceding fade-out's zero master volume.
- Applies the transition only when the requested mapped song is current,
  active, and timer-driven. Unknown selectors and failed loads do not alter the
  game's fade state.
- Sets the launcher master shadow and guarded game fade words atomically before
  returning to the game timer.
- Extends the integration test through the complete loader fade-in and requires
  the game master to reach 64 before passing.
- Leaves the v0.4 GF1/game-clock behavior unchanged. The user's 486/133 with
  GUS PnP plays fades correctly; the remaining silent songs reproduce on both
  that system and the 386/GUS MAX.

Hardware result: v0.5 plays the previously silent scrolling-loader and
post-level music correctly on the target AMD 386DX-40 with 1 MiB GUS MAX.
Intro, Home:Away music, and gameplay SFX also remain working. A mild music
tempo sag remains during some loading and screen fades on that system; changing
the GUS from DMA/IRQ 7 to DMA/IRQ 3 did not alter it. The user's 486/133 with
GUS PnP does not exhibit the slowdown, although v0.5 has not received a full
PnP regression test.

## v0.4 alpha

- Preserves the active song when the game emits selector values 50–54. Those
  values are absent from the original seven-entry song table, and the original
  routine ignores them. Versions 0.2 and 0.3 instead stopped playback before
  discovering the request was unmapped, which could silently erase loader or
  post-level music without producing the missing/invalid-song warning.
- Replaces the retired software-mixer call with a small clock-recovery callback
  reached from the game's verified approximately 50 Hz timer interrupt.
- Keeps GF1 timer 1 as the normal precision music clock. After two consecutive
  game ticks without GF1 timer service, a fractional BPM/125 accumulator
  supplies only the missing tracker ticks. Catch-up is capped at four ticks per
  game interrupt to bound latency on a 386.
- Drops the first stale, coalesced GF1 timer request when hardware IRQ service
  resumes after fallback, preventing a duplicate tracker step.
- Makes the five-byte runtime callback patch atomic with respect to IRQ0.
- Reports the number of recovered tracker ticks after the child exits. A zero
  count is expected when GF1 IRQ delivery stays healthy.
- Adds independent integration regressions for unknown-selector preservation
  and total GF1-timer starvation.
- Extends `CF2DIAG` with fallback events and state while keeping all DOS output
  outside interrupt handlers.

Hardware result: v0.4 recovered 0x001B tracker ticks on the target 386 and made
fade starvation less pronounced, but the third loaded song remained silent.
The same songs remained silent on a 486/133 with GUS PnP even though its fades
played correctly. Unknown-selector preservation was therefore not the root
missing-song fix.

## v0.3 alpha

- Restores the original fade-before-song-change ordering that the v0.2 music
  shim accidentally bypassed.
- Keeps the outgoing GF1 tracker advancing while the game completes its
  64-step fade, then starts the requested AMF at the correct transition point.
- Attempts to prevent a stale fade from silencing later requests; subsequent
  target-hardware testing showed that this change does not resolve the missing
  loader/post-level music.
- Sleeps between transition interrupts rather than busy-waiting, and skips
  redundant four-voice master-volume writes when the requested level is
  unchanged.
- Adds a guarded integration test that forces two real game fade sequences,
  confirms GF1 timer progress during the second, and switches to
  `LOADER.AMF` only after the fade flag retires.

Hardware result: v0.3 behaves the same as v0.2 on the target GUS MAX. Intro and
Home:Away music plus gameplay SFX play, but beats still skip during fades,
loader/post-level music remains silent, and no missing/invalid-song warning is
reported. The emulator-validated fade-order change is therefore not the root
fix; a separate diagnostic build is being used to distinguish song requests,
master-volume state, GF1 timer progress, and PIC masking on the real machine.

## v0.2 alpha

- Tries the original `CANNON.EXE` filename first and `CAN2.EXE` as a fallback.
- Displays the base, both DMA values, and both IRQ values parsed from
  `ULTRASND` before probing the GF1.
- Raises the AMF pattern/track limits to accept the genuine 26-pattern,
  88-logical-track, 80-physical-track `TITLE.AMF`.
- Corrects AMF note/set-volume decoding and adds the pitch-slide, pattern-break,
  retrigger, and fine-volume-slide effects used by the supplied original media.
- Validates all seven game-requested AMFs from the complete installed set.
- Confirms that the supported English executable and all 21 audio assets are
  byte-identical across the supplied installation, original floppy images, and
  English CD image.
- Retains the GF1 hardware-mixer architecture and 44.1 kHz 14-voice setup from
  v0.1; there is still no per-frame PCM software mixer.

Hardware note: v0.1 produced audible `/T` and gameplay SFX on the target GUS
MAX. The v0.2 title/loader changes are emulator-validated and await a real-card
retest.

## v0.1 alpha

- Adds four-channel AMF 1.4 music on GF1 hardware voices.
- Adds eight-voice round-robin GF1 SFX playback for fourteen game effects.
- Uses 14 active GF1 voices to retain the full 44.1 kHz output rate.
- Converts unsigned game PCM to signed GF1 samples during upload, eliminating
  a large DC bias without producing converted files.
- Replaces the verified build's need for a separate `LOADFIX` invocation by
  retaining a 64 KiB launcher block.
- Applies compatibility changes only to the validated child image in memory.
- Uses numeric CRC fingerprints; no game instruction sequence or asset is
  embedded in the source or binary.
- Avoids the GUS MAX codec, ISA DMA transfers, and per-frame software mixing.
- Includes `/T`, stereo-width, music/SFX ceiling, and line-input controls.
- Restores interrupt vectors and PIC masks when the game exits.
- Preserves full 386 register state across GF1 timer and software-interrupt
  handlers.

Known limitations at that release: physical GUS testing, complete-media
testing, and CD/floppy executable support were pending.
