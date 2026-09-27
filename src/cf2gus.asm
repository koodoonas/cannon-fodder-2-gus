; SPDX-License-Identifier: MIT
; CF2GUS - native GF1 audio launcher for Cannon Fodder 2 (DOS)
;
; Target executable:
;   CANNON.EXE (or renamed CAN2.EXE), 98791 bytes
;   SHA-256 bff98b997e893b3bcbe78b8bbdc5dd31e7d378dac0004ffb7de66d42c82fae1b
;
; The launcher leaves the game executable and all assets unchanged.  It retains 64 KiB
; before EXEC (the placement effect of LOADFIX), identifies the exact unpacked
; game image in memory, and replaces its DSMI entry points for the lifetime of
; the child.  Music and SFX use GF1 hardware voices.  No MAX codec, ISA DMA, or
; CPU software mixer is used.  All vectors and PIC masks are restored on exit.
;
; Independently written implementation.  No game or DSMI code is copied or
; included.
; Build with NASM 2.x: nasm -f bin -o CF2GUS.COM cf2gus.asm

bits 16
org 100h

%define AMF_HEADER_BYTES    75
%define MAX_INSTRUMENTS     31
%define MAX_PATTERNS        32
%define MAX_LOGICAL_TRACKS  96
%define MAX_PHYSICAL_TRACKS 96
%define TRACK_BUFFER_BYTES  8192
%define MUSIC_DRAM_LOW      0000h
%define MUSIC_DRAM_HIGH     0001h       ; 0x10000
%define IO_BUFFER_BYTES     512
%define SFX_COUNT           14
%define SFX_VOICES          8
%define USED_VOICES         12
%define ACTIVE_VOICES       14           ; GF1 minimum for 44.1-kHz output
%define SELFTEST_TICKS      300
%define SELFTEST_BIOS_TICKS 128
%define GAME_CLOCK_DENOM    125          ; 50 Hz * 2.5 tracker constant
%define CLOCK_WATCHDOG_TICKS 2           ; tolerate normal IRQ phase jitter
%define CLOCK_CATCHUP_LIMIT 4            ; bound work inside one game IRQ0

%ifdef TRACE_BUILD
%define TRACE_EVENT_BYTES   20
%define TRACE_EVENT_LIMIT   1024
%endif

%ifndef SELFTEST_SONG_ID
%define SELFTEST_SONG_ID    0
%endif

%ifdef FADE_INTEGRATION_TEST
%ifndef INTEGRATION_TEST
%error FADE_INTEGRATION_TEST requires INTEGRATION_TEST
%endif
%endif

%ifdef CLOCK_STARVATION_TEST
%ifndef INTEGRATION_TEST
%error CLOCK_STARVATION_TEST requires INTEGRATION_TEST
%endif
%endif

%ifdef SELECTOR_INTEGRATION_TEST
%ifndef INTEGRATION_TEST
%error SELECTOR_INTEGRATION_TEST requires INTEGRATION_TEST
%endif
%endif

; Segment offsets in the materialized (unpacked) image.  These are factual
; interoperability locations for the one verified build, never on-disk bytes.
%define GAME_MUSIC_SEG      0E11h
%define GAME_AUDIO_SEG      06C4h
%define GAME_MAIN_SEG       0301h
%define GAME_VOLUME_SEG     2A5Ah
%define GAME_DATA_SEG       2FEFh
%define PATCH_MUSIC_OFF     00DBh
%define PATCH_SFX_OFF       01F1h
%define PATCH_INIT_OFF      000Ah
%define PATCH_CLEANUP_OFF   02C8h
%define PATCH_PRELOAD_OFF   061Bh
%define PATCH_MIXCALL_OFF   0372h
%define PATCH_VOLUME_OFF    161Bh
%define GAME_FADE_DOWN_OFF  71A9h
%define GAME_FADE_UP_OFF    71ABh
%define GAME_FADE_LEVEL_OFF 71ADh
%define GAME_TIMER_TICKS_OFF 94DAh
%define LOADFIX_PARAS       1000h

; CRC-16/CCITT fingerprints of the guarded regions in the verified runtime
; image.  Numeric fingerprints avoid embedding any game instruction sequence.
%define MUSIC_GUARD_LEN     24
%define MUSIC_GUARD_CRC     0CDA1h
%define SFX_GUARD_LEN       24
%define SFX_GUARD_CRC       0E976h
%define INIT_GUARD_LEN      15
%define INIT_GUARD_CRC      041FFh
%define CLEANUP_GUARD_LEN   8
%define CLEANUP_GUARD_CRC   09E1Ch
%define PRELOAD_GUARD_LEN   10
%define PRELOAD_GUARD_CRC   0D844h
%define MIXCALL_GUARD_LEN   3
%define MIXCALL_GUARD_CRC   0282Dh
%define VOLUME_GUARD_LEN    23
%define VOLUME_GUARD_CRC    0A66Dh

    jmp start

; ---------------------------------------------------------------------------
; Startup and DOS launcher

start:
    cli
    mov ax, cs
    mov ss, ax
    mov sp, stack_top
    sti
    mov ds, ax
    mov es, ax
    cld
    mov [psp_segment], ax

    mov dx, msg_banner
    call print_dos
    call parse_command_line
    jc fatal_args
    call show_music_pan
    call show_audio_volumes
    call show_line_mode
    call parse_ultrasnd
    jc fatal_config
    call show_gus_config
    call setup_gus_ports

    ; Put our stack inside the retained block, then return unused DOS memory.
    mov bx, RESIDENT_PARAS
    mov ah, 4Ah
    int 21h
    jc fatal_memory

    mov ax, [psp_segment]
    add ax, RESIDENT_PARAS
    mov [patch_scan_start], ax

    call gus_reset
    call gus_probe
    jc fatal_gus
    call gus_set_interface
    call load_sfx_bank
    call install_vectors

    cmp byte [test_mode], 0
    jne run_selftest

    call exec_game
    mov [exec_error], ax
    mov byte [exec_failed], 0
    jnc .child_returned
    mov byte [exec_failed], 1
    jmp .after_child
.child_returned:
    mov ah, 4Dh
    int 21h
    mov [child_exit_code], al
.after_child:
    call cleanup
%ifdef DUMP_CODE
    call write_code_dump
%endif

    cmp byte [exec_failed], 0
    je .report_patch
    mov dx, msg_exec_failed
    call print_dos
    mov ax, [exec_error]
    call print_hex_word
    mov dx, msg_crlf
    call print_dos
    mov al, 1
    jmp exit_dos

.report_patch:
%ifdef DIAGNOSTIC_ABORT
    mov dx, msg_diag_calls
    call print_dos
    mov ax, [diag_int21_calls]
    call print_hex_word
    mov dx, msg_diag_psp
    call print_dos
    mov ax, [diag_child_psp]
    call print_hex_word
    mov dx, msg_diag_base
    call print_dos
    mov ax, [diag_candidate_base]
    call print_hex_word
    mov dx, msg_diag_stage
    call print_dos
    xor ax, ax
    mov al, [diag_stage]
    call print_hex_word
    mov dx, msg_crlf
    call print_dos
%endif
    cmp byte [patch_installed], 1
    jne .not_patched
    mov dx, msg_patch_ok
    call print_dos
    jmp .report_song
.not_patched:
    mov dx, msg_patch_missing
    call print_dos
.report_song:
%ifdef DUMP_CODE
    mov dx, msg_patch_trigger
    call print_dos
    mov ax, [patch_trigger_ax]
    call print_hex_word
    mov dx, msg_patch_trigger_ip
    call print_dos
    mov ax, [patch_trigger_ip]
    call print_hex_word
    mov dx, msg_crlf
    call print_dos
%endif
    cmp byte [song_error], 0
    je .report_counts
    mov dx, msg_song_error
    call print_dos
.report_counts:
%ifdef FADE_INTEGRATION_TEST
    cmp byte [fade_test_pass], 1
    jne .fade_test_failed
    mov dx, msg_fade_test_ok
    call print_dos
    jmp .fade_test_reported
.fade_test_failed:
    mov dx, msg_fade_test_fail
    call print_dos
    mov byte [child_exit_code], 3
.fade_test_reported:
%endif
%ifdef SELECTOR_INTEGRATION_TEST
    cmp byte [selector_test_pass], 1
    jne .selector_test_failed
    mov dx, msg_selector_test_ok
    call print_dos
    jmp .selector_test_reported
.selector_test_failed:
    mov dx, msg_selector_test_fail
    call print_dos
    mov byte [child_exit_code], 5
.selector_test_reported:
%endif
%ifdef CLOCK_STARVATION_TEST
    cmp word [clock_fallback_ticks], 0
    jne .clock_test_ok
    mov dx, msg_clock_test_fail
    call print_dos
    mov byte [child_exit_code], 4
    jmp .clock_test_reported
.clock_test_ok:
    mov dx, msg_clock_test_ok
    call print_dos
.clock_test_reported:
%endif
    mov dx, msg_audio_counts
    call print_dos
    mov ax, [songs_loaded]
    call print_hex_word
    mov dx, msg_audio_sfx
    call print_dos
    mov ax, [sfx_played]
    call print_hex_word
    mov dx, msg_crlf
    call print_dos
    mov dx, msg_clock_recovery
    call print_dos
    mov ax, [clock_fallback_ticks]
    call print_hex_word
    mov dx, msg_crlf
    call print_dos
%ifdef TRACE_BUILD
    call trace_report
%endif
    mov al, [child_exit_code]
    jmp exit_dos

run_selftest:
    mov dx, msg_test_start
    call print_dos
    pushf
    cli
    mov word [total_ticks], 0
    popf
    mov ax, SELFTEST_SONG_ID
    int 65h
%ifndef SELFTEST_NO_SFX
    xor ax, ax                   ; BIRD.SMP, 8363 Hz, volume 64
    mov bx, 8363
    mov cx, 64
    int 66h
%endif

    xor ax, ax
    mov es, ax
    mov ax, [es:046Ch]
    mov [bios_tick_start], ax
.wait:
    cmp word [total_ticks], SELFTEST_TICKS
    jae .test_ok
    mov ah, 01h
    int 16h
    jnz .test_key
    mov ax, [es:046Ch]
    sub ax, [bios_tick_start]
    cmp ax, SELFTEST_BIOS_TICKS
    jae .test_timeout
    sti
    hlt
    jmp .wait
.test_key:
    mov ah, 00h
    int 16h
    cmp word [total_ticks], 0
    je .test_timeout
.test_ok:
    push cs
    pop ds
    call cleanup
    mov dx, msg_test_ok
    call print_dos
    xor al, al
    jmp exit_dos
.test_timeout:
    push cs
    pop ds
    call cleanup
    mov dx, msg_test_fail
    call print_dos
    mov al, 2
    jmp exit_dos

fatal_config:
    mov dx, msg_bad_config
    jmp fatal_plain
fatal_args:
    mov dx, msg_bad_args
    jmp fatal_plain
fatal_memory:
    mov dx, msg_no_memory
    jmp fatal_plain
fatal_gus:
    call gus_quiet
    mov dx, msg_no_gus
    call print_dos
    mov dx, msg_probe_detail
    call print_dos
    mov ax, [gus_base]
    call print_hex_word
    mov dx, msg_probe_values
    call print_dos
    xor ax, ax
    mov al, [probe_value0]
    call print_hex_word
    mov dl, '/'
    mov ah, 02h
    int 21h
    xor ax, ax
    mov al, [probe_value1]
    call print_hex_word
    mov dx, msg_crlf
    call print_dos
    mov al, 1
    jmp exit_dos
fatal_quiet:
    push dx
    call gus_quiet
    pop dx
fatal_plain:
    call print_dos
    mov al, 1

exit_dos:
    mov ah, 4Ch
    int 21h

print_dos:
    mov ah, 09h
    int 21h
    ret

print_hex_word:
    push ax
    push bx
    push cx
    push dx
    mov bx, ax
    mov cx, 4
.digit:
    rol bx, 4
    mov dl, bl
    and dl, 0Fh
    add dl, '0'
    cmp dl, '9'
    jbe .emit
    add dl, 7
.emit:
    mov ah, 02h
    int 21h
    loop .digit
    pop dx
    pop cx
    pop bx
    pop ax
    ret

%ifdef TRACE_BUILD
print_hex_byte:
    push ax
    push bx
    push cx
    push dx
    mov bl, al
    mov cx, 2
.digit:
    rol bl, 4
    mov dl, bl
    and dl, 0Fh
    add dl, '0'
    cmp dl, '9'
    jbe .emit
    add dl, 7
.emit:
    mov ah, 02h
    int 21h
    loop .digit
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Emit the trace only after the child has returned and all interrupt vectors
; have been restored.  This keeps DOS calls out of the game and IRQ contexts;
; callers can redirect CF2DIAG's stdout to a text file.
trace_report:
    push ax
    push bx
    push cx
    push dx
    push si
    mov dx, msg_trace_header
    call print_dos
    mov ax, [trace_count]
    call print_hex_word
    mov dx, msg_trace_overflow
    call print_dos
    mov ax, [trace_overflow]
    call print_hex_word
    mov dx, msg_crlf
    call print_dos
    mov dx, msg_trace_legend
    call print_dos
    xor bx, bx
.event:
    cmp bx, [trace_count]
    jae .done
    mov ax, bx
    call print_hex_word
    mov dl, ' '
    mov ah, 02h
    int 21h
    mov si, bx
    shl si, 1
    shl si, 1
    mov ax, bx
    shl ax, 1
    shl ax, 1
    shl ax, 1
    shl ax, 1
    add si, ax                    ; index * (16 + 4)
    add si, trace_events
    mov dl, [si]
    mov ah, 02h
    int 21h
    mov dx, msg_trace_arg
    call print_dos
    mov al, [si+1]
    call print_hex_byte
    mov dx, msg_trace_current
    call print_dos
    mov al, [si+2]
    call print_hex_byte
    mov dx, msg_trace_master
    call print_dos
    mov al, [si+3]
    call print_hex_byte
    mov dx, msg_trace_ticks
    call print_dos
    mov ax, [si+4]
    call print_hex_word
    mov dx, msg_trace_bios
    call print_dos
    mov ax, [si+6]
    call print_hex_word
    mov dx, msg_trace_order
    call print_dos
    mov al, [si+8]
    call print_hex_byte
    mov dx, msg_trace_tick
    call print_dos
    mov al, [si+9]
    call print_hex_byte
    mov dx, msg_trace_row
    call print_dos
    mov ax, [si+10]
    call print_hex_word
    mov dx, msg_trace_state
    call print_dos
    mov al, [si+12]
    call print_hex_byte
    mov dx, msg_trace_error
    call print_dos
    mov al, [si+13]
    call print_hex_byte
    mov dx, msg_trace_down
    call print_dos
    mov al, [si+14]
    call print_hex_byte
    mov dx, msg_trace_up
    call print_dos
    mov al, [si+15]
    call print_hex_byte
    mov dx, msg_trace_level
    call print_dos
    mov al, [si+16]
    call print_hex_byte
    mov dx, msg_trace_pic
    call print_dos
    mov al, [si+17]
    call print_hex_byte
    mov dx, msg_trace_songs
    call print_dos
    mov al, [si+18]
    call print_hex_byte
    mov dx, msg_trace_reload
    call print_dos
    mov al, [si+19]
    call print_hex_byte
    mov dx, msg_crlf
    call print_dos
    inc bx
    jmp .event
.done:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret
%endif

%ifdef DUMP_CODE
write_code_dump:
    cmp byte [code_dumped], 1
    jne .done
    mov dx, code_dump_filename
    xor cx, cx
    mov ah, 3Ch
    int 21h
    jc .done
    mov bx, ax
    mov dx, code_dump
    mov cx, 1000h
    mov ah, 40h
    int 21h
    mov ah, 3Eh
    int 21h
.done:
    ret
%endif

; The PSP tail belongs to the launcher, not to CAN2.EXE.  Parse switches in
; any order, and reject typos before touching the GF1.  OCP-style -vp, -vm,
; and -vs spellings are accepted; negative panning reverses L/R channels.
parse_command_line:
    mov byte [test_mode], 0
    mov byte [pan_percent], 60    ; v1.1's fixed GF1 positions were 3/12
    mov byte [pan_reverse], 0
    mov byte [pan_seen], 0
    mov byte [music_percent], 81  ; exact legacy master is 52/64
    mov byte [sfx_percent], 86    ; exact legacy master is 55/64
    mov byte [music_master], 52
    mov byte [sfx_master], 55
    mov byte [music_seen], 0
    mov byte [sfx_seen], 0
    mov byte [line_mute], 0
    mov byte [line_seen], 0
    xor cx, cx
    mov cl, [80h]
    mov si, 81h
.next:
    or cx, cx
    jz .success
    mov al, [si]
    dec cx
    inc si
    cmp al, ' '
    je .next
    cmp al, 9
    je .next
    cmp al, '/'
    je .switch
    cmp al, '-'
    jne .fail
.switch:
    or cx, cx
    jz .fail
    mov al, [si]
    inc si
    dec cx
    and al, 0DFh
    xor bh, bh
    cmp al, 'V'
    jne .kind
    mov bh, 1
    or cx, cx
    jz .fail
    mov al, [si]
    inc si
    dec cx
    and al, 0DFh
.kind:
    cmp al, 'T'
    je .test
    cmp al, 'P'
    je .pan
    cmp al, 'M'
    je .music
    cmp al, 'S'
    je .sfx
    cmp al, 'L'
    je .line
    jmp .fail
.test:
    or bh, bh
    jnz .fail
    cmp byte [test_mode], 0
    jne .fail
    mov byte [test_mode], 1
    jmp .token_end
.pan:
    cmp byte [pan_seen], 0
    jne .fail
    mov byte [pan_seen], 1
    mov byte [option_kind], 0
    or cx, cx
    jz .fail
    mov al, [si]
    cmp al, '='
    je .separator
    cmp al, ':'
    jne .sign
.separator:
    inc si
    dec cx
    or cx, cx
    jz .fail
.sign:
    mov al, [si]
    cmp al, '-'
    jne .plus
    mov byte [pan_reverse], 1
    jmp .skip_sign
.plus:
    cmp al, '+'
    jne .first_digit
.skip_sign:
    inc si
    dec cx
    or cx, cx
    jz .fail
.first_digit:
    mov di, si
    xor bx, bx
.digits:
    jcxz .number_done
    mov al, [si]
    cmp al, '0'
    jb .number_done
    cmp al, '9'
    ja .number_done
    sub al, '0'
    mov dl, al
    mov ax, bx
    shl bx, 1
    shl ax, 3
    add bx, ax
    xor dh, dh
    add bx, dx
    cmp bx, 100
    ja .fail
    inc si
    dec cx
    jmp .digits
.number_done:
    cmp si, di
    je .fail
    cmp byte [option_kind], 0
    jne .volume_value
    mov [pan_percent], bl
    jmp .token_end
.music:
    cmp byte [music_seen], 0
    jne .fail
    mov byte [music_seen], 1
    mov byte [option_kind], 1
    jmp .unsigned_value
.sfx:
    cmp byte [sfx_seen], 0
    jne .fail
    mov byte [sfx_seen], 1
    mov byte [option_kind], 2
.unsigned_value:
    or cx, cx
    jz .fail
    mov al, [si]
    cmp al, '='
    je .unsigned_separator
    cmp al, ':'
    jne .unsigned_plus
.unsigned_separator:
    inc si
    dec cx
    or cx, cx
    jz .fail
.unsigned_plus:
    cmp byte [si], '+'
    jne .first_digit
    inc si
    dec cx
    or cx, cx
    jz .fail
.volume_value:
    mov al, bl
    call percent_to_master
    cmp byte [option_kind], 1
    jne .store_sfx
    mov [music_percent], bl
    mov [music_master], al
    jmp .token_end
.store_sfx:
    mov [sfx_percent], bl
    mov [sfx_master], al
    jmp .token_end
.line:
    or bh, bh
    jnz .fail
    cmp byte [line_seen], 0
    jne .fail
    mov byte [line_seen], 1
    cmp cx, 2
    jb .fail
    mov al, [si]
    and al, 0DFh
    cmp al, 'O'
    jne .fail
    inc si
    dec cx
    mov al, [si]
    and al, 0DFh
    cmp al, 'N'
    je .line_on
    cmp al, 'F'
    jne .fail
    inc si
    dec cx
    or cx, cx
    jz .fail
    mov al, [si]
    and al, 0DFh
    cmp al, 'F'
    jne .fail
    inc si
    dec cx
    mov byte [line_mute], 1
    jmp .token_end
.line_on:
    inc si
    dec cx
    mov byte [line_mute], 0
.token_end:
    jcxz .success
    mov al, [si]
    cmp al, ' '
    je .next
    cmp al, 9
    je .next
    jmp .fail
.success:
    call set_music_pan
    clc
    ret
.fail:
    stc
    ret

; AL = percentage 0..100.  Return AL = rounded 0..64 master scalar.
percent_to_master:
    push bx
    xor ah, ah
    mov bl, 64
    mul bl
    add ax, 50
    mov bl, 100
    div bl
    pop bx
    ret

; Map a signed 0..100 percent width to GF1's discrete 0..15 pan register.
; Zero uses 7/7 (both channels centered).  +60 gives 3/12, exactly v1.1.
set_music_pan:
    mov al, [pan_percent]
    or al, al
    jnz .scale
    mov bl, 7
    mov bh, 7
    jmp .store
.scale:
    mov bl, 100
    sub bl, al
    mov al, bl
    mov bl, 15
    mul bl                      ; (100 - width) * 15
    add ax, 100                 ; rounded to nearest GF1 pan step
    xor dx, dx
    mov bx, 200
    div bx
    mov bl, al
    mov bh, 15
    sub bh, bl
    cmp byte [pan_reverse], 0
    je .store
    xchg bl, bh
.store:
    mov [music_pan], bl
    mov [music_pan+1], bh
    mov [music_pan+2], bh
    mov [music_pan+3], bl
    ret

show_music_pan:
    mov dx, msg_pan
    call print_dos
    mov dl, '+'
    cmp byte [pan_reverse], 0
    je .sign_ready
    mov dl, '-'
.sign_ready:
    mov ah, 02h
    int 21h
    mov al, [pan_percent]
    call print_decimal_byte
    mov dx, msg_pan_end
    call print_dos
    ret

show_audio_volumes:
    mov dx, msg_music_volume
    call print_dos
    mov al, [music_percent]
    call print_decimal_byte
    mov dx, msg_volume_percent
    call print_dos
    mov dx, msg_sfx_volume
    call print_dos
    mov al, [sfx_percent]
    call print_decimal_byte
    mov dx, msg_volume_percent
    call print_dos
    ret

show_line_mode:
    cmp byte [line_mute], 0
    jne .muted
    mov dx, msg_line_on
    call print_dos
    ret
.muted:
    mov dx, msg_line_off
    call print_dos
    ret

show_gus_config:
    mov dx, msg_gus_config
    call print_dos
    mov ax, [gus_base]
    call print_hex_word
    mov dx, msg_gus_dma
    call print_dos
    mov al, [gus_dma1]
    call print_decimal_byte
    mov dl, '/'
    mov ah, 02h
    int 21h
    mov al, [gus_dma2]
    call print_decimal_byte
    mov dx, msg_gus_irq
    call print_dos
    mov al, [gus_irq]
    call print_decimal_byte
    mov dl, '/'
    mov ah, 02h
    int 21h
    mov al, [gus_midi_irq]
    call print_decimal_byte
    mov dx, msg_crlf
    call print_dos
    ret

print_decimal_byte:
    push bx
    push cx
    push dx
    xor ah, ah
    mov bl, 10
    div bl
    mov bl, ah                   ; ones digit
    xor ah, ah
    mov dl, 10
    div dl
    mov bh, ah                   ; tens digit
    mov ch, al                   ; hundreds digit
    or al, al
    jz .tens
    add al, '0'
    mov dl, al
    mov ah, 02h
    int 21h
.tens:
    cmp ch, 0
    jne .print_tens
    cmp bh, 0
    jne .print_tens
    jmp .ones
.print_tens:
    mov dl, bh
    add dl, '0'
    mov ah, 02h
    int 21h
.ones:
    mov dl, bl
    add dl, '0'
    mov ah, 02h
    int 21h
    pop dx
    pop cx
    pop bx
    ret

exec_game:
    push cs
    pop ds
    push cs
    pop es
    mov word [exec_params], 0
    mov ax, [psp_segment]
    mov word [exec_params+2], exec_tail
    mov word [exec_params+4], ax
    mov word [exec_params+6], 5Ch
    mov word [exec_params+8], ax
    mov word [exec_params+10], 6Ch
    mov word [exec_params+12], ax
    mov dx, game_filename
    mov bx, exec_params
    mov ax, 4B00h
    int 21h
    jnc .done
    cmp ax, 2
    jne .done
    mov dx, game_filename_alt
    mov bx, exec_params
    mov ax, 4B00h
    int 21h
.done:
    ret

; ---------------------------------------------------------------------------
; ULTRASND parsing

parse_ultrasnd:
    push es
    mov ax, [2Ch]
    or ax, ax
    jz .fail
    mov es, ax
    xor di, di
.next_string:
    cmp byte [es:di], 0
    jne .compare
    cmp byte [es:di+1], 0
    je .fail
    inc di
    jmp .next_string
.compare:
    push di
    mov si, ultrasnd_key
    mov cx, 9
.compare_char:
    mov al, [es:di]
    cmp al, 'a'
    jb .already_upper
    cmp al, 'z'
    ja .already_upper
    sub al, 20h
.already_upper:
    cmp al, [si]
    jne .not_this
    inc di
    inc si
    loop .compare_char
    pop bx                       ; discard original string offset

    call parse_hex_component
    jc .fail
    mov [gus_base], ax
    call require_comma
    jc .fail
    call parse_dec_component
    jc .fail
    mov [gus_dma1], ax
    call require_comma
    jc .fail
    call parse_dec_component
    jc .fail
    mov [gus_dma2], ax
    call require_comma
    jc .fail
    call parse_dec_component
    jc .fail
    mov [gus_irq], ax
    call require_comma
    jc .fail
    call parse_dec_component
    jc .fail
    mov [gus_midi_irq], ax
    cmp byte [es:di], 0
    jne .fail

    mov ax, [gus_base]
    cmp ax, 210h
    jb .fail
    cmp ax, 260h
    ja .fail
    test al, 0Fh
    jnz .fail

    mov bx, [gus_dma1]
    cmp bx, 7
    ja .fail
    cmp byte [dma_lut+bx], 0
    je .fail
    mov bx, [gus_dma2]
    cmp bx, 7
    ja .fail
    cmp byte [dma_lut+bx], 0
    je .fail
    mov bx, [gus_irq]
    cmp bx, 15
    ja .fail
    cmp byte [irq_lut+bx], 0
    je .fail
    mov bx, [gus_midi_irq]
    cmp bx, 15
    ja .fail
    cmp byte [irq_lut+bx], 0
    je .fail
    pop es
    clc
    ret

.not_this:
    pop di
.skip_string:
    cmp byte [es:di], 0
    je .past_string
    inc di
    jmp .skip_string
.past_string:
    inc di
    jmp .next_string
.fail:
    pop es
    stc
    ret

require_comma:
    cmp byte [es:di], ','
    jne .bad
    inc di
    clc
    ret
.bad:
    stc
    ret

parse_hex_component:
    xor bx, bx
    xor cx, cx
.loop:
    mov al, [es:di]
    cmp al, ','
    je .end
    or al, al
    jz .end
    cmp al, '0'
    jb .bad
    cmp al, '9'
    jbe .number
    and al, 0DFh
    cmp al, 'A'
    jb .bad
    cmp al, 'F'
    ja .bad
    sub al, 'A'-10
    jmp .add
.number:
    sub al, '0'
.add:
    shl bx, 4
    xor ah, ah
    add bx, ax
    inc di
    inc cx
    jmp .loop
.end:
    jcxz .bad
    mov ax, bx
    clc
    ret
.bad:
    stc
    ret

parse_dec_component:
    xor bx, bx
    xor cx, cx
.loop:
    mov al, [es:di]
    cmp al, ','
    je .end
    or al, al
    jz .end
    cmp al, '0'
    jb .bad
    cmp al, '9'
    ja .bad
    sub al, '0'
    xor ah, ah
    push ax
    mov ax, bx
    mov dx, 10
    mul dx
    mov bx, ax
    pop ax
    add bx, ax
    inc di
    inc cx
    jmp .loop
.end:
    jcxz .bad
    mov ax, bx
    clc
    ret
.bad:
    stc
    ret

; ---------------------------------------------------------------------------
; GF1 low-level setup

setup_gus_ports:
    mov ax, [gus_base]
    mov dx, ax
    add dx, 102h
    mov [gus_voice_port], dx
    inc dx
    mov [gus_command_port], dx
    inc dx
    mov [gus_data_low_port], dx
    inc dx
    mov [gus_data_high_port], dx
    mov dx, ax
    add dx, 006h
    mov [gus_status_port], dx
    add dx, 2
    mov [gus_timer_control_port], dx
    inc dx
    mov [gus_timer_data_port], dx
    mov dx, ax
    add dx, 107h
    mov [gus_dram_port], dx
    ret

gus_set_interface:
    pushf
    cli
    xor cx, cx
    mov bx, [gus_irq]
    mov cl, [irq_lut+bx]
    mov bx, [gus_midi_irq]
    mov al, [irq_lut+bx]
    shl al, 3
    or cl, al
    mov ax, [gus_irq]
    cmp ax, [gus_midi_irq]
    jne .irq_ready
    or cl, 40h
.irq_ready:
    mov [irq_latch], cl

    xor cx, cx
    mov bx, [gus_dma1]
    mov cl, [dma_lut+bx]
    mov bx, [gus_dma2]
    mov al, [dma_lut+bx]
    shl al, 3
    or cl, al
    mov ax, [gus_dma1]
    cmp ax, [gus_dma2]
    jne .dma_ready
    or cl, 40h
.dma_ready:
    mov [dma_latch], cl

    ; Unlock and reset the original GF1 digital ASIC interface.
    mov dx, [gus_base]
    add dx, 0Fh
    mov al, 05h
    out dx, al
    mov dx, [gus_base]
    mov al, 0Bh                  ; line/mic/output off, GF1 IRQ enabled
    out dx, al
    add dx, 0Bh
    xor al, al
    out dx, al
    mov dx, [gus_base]
    add dx, 0Fh
    xor al, al
    out dx, al

    ; Program the DRAM/ADC DMA and GF1/MIDI IRQ latches twice, as
    ; prescribed by the GF1 hardware interface sequence.
    mov dx, [gus_base]
    mov al, 0Bh
    out dx, al
    add dx, 0Bh
    mov al, [dma_latch]
    or al, 80h
    out dx, al
    mov dx, [gus_base]
    mov al, 4Bh
    out dx, al
    add dx, 0Bh
    mov al, [irq_latch]
    out dx, al
    mov dx, [gus_base]
    mov al, 0Bh
    out dx, al
    add dx, 0Bh
    mov al, [dma_latch]
    out dx, al
    mov dx, [gus_base]
    mov al, 4Bh
    out dx, al
    add dx, 0Bh
    mov al, [irq_latch]
    out dx, al
    mov dx, [gus_voice_port]
    xor al, al
    out dx, al
    mov dx, [gus_base]
    mov al, 08h                  ; line input, output and GF1 IRQ on; mic off
    out dx, al
    mov dx, [gus_voice_port]
    xor al, al
    out dx, al
    popf
    ret

gus_reset:
    pushf
    cli
    mov dx, [gus_command_port]
    mov al, 4Ch
    out dx, al
    mov dx, [gus_data_high_port]
    xor al, al
    out dx, al
    call gf1_delay
    call gf1_delay
    mov dx, [gus_command_port]
    mov al, 4Ch
    out dx, al
    mov dx, [gus_data_high_port]
    mov al, 01h
    out dx, al
    call gf1_delay
    call gf1_delay

    mov dx, [gus_base]
    add dx, 100h
    mov al, 03h
    out dx, al
    call gf1_delay
    xor al, al
    out dx, al

    mov dx, [gus_command_port]
    mov al, 41h
    out dx, al
    mov dx, [gus_data_high_port]
    xor al, al
    out dx, al
    mov dx, [gus_command_port]
    mov al, 45h
    out dx, al
    mov dx, [gus_data_high_port]
    xor al, al
    out dx, al
    mov dx, [gus_command_port]
    mov al, 49h
    out dx, al
    mov dx, [gus_data_high_port]
    xor al, al
    out dx, al

    mov dx, [gus_command_port]
    mov al, 0Eh
    out dx, al
    mov dx, [gus_data_high_port]
    mov al, 0CDh                  ; 14 active voices: (14-1) | C0
    out dx, al

    call gus_clear_pending
    xor si, si
.voice_loop:
    mov dx, [gus_voice_port]
    mov ax, si
    out dx, al
    mov dx, [gus_command_port]
    xor al, al
    out dx, al
    mov dx, [gus_data_high_port]
    mov al, 03h
    out dx, al
    mov dx, [gus_command_port]
    mov al, 0Dh
    out dx, al
    mov dx, [gus_data_high_port]
    mov al, 03h
    out dx, al
    call gf1_delay

    mov dx, [gus_command_port]
    mov al, 01h
    out dx, al
    mov dx, [gus_data_low_port]
    mov ax, 0400h
    out dx, ax
    mov dx, [gus_command_port]
    mov al, 09h
    out dx, al
    mov dx, [gus_data_low_port]
    xor ax, ax
    out dx, ax
    mov dx, [gus_command_port]
    mov al, 0Ch
    out dx, al
    mov dx, [gus_data_high_port]
    mov al, 07h
    out dx, al
    inc si
    cmp si, ACTIVE_VOICES
    jb .voice_loop

    call gus_clear_pending
    mov dx, [gus_command_port]
    mov al, 4Ch
    out dx, al
    mov dx, [gus_data_high_port]
    mov al, 07h                  ; reset released, DAC and master IRQ enabled
    out dx, al
    popf
    ret

gus_clear_pending:
    push ax
    push dx
    mov dx, [gus_status_port]
    in al, dx
    mov dx, [gus_command_port]
    mov al, 41h
    out dx, al
    mov dx, [gus_data_high_port]
    in al, dx
    mov dx, [gus_command_port]
    mov al, 49h
    out dx, al
    mov dx, [gus_data_high_port]
    in al, dx
    mov dx, [gus_command_port]
    mov al, 8Fh
    out dx, al
    mov dx, [gus_data_high_port]
    in al, dx
    pop dx
    pop ax
    ret

gf1_delay:
    push ax
    push cx
    push dx
    mov dx, [gus_dram_port]
    mov cx, 7
.wait:
    in al, dx
    loop .wait
    pop dx
    pop cx
    pop ax
    ret

gus_probe:
    mov word [dram_addr_low], 0
    mov word [dram_addr_high], 0
    mov bl, 0AAh
    call gus_poke
    mov word [dram_addr_low], 1
    mov bl, 055h
    call gus_poke
    mov word [dram_addr_low], 0
    call gus_peek
    mov [probe_value0], al
    cmp al, 0AAh
    jne .fail
    mov word [dram_addr_low], 1
    call gus_peek
    mov [probe_value1], al
    cmp al, 055h
    jne .fail
    clc
    ret
.fail:
    stc
    ret

gus_poke:
    push ax
    push dx
    pushf
    cli
    mov dx, [gus_command_port]
    mov al, 43h
    out dx, al
    mov dx, [gus_data_low_port]
    mov ax, [dram_addr_low]
    out dx, ax
    mov dx, [gus_command_port]
    mov al, 44h
    out dx, al
    mov dx, [gus_data_high_port]
    mov ax, [dram_addr_high]
    out dx, al
    mov dx, [gus_dram_port]
    mov al, bl
    out dx, al
    popf
    pop dx
    pop ax
    ret

gus_peek:
    push dx
    pushf
    cli
    mov dx, [gus_command_port]
    mov al, 43h
    out dx, al
    mov dx, [gus_data_low_port]
    mov ax, [dram_addr_low]
    out dx, ax
    mov dx, [gus_command_port]
    mov al, 44h
    out dx, al
    mov dx, [gus_data_high_port]
    mov ax, [dram_addr_high]
    out dx, al
    mov dx, [gus_dram_port]
    in al, dx
    mov [peek_value], al
    popf
    pop dx
    mov al, [peek_value]
    ret

; DS:SI = bytes, CX = count.  dram_addr_* is advanced by count.
gus_upload:
    push ax
    push bx
    push cx
    push dx
    push si
    pushf
    cli
    mov dx, [gus_command_port]
    mov al, 44h
    out dx, al
    mov dx, [gus_data_high_port]
    mov ax, [dram_addr_high]
    out dx, al
.byte:
    mov dx, [gus_command_port]
    mov al, 43h
    out dx, al
    mov dx, [gus_data_low_port]
    mov ax, [dram_addr_low]
    out dx, ax
    mov dx, [gus_dram_port]
    lodsb
    xor al, 80h                   ; AMF/SMP data is unsigned; GF1 PCM is signed
    out dx, al
    inc word [dram_addr_low]
    jnz .next
    inc word [dram_addr_high]
    mov dx, [gus_command_port]
    mov al, 44h
    out dx, al
    mov dx, [gus_data_high_port]
    mov ax, [dram_addr_high]
    out dx, al
.next:
    loop .byte
    popf
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ---------------------------------------------------------------------------
; Initial SFX upload.  Each source file remains external and unmodified.  A
; missing/truncated file disables only that effect; this is important for the
; commonly circulated incomplete installation, which lacks DIE1/2/3.SMP.

load_sfx_bank:
    mov word [sfx_present_mask], 0
    mov byte [missing_sfx_count], 0
    xor di, di
.next_file:
    mov bx, di
    shl bx, 1
    mov dx, [sfx_filename_table+bx]
    mov ax, 3D00h
    int 21h
    jc .missing
    mov [file_handle], ax
    mov bx, di
    shl bx, 1
    mov ax, [sfx_offsets+bx]
    mov [dram_addr_low], ax
    mov word [dram_addr_high], 0
    mov ax, [sfx_lengths+bx]
    mov [bytes_remaining], ax
.read:
    mov cx, [bytes_remaining]
    jcxz .loaded
    cmp cx, IO_BUFFER_BYTES
    jbe .size_ready
    mov cx, IO_BUFFER_BYTES
.size_ready:
    mov bx, [file_handle]
    mov dx, io_buffer
    mov ah, 3Fh
    int 21h
    jc .read_failed
    cmp ax, cx
    jne .read_failed
    push cx
    mov si, io_buffer
    call gus_upload
    pop cx
    sub [bytes_remaining], cx
    jmp .read
.loaded:
    mov bx, [file_handle]
    mov ah, 3Eh
    int 21h
    mov word [file_handle], 0FFFFh
    mov cx, di
    mov ax, 1
    shl ax, cl
    or [sfx_present_mask], ax
    jmp .advance
.read_failed:
    mov bx, [file_handle]
    mov ah, 3Eh
    int 21h
    mov word [file_handle], 0FFFFh
.missing:
    inc byte [missing_sfx_count]
.advance:
    inc di
    cmp di, SFX_COUNT
    jb .next_file
    cmp byte [missing_sfx_count], 0
    je .done
    mov dx, msg_missing_sfx
    call print_dos
    mov al, [missing_sfx_count]
    call print_decimal_byte
    mov dx, msg_missing_sfx_end
    call print_dos
.done:
    clc
    ret

; ---------------------------------------------------------------------------
; Interrupt vector management and in-memory Cannon Fodder 2 patch

install_vectors:
    mov ax, 3521h
    int 21h
    mov [old_int21], bx
    mov [old_int21+2], es
    mov ax, 3565h
    int 21h
    mov [old_int65], bx
    mov [old_int65+2], es
    mov ax, 3566h
    int 21h
    mov [old_int66], bx
    mov [old_int66+2], es
    mov ax, 3564h
    int 21h
    mov [old_int64], bx
    mov [old_int64+2], es

    mov ax, [gus_irq]
    cmp ax, 7
    jbe .master_vector
    add ax, 68h
    jmp .vector_ready
.master_vector:
    add ax, 08h
.vector_ready:
    mov [irq_vector], al
    mov ah, 35h
    int 21h
    mov [old_irq], bx
    mov [old_irq+2], es

    in al, 21h
    mov [old_pic_master], al
    in al, 0A1h
    mov [old_pic_slave], al

    push ds
    push cs
    pop ds
    mov dx, int65_handler
    mov ax, 2565h
    int 21h
    mov dx, int66_handler
    mov ax, 2566h
    int 21h
    mov dx, int64_handler
    mov ax, 2564h
    int 21h
    mov dx, gus_irq_handler
    mov ah, 25h
    mov al, [irq_vector]
    int 21h
    mov dx, int21_handler
    mov ax, 2521h
    int 21h
    pop ds

    pushf
    cli
    mov ax, [gus_irq]
    cmp ax, 7
    ja .unmask_slave
    mov cl, al
    mov bl, 1
    shl bl, cl
    not bl
    in al, 21h
    and al, bl
    out 21h, al
    jmp .unmask_done
.unmask_slave:
    sub al, 8
    mov cl, al
    mov bl, 1
    shl bl, cl
    not bl
    in al, 0A1h
    and al, bl
    out 0A1h, al
    in al, 21h
    and al, 0FBh
    out 21h, al
.unmask_done:
    popf
    mov byte [vectors_installed], 1
    ret

restore_vectors:
    cmp byte [vectors_installed], 1
    jne .done
    call gus_timer_stop

    pushf
    cli
    mov al, [old_pic_master]
    out 21h, al
    mov al, [old_pic_slave]
    out 0A1h, al
    popf

    mov dx, [old_irq]
    mov ax, [old_irq+2]
    mov ds, ax
    mov ah, 25h
    mov al, [cs:irq_vector]
    int 21h
    mov dx, [cs:old_int65]
    mov ax, [cs:old_int65+2]
    mov ds, ax
    mov ax, 2565h
    int 21h
    mov dx, [cs:old_int66]
    mov ax, [cs:old_int66+2]
    mov ds, ax
    mov ax, 2566h
    int 21h
    mov dx, [cs:old_int64]
    mov ax, [cs:old_int64+2]
    mov ds, ax
    mov ax, 2564h
    int 21h
    mov dx, [cs:old_int21]
    mov ax, [cs:old_int21+2]
    mov ds, ax
    mov ax, 2521h
    int 21h
    push cs
    pop ds
    mov byte [vectors_installed], 0
.done:
    ret

cleanup:
    mov byte [music_active], 0
    call gus_quiet
    call restore_vectors
    cmp byte [game_line_muted], 1
    jne .done
    mov dx, [gus_base]
    mov al, 08h
    out dx, al
    mov byte [game_line_muted], 0
.done:
    ret

; CRC-16/CCITT, initial value FFFFh, polynomial 1021h.
; Input ES:DI = region and CX = byte count; output AX = fingerprint.
crc16_region:
    mov ax, 0FFFFh
.byte:
    xor ah, [es:di]
    inc di
    mov bl, 8
.bit:
    shl ax, 1
    jnc .next_bit
    xor ax, 1021h
.next_bit:
    dec bl
    jnz .bit
    loop .byte
    ret

; Called before the previous DOS INT 21 handler.  Walk the short DOS MCB chain
; after the retained launcher block to identify the child PSP, derive its MZ
; load-module base, then validate every call site before writing the complete
; patch set.  A partial or wrong-version image is never modified.
int21_handler:
    pushf
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es
    push cs
    pop ds
    cld

%ifdef DIAGNOSTIC_ABORT
    inc word [diag_int21_calls]
    cmp byte [diag_abort_armed], 1
    je .chain
%endif
    cmp byte [test_mode], 1
    je .chain
%ifdef NO_PATCH_SCAN
    jmp .chain
%endif
    cmp ah, 4Bh                    ; parent EXEC: child image does not exist yet
    je .chain
    cmp byte [patch_installed], 1
    je .chain
.scan_start:
    mov ax, [patch_scan_start]
                                    ; first MCB after the retained parent block
    mov cx, 64                     ; normally only environment + child PSP
.mcb_loop:
    cmp ax, 0A000h
    jae .chain
    mov es, ax
    mov dl, [es:0]
    cmp dl, 'M'
    je .mcb_valid
    cmp dl, 'Z'
    jne .chain
.mcb_valid:
    mov bx, [es:3]                 ; allocation size in paragraphs
    mov dx, [es:1]                 ; owner PSP
    inc ax                         ; allocation segment
    cmp dx, ax
    je .child_psp
    cmp byte [es:0], 'Z'           ; never walk beyond the final MCB
    je .chain
    add ax, bx                     ; next MCB = block segment + block size
    loop .mcb_loop
    jmp .chain
.child_psp:
%ifdef DIAGNOSTIC_ABORT
    mov [diag_child_psp], ax
    mov byte [diag_child_seen], 1
    mov byte [diag_stage], 1
%endif
    add ax, 10h                    ; MZ load module follows the 256-byte PSP
    mov [candidate_base], ax
%ifdef DIAGNOSTIC_ABORT
    mov [diag_candidate_base], ax
%endif
    add ax, GAME_MUSIC_SEG
    mov es, ax
    mov di, PATCH_MUSIC_OFF
    mov cx, MUSIC_GUARD_LEN
    call crc16_region
    cmp ax, MUSIC_GUARD_CRC
    jne .candidate_fail
%ifdef DIAGNOSTIC_ABORT
    mov byte [diag_stage], 2
%endif
    mov ax, [candidate_base]

    ; Validate the audio wrapper entry points.
    add ax, GAME_AUDIO_SEG
    mov es, ax
    mov di, PATCH_SFX_OFF
    mov cx, SFX_GUARD_LEN
    call crc16_region
    cmp ax, SFX_GUARD_CRC
    jne .candidate_fail
%ifdef DIAGNOSTIC_ABORT
    mov byte [diag_stage], 3
%endif
    mov di, PATCH_INIT_OFF
    mov cx, INIT_GUARD_LEN
    call crc16_region
    cmp ax, INIT_GUARD_CRC
    jne .candidate_fail
    mov di, PATCH_CLEANUP_OFF
    mov cx, CLEANUP_GUARD_LEN
    call crc16_region
    cmp ax, CLEANUP_GUARD_CRC
    jne .candidate_fail
    mov di, PATCH_PRELOAD_OFF
    mov cx, PRELOAD_GUARD_LEN
    call crc16_region
    cmp ax, PRELOAD_GUARD_CRC
    jne .candidate_fail
%ifdef DIAGNOSTIC_ABORT
    mov byte [diag_stage], 4
%endif

    ; Validate the old per-frame mixer update call.
    mov ax, [candidate_base]
    add ax, GAME_MAIN_SEG
    mov es, ax
    mov di, PATCH_MIXCALL_OFF
    mov cx, MIXCALL_GUARD_LEN
    call crc16_region
    cmp ax, MIXCALL_GUARD_CRC
    jne .candidate_fail
    mov dx, [candidate_base]
    add dx, GAME_VOLUME_SEG
    cmp word [es:PATCH_MIXCALL_OFF+3], dx
    jne .candidate_fail
%ifdef DIAGNOSTIC_ABORT
    mov byte [diag_stage], 5
%endif

    ; Validate the common DSMI master-volume target.
    mov ax, [candidate_base]
    add ax, GAME_VOLUME_SEG
    mov es, ax
    mov di, PATCH_VOLUME_OFF
    mov cx, VOLUME_GUARD_LEN
    call crc16_region
    cmp ax, VOLUME_GUARD_CRC
    jne .candidate_fail
%ifdef DIAGNOSTIC_ABORT
    mov byte [diag_stage], 6
%endif

    ; All fingerprints matched.  Patch software interrupt shims and replace
    ; the old software-mixer update with our bounded clock-recovery callback.
    ; Keep interrupts disabled until all five bytes of the far call and the
    ; installed flag agree; IRQ0 is itself one of the callers being changed.
    ; The original executable on disk is never changed.
    pushf
    cli
    mov ax, [candidate_base]
    add ax, GAME_MUSIC_SEG
    mov es, ax
    mov byte [es:PATCH_MUSIC_OFF], 0CDh
    mov byte [es:PATCH_MUSIC_OFF+1], 65h
    mov byte [es:PATCH_MUSIC_OFF+2], 0CBh

    mov ax, [candidate_base]
    add ax, GAME_AUDIO_SEG
    mov es, ax
    mov byte [es:PATCH_SFX_OFF], 0CDh
    mov byte [es:PATCH_SFX_OFF+1], 66h
    mov byte [es:PATCH_SFX_OFF+2], 0CBh
    mov byte [es:PATCH_INIT_OFF], 0CBh
    mov byte [es:PATCH_CLEANUP_OFF], 0CBh
    mov byte [es:PATCH_PRELOAD_OFF], 0CBh

    mov ax, [candidate_base]
    add ax, GAME_MAIN_SEG
    mov es, ax
    mov byte [es:PATCH_MIXCALL_OFF], 09Ah
    mov word [es:PATCH_MIXCALL_OFF+1], game_clock_handler
    mov ax, cs
    mov word [es:PATCH_MIXCALL_OFF+3], ax

    mov ax, [candidate_base]
    add ax, GAME_VOLUME_SEG
    mov es, ax
    mov byte [es:PATCH_VOLUME_OFF], 0CDh
    mov byte [es:PATCH_VOLUME_OFF+1], 64h
    mov byte [es:PATCH_VOLUME_OFF+2], 0CBh

    mov ax, [candidate_base]
    mov [patch_image_base], ax
    cmp byte [line_mute], 0
    je .line_ready
    cmp byte [game_line_muted], 1
    je .line_ready
    mov dx, [gus_base]
    mov al, 09h
    out dx, al
    mov byte [game_line_muted], 1
.line_ready:
    mov byte [patch_installed], 1
    popf
%ifdef SFX_INTEGRATION_TEST
    ; Test-only build: enter the freshly patched game SFX wrapper once.  This
    ; exercises the exact far-call -> INT 66h -> GF1 path without altering the
    ; production binary or requiring automated mouse input.
    mov word [test_sfx_entry], PATCH_SFX_OFF
    mov ax, [candidate_base]
    add ax, GAME_AUDIO_SEG
    mov [test_sfx_entry+2], ax
    xor ax, ax                      ; BIRD.SMP
    mov bx, 8363
    mov cx, 64
    call far [test_sfx_entry]
%endif
%ifdef DIAGNOSTIC_ABORT
    mov byte [diag_stage], 7
%endif
    jmp .chain
.candidate_fail:
    mov word [candidate_base], 0
    jmp .chain
.chain:
    pop es
    pop ds
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf
%ifdef DIAGNOSTIC_ABORT
    cmp byte [cs:diag_abort_armed], 1
    je .chain_old
    cmp word [cs:diag_int21_calls], 20
    jb .chain_old
    mov byte [cs:diag_abort_armed], 1
    push bp
    mov bp, sp
    mov word [ss:bp+2], diagnostic_abort_stub
    mov word [ss:bp+4], cs
    pop bp
.chain_old:
%endif
    jmp far [cs:old_int21]

%ifdef DIAGNOSTIC_ABORT
diagnostic_abort_stub:
    mov ax, 4C00h
    int 21h
%endif

; ---------------------------------------------------------------------------
; Song/SFX software interrupt entry points

int65_handler:
    mov [cs:requested_song], al
%ifdef TRACE_BUILD
    push ax
    mov ah, al
    mov al, 'S'
    call trace_event
    pop ax
%endif
    pushad
    push ds
    push es
    push cs
    pop ds
    push cs
    pop es
    cld
    sti
%ifdef FADE_INTEGRATION_TEST
    ; Test-only: arm a short real game fade before the first song request.  A
    ; correct shim must sleep until the game's timer retires it, then load the
    ; song.  This exercises the exact guarded child-data address and IRQ path.
    cmp word [songs_loaded], 0
    jne .fade_test_armed
    mov word [fade_wait_wakeups], 0
    mov byte [fade_wait_completed], 0
    mov ax, [patch_image_base]
    add ax, GAME_DATA_SEG
    mov es, ax
    mov word [es:GAME_FADE_DOWN_OFF], 0
    mov word [es:GAME_FADE_UP_OFF], 0FFFFh
    mov word [es:GAME_FADE_LEVEL_OFF], 4
    push cs
    pop es
.fade_test_armed:
%endif
    call wait_for_game_fade
%ifdef TRACE_BUILD
    push ax
    mov ah, [requested_song]
    mov al, 'W'
    call trace_event
    pop ax
%endif
    call load_requested_song
    call arm_game_fade_in
%ifdef TRACE_BUILD
    push ax
    mov ah, [requested_song]
    mov al, 'L'
    call trace_event
    pop ax
%endif
%ifdef INTEGRATION_TEST
    ; Test-only build: let the first game-requested song run for five seconds,
    ; then terminate the child so the parent can report counters and clean up.
    cmp word [songs_loaded], 0
    je .integration_done
%ifdef FADE_INTEGRATION_TEST
    call run_fade_transition_test
%endif
%ifdef SELECTOR_INTEGRATION_TEST
    call run_unknown_selector_test
%endif
    mov bx, [total_ticks]
    add bx, SELFTEST_TICKS
.integration_wait:
    cmp word [total_ticks], bx
    jae .integration_exit
    sti
    hlt
    jmp .integration_wait
.integration_exit:
    mov ax, 4C00h
    int 21h
.integration_done:
%endif
    cli
    pop es
    pop ds
    popad
    iret

; The original song-selection entry point does not replace a module until the
; game's 64-step music fade-out has finished.  Returning early leaves that
; fade armed: it then attenuates the newly loaded song to silence and later
; screens inherit the stale state.  Keep the old GF1 song advancing while the
; game timer completes the fade, sleeping between interrupts to avoid a busy
; loop.  The data location is used only after the exact runtime image guards
; have matched; /T has no child image and therefore skips this synchronization.
wait_for_game_fade:
    cmp byte [test_mode], 0
    jne .done
    cmp byte [patch_installed], 1
    jne .done
    call find_song_filename
    jc .done                         ; unknown IDs returned immediately before
    mov ax, [patch_image_base]
    add ax, GAME_DATA_SEG
    mov es, ax
.wait:
    cmp word [es:GAME_FADE_DOWN_OFF], 0FFFFh
    je .ready
%ifdef FADE_INTEGRATION_TEST
    inc word [fade_wait_wakeups]
%endif
    sti
    hlt
    jmp .wait
.ready:
    push cs
    pop es
%ifdef FADE_INTEGRATION_TEST
    cmp word [fade_wait_wakeups], 0
    je .done
    mov byte [fade_wait_completed], 1
%endif
.done:
    ret

; A successful original song change arms the game's 64-step fade-in after the
; replacement module has started.  The INT 65h shim must reproduce that state
; transition or a song loaded after fade-down remains at master volume zero.
; Unknown selectors and failed loads leave the game fade state untouched.
arm_game_fade_in:
    cmp byte [test_mode], 0
    jne .done
    cmp byte [patch_installed], 1
    jne .done
    mov al, [requested_song]
    cmp al, [current_song]
    jne .done
    cmp byte [music_active], 1
    jne .done
    cmp byte [timer_started], 1
    jne .done
    push ax
    push es
    pushf
    cli
    mov byte [game_music_master], 0
    mov ax, [patch_image_base]
    add ax, GAME_DATA_SEG
    mov es, ax
    mov word [es:GAME_FADE_UP_OFF], 0
    mov word [es:GAME_FADE_DOWN_OFF], 0FFFFh
    mov word [es:GAME_FADE_LEVEL_OFF], 0
    popf
    pop es
    pop ax
.done:
    ret

%ifdef FADE_INTEGRATION_TEST
; After the first real game request has passed the forced short fade above,
; exercise a second transition to LOADER.AMF.  The old tracker must continue
; receiving GF1 timer IRQs during the wait, and the replacement module must
; become current only after the game's fade-down flag retires.
run_fade_transition_test:
    cmp byte [fade_wait_completed], 1
    jne .done
    mov ax, [total_ticks]
    mov [fade_transition_tick_start], ax
    mov word [fade_wait_wakeups], 0
    mov byte [fade_wait_completed], 0
    mov ax, [patch_image_base]
    add ax, GAME_DATA_SEG
    mov es, ax
    mov word [es:GAME_FADE_DOWN_OFF], 0
    mov word [es:GAME_FADE_UP_OFF], 0FFFFh
    mov word [es:GAME_FADE_LEVEL_OFF], 8
    push cs
    pop es
    mov byte [requested_song], 8      ; LOADER.AMF
    call wait_for_game_fade
    cmp byte [fade_wait_completed], 1
    jne .done
    mov ax, [total_ticks]
    cmp ax, [fade_transition_tick_start]
    je .done
    call load_requested_song
    cmp byte [current_song], 8
    jne .done
    cmp byte [song_error], 0
    jne .done
    cmp word [songs_loaded], 2
    jb .done
    call arm_game_fade_in
    mov ax, [patch_image_base]
    add ax, GAME_DATA_SEG
    mov es, ax
    cmp word [es:GAME_FADE_UP_OFF], 0
    jne .restore_es
    cmp word [es:GAME_FADE_DOWN_OFF], 0FFFFh
    jne .restore_es
    cmp word [es:GAME_FADE_LEVEL_OFF], 0
    jne .restore_es
.fade_in_wait:
    cmp word [es:GAME_FADE_UP_OFF], 0FFFFh
    je .fade_in_done
    sti
    hlt
    jmp .fade_in_wait
.fade_in_done:
    cmp word [es:GAME_FADE_LEVEL_OFF], 64
    jne .restore_es
    push cs
    pop es
    cmp byte [game_music_master], 64
    jne .done
    mov byte [fade_test_pass], 1
    jmp .done
.restore_es:
    push cs
    pop es
.done:
    ret
%endif

%ifdef SELECTOR_INTEGRATION_TEST
; The original selector ignores unknown IDs.  Verify that a known resident
; module remains active and is neither restarted nor counted again when the
; game emits one of its non-song selector values.
run_unknown_selector_test:
    mov byte [selector_test_pass], 0
    cmp byte [current_song], 8
    jne .done
    mov ax, [songs_loaded]
    mov [selector_test_song_count], ax
    mov byte [requested_song], 50
    call load_requested_song
    cmp byte [current_song], 8
    jne .done
    cmp byte [music_active], 1
    jne .done
    cmp byte [timer_started], 1
    jne .done
    mov ax, [songs_loaded]
    cmp ax, [selector_test_song_count]
    jne .done
    mov byte [selector_test_pass], 1
.done:
    ret
%endif

int66_handler:
    mov [cs:requested_sfx], al
    mov [cs:requested_sfx_rate], bx
    mov [cs:requested_sfx_volume], cl
    pushad
    push ds
    push es
    push cs
    pop ds
    push cs
    pop es
    call play_requested_sfx
    pop es
    pop ds
    popad
    iret

; The verified game already calls the replaced software-mixer slot once from
; its approximately 50 Hz IRQ0 handler.  GF1 timer 1 remains the precise music
; clock.  This callback only supplies tracker ticks after two consecutive game
; ticks without a GF1 timer service, recovering from low-priority IRQ7/IRQ11
; starvation during fades and loading.  All caller state is preserved because
; this executes inside the game's interrupt handler rather than as a new IRQ.
game_clock_handler:
    pushf
    pushad
    push ds
    push es
    push cs
    pop ds
    push cs
    pop es
    cld
    call game_clock_tick
    pop es
    pop ds
    popad
    popf
    retf

game_clock_tick:
    cmp byte [patch_installed], 1
    jne .done
    cmp byte [music_active], 1
    jne .inactive

    ; DSMI advances at BPM/2.5 Hz.  At the game's measured 50 Hz this is
    ; tracker_tempo/125 ticks per game interrupt.  The fractional accumulator
    ; preserves the exact average tempo when the emergency clock is needed.
    xor ax, ax
    mov al, [tracker_tempo]
    add [clock_phase], ax
.expected:
    cmp word [clock_phase], GAME_CLOCK_DENOM
    jb .watchdog
    sub word [clock_phase], GAME_CLOCK_DENOM
    inc word [clock_expected]
    jmp .expected

.watchdog:
    cmp byte [gf1_watchdog], 0FFh
    je .watchdog_ready
    inc byte [gf1_watchdog]
.watchdog_ready:
    cmp byte [gf1_watchdog], CLOCK_WATCHDOG_TICKS
    jb .done

    mov ax, [clock_expected]
    sub ax, [clock_delivered]
    jle .done                       ; equal, or GF1 is at most slightly ahead
    cmp ax, CLOCK_CATCHUP_LIMIT
    jbe .budget_ready
    mov ax, CLOCK_CATCHUP_LIMIT
.budget_ready:
    mov cx, ax
    cmp byte [clock_fallback_active], 1
    je .deliver
    mov byte [clock_fallback_active], 1
%ifdef TRACE_BUILD
    push ax
    mov ah, [gf1_watchdog]
    mov al, 'F'
    call trace_event
    pop ax
%endif
.deliver:
    push cx
    call deliver_tracker_tick
    inc word [clock_fallback_ticks]
    pop cx
    loop .deliver
    jmp .done

.inactive:
    mov byte [gf1_watchdog], 0
.done:
    ret

; The original master-volume routine receives two 32-bit cdecl arguments:
; channel (-1 for all) and level (0..64).  At interrupt entry, the low byte of
; the second argument is SS:[SP+14].  Preserve the user's /M ceiling and apply
; the game fade as a second scalar, then refresh the four music voices.
int64_handler:
    push bp
    mov bp, sp
    mov al, [ss:bp+16]
    pop bp
    cmp al, 64
    jbe .level_ok
    mov al, 64
.level_ok:
%ifdef TRACE_BUILD
    push ax
    mov ah, al
    mov al, 'V'
    call trace_event
    pop ax
%endif
    cmp [cs:game_music_master], al
    je .done
    mov [cs:game_music_master], al
    pushad
    push ds
    push es
    push cs
    pop ds
    xor di, di
.voice:
    mov al, [channel_volume+di]
    call music_volume_word
    mov bx, ax
    mov ax, di
    call gf1_voice_volume
    inc di
    cmp di, 4
    jb .voice
    pop es
    pop ds
    popad
.done:
    iret

%ifdef TRACE_BUILD
; Append one fixed-size event using only memory and port reads.  DOS is never
; called here.  AL is the event type and AH is its argument.  The routine
; preserves all 16-bit registers and the incoming flags, and briefly disables
; interrupts so a GF1 heartbeat cannot interleave with a game event.
trace_event:
    pushf
    cli
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push bp
    push ds
    push es
    mov bp, sp
    push cs
    pop ds
    mov bx, [trace_count]
    cmp bx, TRACE_EVENT_LIMIT
    jae .full
    mov di, bx
    shl di, 1
    shl di, 1
    mov dx, bx
    shl dx, 1
    shl dx, 1
    shl dx, 1
    shl dx, 1
    add di, dx                    ; index * (4 + 16)
    add di, trace_events
    mov ax, [ss:bp+16]            ; caller's type/argument pair
    mov [di], ax
    mov al, [current_song]
    mov [di+2], al
    mov al, [game_music_master]
    mov [di+3], al
    mov ax, [total_ticks]
    mov [di+4], ax
    mov word [di+6], 0FEFEh       ; no guarded child timer by default
    mov al, [tracker_order]
    mov [di+8], al
    mov al, [tracker_tick_count]
    mov [di+9], al
    mov ax, [tracker_row]
    mov [di+10], ax
    xor al, al
    cmp byte [music_active], 1
    jne .state_timer
    or al, 01h
.state_timer:
    cmp byte [timer_started], 1
    jne .state_patch
    or al, 02h
.state_patch:
    cmp byte [patch_installed], 1
    jne .state_fallback
    or al, 04h
.state_fallback:
    cmp byte [clock_fallback_active], 1
    jne .state_ready
    or al, 08h
.state_ready:
    mov [di+12], al
    mov al, [song_error]
    mov [di+13], al
    mov byte [di+14], 0FEh         ; no guarded child data by default
    mov byte [di+15], 0FEh
    mov byte [di+16], 0FEh
    cmp byte [patch_installed], 1
    jne .game_state_ready
    cmp byte [test_mode], 0
    jne .game_state_ready
    mov ax, [patch_image_base]
    add ax, GAME_DATA_SEG
    mov es, ax
    mov ax, [es:GAME_TIMER_TICKS_OFF]
    mov [di+6], ax
    mov al, [es:GAME_FADE_DOWN_OFF]
    mov [di+14], al
    mov al, [es:GAME_FADE_UP_OFF]
    mov [di+15], al
    mov al, [es:GAME_FADE_LEVEL_OFF]
    mov [di+16], al
.game_state_ready:
    in al, 21h
    mov [di+17], al
    mov ax, [songs_loaded]
    mov [di+18], al
    mov al, [timer_reload]
    mov [di+19], al
    inc word [trace_count]
    jmp .done
.full:
    inc word [trace_overflow]
.done:
    pop es
    pop ds
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf
    ret
%endif

; ---------------------------------------------------------------------------
; Module loading

load_requested_song:
    mov al, [requested_song]
    cmp al, [current_song]
    jne .new_song
    cmp al, 0FFh
    je .done
    ; The game can request the same selection again when returning to a state.
    ; Restart its already resident module without repeating disk or PIO work.
    mov byte [music_active], 0
    call gus_timer_stop
    call tracker_reset
    mov byte [music_active], 1
    call gus_timer_program
    jmp .done
.new_song:
    ; The game also emits selector values 50..54 that are absent from its own
    ; seven-entry song table.  Its original routine treats those values as a
    ; no-op.  Resolve first so an unmapped request cannot stop a valid module
    ; that was just selected for a loader or post-level screen.
    call find_song_filename
    jc .unknown_song
    mov [song_filename_ptr], dx
    mov byte [music_active], 0
    call mute_music_voices
    call gus_timer_stop
    mov word [file_handle], 0FFFFh
    mov dx, [song_filename_ptr]
    mov ax, 3D00h
    int 21h
    jc .open_error
    mov [file_handle], ax
    mov bx, ax
    mov cx, AMF_HEADER_BYTES
    mov dx, amf_header
    call dos_read_exact
    jc .load_error
    cmp word [amf_header], 4D41h       ; "AM"
    jne .format_error
    cmp byte [amf_header+2], 'F'
    jne .format_error
    cmp byte [amf_header+3], 0Eh       ; AMF 1.4 only
    jne .format_error
    mov al, [amf_header+36]
    or al, al
    jz .format_error
    cmp al, MAX_INSTRUMENTS
    ja .format_error
    mov [amf_instrument_count], al
    mov al, [amf_header+37]
    or al, al
    jz .format_error
    cmp al, MAX_PATTERNS
    ja .format_error
    mov [amf_pattern_count], al
    mov ax, [amf_header+38]
    or ax, ax
    jz .format_error
    cmp ax, MAX_LOGICAL_TRACKS
    ja .format_error
    mov [amf_logical_tracks], ax
    cmp byte [amf_header+40], 4
    jne .format_error
    mov al, [amf_header+73]
    cmp al, 123                    ; GF1 timer-1 range at 80 us/count
    jb .format_error
    mov [tracker_tempo], al
    mov al, [amf_header+74]
    or al, al
    jz .format_error
    mov [tracker_speed], al
    call set_module_pan

    ; Pattern records: row count followed by four logical track numbers.
    xor di, di
.pattern_loop:
    mov bx, [file_handle]
    mov cx, 10
    mov dx, io_buffer
    call dos_read_exact
    jc .load_error
    mov ax, [io_buffer]
    or ax, ax
    jz .format_error
    cmp ax, 256
    ja .format_error
    mov bx, di
    shl bx, 1
    mov [pattern_rows+bx], ax
    mov ax, di
    mov cl, 3
    shl ax, cl
    mov bx, ax
    mov ax, [io_buffer+2]
    mov [pattern_tracks+bx], ax
    mov ax, [io_buffer+4]
    mov [pattern_tracks+bx+2], ax
    mov ax, [io_buffer+6]
    mov [pattern_tracks+bx+4], ax
    mov ax, [io_buffer+8]
    mov [pattern_tracks+bx+6], ax
    inc di
    xor ax, ax
    mov al, [amf_pattern_count]
    cmp di, ax
    jb .pattern_loop

    ; Instrument records are 65 bytes in AMF 1.4.  Keep only hardware-facing
    ; metadata; names and sample bytes remain in the user's module file.
    xor di, di
.instrument_loop:
    mov bx, [file_handle]
    mov cx, 65
    mov dx, io_buffer
    call dos_read_exact
    jc .load_error
    mov bx, di
    shl bx, 1
    cmp word [io_buffer+52], 0
    jne .format_error                 ; this player supports <64 KiB samples
    mov ax, [io_buffer+50]
    mov [sample_length+bx], ax
    mov ax, [io_buffer+54]
    or ax, ax
    jnz .rate_ok
    mov ax, 8368
.rate_ok:
    mov [sample_rate+bx], ax
    mov al, [io_buffer+56]
    cmp al, 64
    jbe .volume_ok
    mov al, 64
.volume_ok:
    mov [sample_volume+di], al
    cmp word [io_buffer+59], 0
    jne .no_loop
    cmp word [io_buffer+63], 0
    jne .no_loop
    mov ax, [io_buffer+57]
    mov [sample_loop_start+bx], ax
    mov dx, [io_buffer+61]
    cmp dx, ax
    jbe .no_loop
    cmp dx, [sample_length+bx]
    ja .no_loop
    sub dx, ax
    mov [sample_loop_length+bx], dx
    jmp .instrument_next
.no_loop:
    mov word [sample_loop_start+bx], 0
    mov word [sample_loop_length+bx], 0
.instrument_next:
    inc di
    xor ax, ax
    mov al, [amf_instrument_count]
    cmp di, ax
    jb .instrument_loop

    ; Logical-to-physical track map.  Index zero is the implicit empty track.
    mov word [track_map], 0
    mov word [amf_physical_tracks], 0
    mov di, 1
.map_loop:
    mov bx, [file_handle]
    mov cx, 2
    mov dx, io_buffer
    call dos_read_exact
    jc .load_error
    mov ax, [io_buffer]
    cmp ax, MAX_PHYSICAL_TRACKS
    ja .format_error
    mov bx, di
    shl bx, 1
    mov [track_map+bx], ax
    cmp ax, [amf_physical_tracks]
    jbe .map_next
    mov [amf_physical_tracks], ax
.map_next:
    inc di
    cmp di, [amf_logical_tracks]
    jbe .map_loop

    ; Store sparse track triples.  Runtime playback walks one cursor per voice,
    ; so an empty row costs no parsing and only a handful of integer operations.
    mov word [track_data_used], 0
    mov di, 1
.track_loop:
    cmp di, [amf_physical_tracks]
    ja .tracks_done
    mov bx, [file_handle]
    mov cx, 3
    mov dx, io_buffer
    call dos_read_exact
    jc .load_error
    mov ax, [io_buffer]
    mov bx, di
    shl bx, 1
    mov [physical_track_count+bx], ax
    mov ax, [track_data_used]
    mov [physical_track_offset+bx], ax
    mov ax, [io_buffer]
    mov cx, 3
    mul cx
    or dx, dx
    jnz .format_error
    mov cx, ax
    add ax, [track_data_used]
    jc .format_error
    cmp ax, TRACK_BUFFER_BYTES
    ja .format_error
    mov [track_data_next], ax
    mov dx, track_data
    add dx, [track_data_used]
    mov bx, [file_handle]
    call dos_read_exact
    jc .load_error
    mov ax, [track_data_next]
    mov [track_data_used], ax
    inc di
    jmp .track_loop
.tracks_done:

    ; Stream all sample payloads directly to GF1 RAM beginning at 0x10000.
    ; This avoids both ISA DMA contention and a large conventional-memory copy.
    mov word [dram_addr_low], MUSIC_DRAM_LOW
    mov word [dram_addr_high], MUSIC_DRAM_HIGH
    xor di, di
.sample_loop:
    xor ax, ax
    mov al, [amf_instrument_count]
    cmp di, ax
    jae .samples_done
    mov bx, di
    shl bx, 1
    mov ax, [dram_addr_low]
    mov [sample_start_low+bx], ax
    mov ax, [dram_addr_high]
    mov [sample_start_high+bx], ax
    mov ax, [sample_length+bx]
    mov [bytes_remaining], ax
.sample_read:
    mov cx, [bytes_remaining]
    jcxz .sample_done
    cmp cx, IO_BUFFER_BYTES
    jbe .sample_size_ready
    mov cx, IO_BUFFER_BYTES
.sample_size_ready:
    mov bx, [file_handle]
    mov dx, io_buffer
    mov ah, 3Fh
    int 21h
    jc .load_error
    cmp ax, cx
    jne .load_error
    push cx
    mov si, io_buffer
    call gus_upload
    pop cx
    sub [bytes_remaining], cx
    jmp .sample_read
.sample_done:
    cmp word [dram_addr_high], 10h
    jae .format_error
    inc di
    jmp .sample_loop
.samples_done:

    mov bx, [file_handle]
    mov ah, 3Eh
    int 21h
    mov word [file_handle], 0FFFFh
    mov al, [requested_song]
    mov [current_song], al
    inc word [songs_loaded]
    call tracker_reset
    mov byte [music_active], 1
    call gus_timer_program
    jmp .done

.format_error:
    mov byte [song_error], 2
    jmp .close_error
.load_error:
    mov byte [song_error], 3
.close_error:
    cmp word [file_handle], 0FFFFh
    je .mark_none
    mov bx, [file_handle]
    mov ah, 3Eh
    int 21h
    mov word [file_handle], 0FFFFh
.mark_none:
    mov byte [current_song], 0FFh
    jmp .done
.open_error:
    mov byte [song_error], 1
    mov byte [current_song], 0FFh
    jmp .done
.unknown_song:
    ; Match the guarded original selector: unknown IDs leave playback alone.
.done:
    ret

find_song_filename:
    xor di, di
.search:
    mov al, [song_id_table+di]
    cmp al, 0FFh
    je .missing
    cmp al, [requested_song]
    je .found
    inc di
    jmp .search
.found:
    mov bx, di
    shl bx, 1
    mov dx, [song_filename_table+bx]
    clc
    ret
.missing:
    stc
    ret

dos_read_exact:
    mov ah, 3Fh
    int 21h
    jc .fail
    cmp ax, cx
    jne .fail
    clc
    ret
.fail:
    stc
    ret

tracker_reset:
    mov word [clock_phase], 0
    mov word [clock_expected], 0
    mov word [clock_delivered], 0
    mov byte [gf1_watchdog], 0
    mov byte [clock_fallback_active], 0
    mov byte [tracker_tick_count], 1
    mov byte [tracker_order], 0
    mov word [tracker_row], 0
    mov byte [channel_sample+0], 0FFh
    mov byte [channel_sample+1], 0FFh
    mov byte [channel_sample+2], 0FFh
    mov byte [channel_sample+3], 0FFh
    xor ax, ax
    mov di, channel_frequency
    mov cx, 4
    rep stosw
    mov di, channel_target
    mov cx, 4
    rep stosw
    mov di, channel_volume
    mov cx, 4
    rep stosb
    mov di, channel_slide
    mov cx, 4
    rep stosb
    mov di, channel_effect
    mov cx, 4
    rep stosb
    mov di, channel_pitch_slide
    mov cx, 4
    rep stosb
    mov di, channel_retrigger_period
    mov cx, 4
    rep stosb
    mov di, channel_retrigger_count
    mov cx, 4
    rep stosb
    mov di, channel_vibrato_phase
    mov cx, 4
    rep stosb
    mov di, channel_porta_speed
    mov cx, 4
    rep stosb
    mov di, channel_vibrato_speed
    mov cx, 4
    rep stosb
    mov di, channel_vibrato_depth
    mov cx, 4
    rep stosb
    call mute_music_voices
    call setup_pattern_tracks
    ret

; ---------------------------------------------------------------------------
; GF1 timer IRQ.  DSMI tempo uses 2.5/BPM seconds per tick.  GF1 timer 1
; advances in 80 us units, so the rounded period is 31250/BPM counts.  The
; supplied modules use 125 and 144 BPM (and MENU switches up to 212 BPM).

gus_timer_program:
    xor bx, bx
    mov bl, [tracker_tempo]
    mov ax, 31250
    mov dx, bx
    shr dx, 1
    add ax, dx
    xor dx, dx
    div bx
    cmp ax, 255
    jbe .period_ok
    mov ax, 255
.period_ok:
    neg al                       ; 256 - period counts
    mov [timer_reload], al
    pushf
    cli
    mov dx, [gus_command_port]
    mov al, 46h
    out dx, al
    mov dx, [gus_data_high_port]
    mov al, [timer_reload]
    out dx, al
    cmp byte [timer_started], 1
    je .already_running
    mov dx, [gus_command_port]
    mov al, 45h
    out dx, al
    mov dx, [gus_data_high_port]
    mov al, 04h
    out dx, al
    mov byte [timer_control_shadow], 04h
    mov dx, [gus_timer_control_port]
    mov al, 04h
    out dx, al
    mov dx, [gus_timer_data_port]
    mov al, 01h
    out dx, al
    mov byte [timer_started], 1
.already_running:
    popf
.done:
    ret

gus_timer_stop:
    cmp byte [timer_started], 1
    jne .done
    pushf
    cli
    mov dx, [gus_command_port]
    mov al, 45h
    out dx, al
    mov dx, [gus_data_high_port]
    xor al, al
    out dx, al
    mov byte [timer_control_shadow], 0
    mov dx, [gus_timer_control_port]
    mov al, 04h
    out dx, al
    mov dx, [gus_timer_data_port]
    xor al, al
    out dx, al
    mov byte [timer_started], 0
    popf
.done:
    ret

gus_irq_handler:
    pushf
    push eax
    push edx
    mov dx, [cs:gus_status_port]
    in al, dx
    test al, 04h
    jnz .ours
    pop edx
    pop eax
    popf
    jmp far [cs:old_irq]
.ours:
    push ebx
    push ecx
    push esi
    push edi
    push ebp
    push ds
    push es
    push cs
    pop ds

    mov dx, [gus_command_port]
    mov al, 45h
    out dx, al
    mov dx, [gus_data_high_port]
    mov al, [timer_control_shadow]
    and al, 0FBh
    out dx, al
    or al, 04h
    out dx, al

%ifndef CLOCK_STARVATION_TEST
    cmp byte [music_active], 1
    jne .clear_voice_irq
    mov byte [gf1_watchdog], 0
    cmp byte [clock_fallback_active], 1
    jne .deliver

    ; A single GF1 request can remain pending after the 50 Hz path has already
    ; replaced its coalesced lost ticks.  Consume that stale request without
    ; double-advancing the tracker; subsequent GF1 interrupts are primary again.
    mov byte [clock_fallback_active], 0
    mov ax, [clock_expected]
    sub ax, [clock_delivered]
    jle .sync_primary
.deliver:
    call deliver_tracker_tick
.sync_primary:
    ; Keep the emergency reference anchored to the most recent real GF1 tick.
    ; This prevents the GF1 timer's integer reload rounding from accumulating a
    ; long-term lead or lag against the exact 50 Hz fractional reference.
    mov ax, [clock_delivered]
    mov [clock_expected], ax
%endif
.clear_voice_irq:
    mov dx, [gus_command_port]
    mov al, 8Fh
    out dx, al
    mov dx, [gus_data_high_port]
    in al, dx

    cmp word [gus_irq], 7
    jbe .master_eoi
    mov al, 20h
    out 0A0h, al
.master_eoi:
    mov al, 20h
    out 20h, al
    pop es
    pop ds
    pop ebp
    pop edi
    pop esi
    pop ecx
    pop ebx
    pop edx
    pop eax
    popf
    iret

; Advance one tracker tick from either the precise GF1 timer or the bounded
; game-clock recovery path.  DS must be the launcher segment.
deliver_tracker_tick:
    inc word [clock_delivered]
    inc word [total_ticks]
    call tracker_tick
%ifdef TRACE_BUILD
    test word [total_ticks], 003Fh
    jnz .trace_heartbeat_done
    push ax
    xor ah, ah
    mov al, 'G'
    call trace_event
    pop ax
.trace_heartbeat_done:
%endif
    ret

; Apply file panning directions through the user-selected stereo width.  The
; current CF2 modules use hard-left/right DSMI positions; center remains center.
set_module_pan:
    xor di, di
.loop:
    mov al, [amf_header+41+di]
    or al, al
    jz .center
    js .left
    mov al, [music_pan+1]
    jmp .store
.left:
    mov al, [music_pan]
    jmp .store
.center:
    mov al, 7
.store:
    mov [module_pan+di], al
    inc di
    cmp di, 4
    jb .loop
    ret

; Resolve the four sparse track cursors for tracker_order.
setup_pattern_tracks:
    xor ax, ax
    mov al, [tracker_order]
    cmp al, [amf_pattern_count]
    jb .order_ok
    xor ax, ax
    mov [tracker_order], al
.order_ok:
    mov bx, ax
    shl bx, 1
    mov ax, [pattern_rows+bx]
    mov [current_pattern_rows], ax
    xor ax, ax
    mov al, [tracker_order]
    mov cl, 3
    shl ax, cl
    mov si, pattern_tracks
    add si, ax
    xor di, di
.channel:
    mov bx, di
    shl bx, 1
    mov ax, [si+bx]
    or ax, ax
    jz .empty
    cmp ax, [amf_logical_tracks]
    ja .empty
    shl ax, 1
    mov bx, ax
    mov ax, [track_map+bx]
    or ax, ax
    jz .empty
    cmp ax, [amf_physical_tracks]
    ja .empty
    shl ax, 1
    mov bx, ax
    mov dx, [physical_track_offset+bx]
    mov cx, [physical_track_count+bx]
    mov bx, di
    shl bx, 1
    mov [channel_track_ptr+bx], dx
    mov [channel_track_remaining+bx], cx
    jmp .next
.empty:
    mov bx, di
    shl bx, 1
    mov word [channel_track_ptr+bx], 0
    mov word [channel_track_remaining+bx], 0
.next:
    inc di
    cmp di, 4
    jb .channel
    ret

tracker_tick:
    dec byte [tracker_tick_count]
    jz .row
    call tracker_effect_tick
    ret
.row:
    mov byte [pending_jump], 0
    xor di, di
.channel:
    call tracker_process_channel
    inc di
    cmp di, 4
    jb .channel
    mov al, [tracker_speed]
    or al, al
    jnz .speed_ok
    mov al, 1
.speed_ok:
    mov [tracker_tick_count], al
    cmp byte [pending_jump], 0
    je .next_row
    mov al, [pending_order]
    cmp al, [amf_pattern_count]
    jb .jump_ok
    xor al, al
.jump_ok:
    mov [tracker_order], al
    mov word [tracker_row], 0
    call setup_pattern_tracks
    ret
.next_row:
    inc word [tracker_row]
    mov ax, [tracker_row]
    cmp ax, [current_pattern_rows]
    jb .done
    mov word [tracker_row], 0
    inc byte [tracker_order]
    mov al, [tracker_order]
    cmp al, [amf_pattern_count]
    jb .new_pattern
    mov byte [tracker_order], 0
.new_pattern:
    call setup_pattern_tracks
.done:
    ret

; Effects on ticks 1..speed-1.  All calculations are integer-only and each
; channel maps directly to one GF1 voice.
tracker_effect_tick:
    xor di, di
.channel:
    mov al, [channel_slide+di]
    or al, al
    jz .pitch
    cbw
    xor bx, bx
    mov bl, [channel_volume+di]
    add ax, bx
    jns .volume_nonnegative
    xor ax, ax
.volume_nonnegative:
    cmp ax, 64
    jbe .volume_ready
    mov ax, 64
.volume_ready:
    mov [channel_volume+di], al
    call update_music_volume
.pitch:
    mov al, [channel_effect+di]
    cmp al, 1
    je .tone_porta
    cmp al, 2
    je .vibrato
    cmp al, 3
    je .pitch_slide
    cmp al, 4
    je .retrigger
    jmp .next
.tone_porta:
    mov bx, di
    shl bx, 1
    mov ax, [channel_frequency+bx]
    mov dx, [channel_target+bx]
    cmp ax, dx
    je .next
    jb .porta_up_prepare
    xor cx, cx
    mov cl, [channel_porta_speed+di]
    or cx, cx
    jnz .porta_step
    mov cx, 1
.porta_step:
    sub ax, cx
    jnc .porta_down_check
    xor ax, ax
.porta_down_check:
    cmp ax, dx
    ja .porta_store
    mov ax, dx
    jmp .porta_store
.porta_up_prepare:
    xor cx, cx
    mov cl, [channel_porta_speed+di]
    or cx, cx
    jnz .porta_up
    mov cx, 1
.porta_up:
    add ax, cx
    jc .porta_target
    cmp ax, dx
    jb .porta_store
.porta_target:
    mov ax, dx
.porta_store:
    mov [channel_frequency+bx], ax
    call update_music_frequency
    jmp .next
.vibrato:
    mov al, [channel_vibrato_phase+di]
    add al, [channel_vibrato_speed+di]
    and al, 3Fh
    mov [channel_vibrato_phase+di], al
    xor bx, bx
    mov bl, al
    mov al, [vibrato_table+bx]
    cbw
    xor bx, bx
    mov bl, [channel_vibrato_depth+di]
    imul bx
    mov cl, 7
    sar ax, cl
    mov bx, di
    shl bx, 1
    add ax, [channel_frequency+bx]
    mov bx, ax
    mov ax, di
    call gf1_voice_frequency
    jmp .next
.pitch_slide:
    mov bx, di
    shl bx, 1
    mov dx, [channel_frequency+bx]
    or dx, dx
    jz .next
    mov al, [channel_pitch_slide+di]
    or al, al
    jz .next
    js .pitch_slide_up
    xor ah, ah
    cmp dx, ax
    ja .pitch_slide_down_store
    mov dx, 1
    jmp .pitch_slide_store
.pitch_slide_down_store:
    sub dx, ax
    jmp .pitch_slide_store
.pitch_slide_up:
    cbw
    neg ax
    add dx, ax
    jnc .pitch_slide_store
    mov dx, 0FFFEh
.pitch_slide_store:
    mov [channel_frequency+bx], dx
    call update_music_frequency
    jmp .next
.retrigger:
    mov al, [channel_retrigger_period+di]
    or al, al
    jz .next
    inc byte [channel_retrigger_count+di]
    cmp [channel_retrigger_count+di], al
    jb .next
    mov byte [channel_retrigger_count+di], 0
    call trigger_music_channel
.next:
    inc di
    cmp di, 4
    jb .channel
    ret

; Consume all sparse AMF events for the current row of channel DI.
tracker_process_channel:
    mov al, [channel_effect+di]
    mov [temp_previous_effect], al
    mov byte [channel_slide+di], 0
    mov byte [channel_effect+di], 0
    mov byte [channel_retrigger_period+di], 0
    mov byte [channel_retrigger_count+di], 0
    mov byte [temp_note_seen], 0
    mov byte [temp_trigger], 0
    mov byte [temp_freq_changed], 0
    mov byte [temp_volume_changed], 0
    mov byte [temp_tone_porta], 0
    mov byte [temp_fine_slide], 0
    cmp byte [temp_previous_effect], 2
    jne .event_loop
    mov byte [temp_freq_changed], 1  ; restore base pitch after vibrato tick
.event_loop:
    mov bx, di
    shl bx, 1
    cmp word [channel_track_remaining+bx], 0
    je .events_done
    mov si, [channel_track_ptr+bx]
    add si, track_data
    mov al, [si]
    cmp al, 0FFh
    je .end_track
    cmp al, [tracker_row]
    ja .events_done
    add word [channel_track_ptr+bx], 3
    dec word [channel_track_remaining+bx]
    jb .event_loop                    ; skip malformed old-row event
    mov al, [si+1]
    mov ah, [si+2]
    cmp al, 7Fh
    jb .note_event
    je .event_loop
    cmp al, 80h
    je .instrument_event
    cmp al, 81h
    je .speed_effect
    cmp al, 82h
    je .volume_slide
    cmp al, 83h
    je .set_volume
    cmp al, 84h
    je .pitch_slide_effect
    cmp al, 86h
    je .tone_porta
    cmp al, 89h
    je .vibrato
    cmp al, 8Bh
    je .vibrato_slide
    cmp al, 8Ch
    je .pattern_break
    cmp al, 8Dh
    je .pattern_jump
    cmp al, 8Fh
    je .retrigger_effect
    cmp al, 91h
    je .fine_volume_slide
    cmp al, 92h
    je .fine_slide
    cmp al, 95h
    je .set_tempo
    jmp .event_loop
.note_event:
    cmp ah, 0FFh
    je .note_only
    cmp ah, 63
    jbe .note_volume_increment
    mov ah, 64
    jmp .note_volume_ok
.note_volume_increment:
    inc ah
.note_volume_ok:
    mov [channel_volume+di], ah
    mov byte [temp_volume_changed], 1
.note_only:
    or al, al
    jz .event_loop
    mov [temp_note], al
    mov byte [temp_note_seen], 1
    jmp .event_loop
.instrument_event:
    cmp ah, [amf_instrument_count]
    jae .event_loop
    mov [channel_sample+di], ah
    xor bx, bx
    mov bl, ah
    mov al, [sample_volume+bx]
    mov [channel_volume+di], al
    mov byte [temp_volume_changed], 1
    jmp .event_loop
.speed_effect:
    or ah, ah
    jz .event_loop
    mov [tracker_speed], ah
    jmp .event_loop
.volume_slide:
    mov [channel_slide+di], ah
    jmp .event_loop
.set_volume:
    cmp ah, 63
    jbe .set_volume_increment
    mov ah, 64
    jmp .set_volume_ok
.set_volume_increment:
    inc ah
.set_volume_ok:
    mov [channel_volume+di], ah
    mov byte [temp_volume_changed], 1
    jmp .event_loop
.pitch_slide_effect:
    mov byte [channel_effect+di], 3
    or ah, ah
    jz .event_loop
    mov [channel_pitch_slide+di], ah
    jmp .event_loop
.tone_porta:
    mov byte [channel_effect+di], 1
    mov byte [temp_tone_porta], 1
    or ah, ah
    jz .event_loop
    mov [channel_porta_speed+di], ah
    jmp .event_loop
.vibrato:
    mov byte [channel_effect+di], 2
    or ah, ah
    jz .event_loop
    mov al, ah
    shr al, 1
    shr al, 1
    shr al, 1
    shr al, 1
    or al, al
    jz .vibrato_depth
    mov [channel_vibrato_speed+di], al
.vibrato_depth:
    and ah, 0Fh
    jz .event_loop
    mov [channel_vibrato_depth+di], ah
    jmp .event_loop
.vibrato_slide:
    mov byte [channel_effect+di], 2
    mov [channel_slide+di], ah
    jmp .event_loop
.pattern_break:
    mov al, [tracker_order]
    inc al
    mov [pending_order], al
    mov byte [pending_jump], 1
    jmp .event_loop
.pattern_jump:
    mov [pending_order], ah
    mov byte [pending_jump], 1
    jmp .event_loop
.retrigger_effect:
    and ah, 0Fh
    jz .event_loop
    mov [channel_retrigger_period+di], ah
    mov byte [channel_retrigger_count+di], 0
    mov byte [channel_effect+di], 4
    jmp .event_loop
.fine_volume_slide:
    mov al, ah
    cbw
    xor bx, bx
    mov bl, [channel_volume+di]
    add ax, bx
    jns .fine_volume_nonnegative
    xor ax, ax
.fine_volume_nonnegative:
    cmp ax, 64
    jbe .fine_volume_ready
    mov ax, 64
.fine_volume_ready:
    mov [channel_volume+di], al
    mov byte [temp_volume_changed], 1
    jmp .event_loop
.fine_slide:
    mov [temp_fine_slide], ah
    jmp .event_loop
.set_tempo:
    cmp ah, 123
    jb .event_loop
    mov [tracker_tempo], ah
    call gus_timer_program
    jmp .event_loop
.end_track:
    mov word [channel_track_remaining+bx], 0
.events_done:
    cmp byte [temp_note_seen], 0
    je .apply_fine
    mov al, [temp_note]
    call note_to_frequency
    or ax, ax
    jz .apply_fine
    mov bx, di
    shl bx, 1
    cmp byte [temp_tone_porta], 0
    je .new_note
    cmp word [channel_frequency+bx], 0
    je .new_note
    mov [channel_target+bx], ax
    jmp .apply_fine
.new_note:
    mov [channel_frequency+bx], ax
    mov [channel_target+bx], ax
    mov byte [channel_vibrato_phase+di], 0
    mov byte [temp_trigger], 1
.apply_fine:
    mov al, [temp_fine_slide]
    or al, al
    jz .hardware
    cbw
    neg ax
    mov bx, di
    shl bx, 1
    add [channel_frequency+bx], ax
    mov byte [temp_freq_changed], 1
.hardware:
    cmp byte [temp_trigger], 0
    je .frequency_only
    call trigger_music_channel
    ret
.frequency_only:
    cmp byte [temp_freq_changed], 0
    je .volume_only
    call update_music_frequency
.volume_only:
    cmp byte [temp_volume_changed], 0
    je .done
    call update_music_volume
.done:
    ret

; AL = AMF note (60 is the nominal sample-rate note), DI = channel.  Scale the
; 8368-Hz note table by the instrument's declared rate.  32-bit integer math is
; available on the game's minimum 386 and occurs only on note events.
note_to_frequency:
    push bx
    push cx
    push dx
    cmp al, 96
    jae .zero
    xor bx, bx
    mov bl, al
    shl bx, 1
    movzx eax, word [note_frequency_table+bx]
    xor bx, bx
    mov bl, [channel_sample+di]
    cmp bl, [amf_instrument_count]
    jae .zero
    shl bx, 1
    movzx ecx, word [sample_rate+bx]
    mul ecx
    add eax, 4184
    xor edx, edx
    mov ecx, 8368
    div ecx
    and ax, 0FFFEh
    jmp .done
.zero:
    xor ax, ax
.done:
    pop dx
    pop cx
    pop bx
    ret

trigger_music_channel:
    push ax
    push bx
    push cx
    push dx
    push si
    xor bx, bx
    mov bl, [channel_sample+di]
    cmp bl, 30
    ja .stop
    shl bx, 1
    mov ax, [sample_length+bx]
    or ax, ax
    jz .stop
    mov [voice_sample_length], ax
    mov ax, [sample_start_low+bx]
    mov [voice_begin_low], ax
    mov [voice_loop_low], ax
    mov ax, [sample_start_high+bx]
    mov [voice_begin_high], ax
    mov [voice_loop_high], ax

    mov ax, [sample_loop_length+bx]
    cmp ax, 2
    jbe .no_loop
    mov [voice_loop_length], ax
    mov ax, [sample_loop_start+bx]
    add [voice_loop_low], ax
    adc word [voice_loop_high], 0
    mov ax, [voice_loop_low]
    mov [voice_end_low], ax
    mov ax, [voice_loop_high]
    mov [voice_end_high], ax
    mov ax, [voice_loop_length]
    dec ax                          ; GF1 end addresses are inclusive
    add [voice_end_low], ax
    adc word [voice_end_high], 0
    mov byte [voice_mode], 08h
    jmp .address_ready
.no_loop:
    mov ax, [voice_begin_low]
    mov [voice_end_low], ax
    mov ax, [voice_begin_high]
    mov [voice_end_high], ax
    mov ax, [voice_sample_length]
    dec ax
    add [voice_end_low], ax
    adc word [voice_end_high], 0
    mov byte [voice_mode], 0
.address_ready:
    mov bx, di
    shl bx, 1
    mov ax, [channel_frequency+bx]
    or ax, ax
    jz .stop
    mov [voice_frequency], ax
    mov ax, di
    mov [voice_number], al
    mov bx, di
    mov al, [module_pan+bx]
    mov [voice_pan], al
    mov al, [channel_volume+di]
    call music_volume_word
    mov [voice_volume], ax
    call gf1_start_voice
    jmp .done
.stop:
    mov ax, di
    call gf1_stop_voice
.done:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

update_music_frequency:
    push ax
    push bx
    mov bx, di
    shl bx, 1
    mov bx, [channel_frequency+bx]
    or bx, bx
    jz .done
    mov ax, di
    call gf1_voice_frequency
.done:
    pop bx
    pop ax
    ret

update_music_volume:
    push ax
    push bx
    mov al, [channel_volume+di]
    call music_volume_word
    mov bx, ax
    mov ax, di
    call gf1_voice_volume
    pop bx
    pop ax
    ret

music_volume_word:
    push bx
    push cx
    xor ah, ah
    mov bl, [music_master]
    mul bl
    mov cl, 6
    shr ax, cl
    mov bl, [game_music_master]
    mul bl
    mov cl, 6
    shr ax, cl
    cmp ax, 64
    jbe .index
    mov ax, 64
.index:
    shl ax, 1
    mov bx, ax
    mov ax, [volume_table+bx]
    pop cx
    pop bx
    ret

; ---------------------------------------------------------------------------
; GF1 voice operations

gf1_start_voice:
    pushf
    cli
    push ax
    push bx
    push cx
    push dx
    mov dx, [gus_voice_port]
    mov al, [voice_number]
    out dx, al

    mov dx, [gus_command_port]
    mov al, 0Dh
    out dx, al
    mov dx, [gus_data_high_port]
    mov al, 03h
    out dx, al
    call gf1_delay
    out dx, al
    mov dx, [gus_command_port]
    xor al, al
    out dx, al
    mov dx, [gus_data_high_port]
    mov al, 03h
    out dx, al
    call gf1_delay
    out dx, al

    mov dx, [gus_command_port]
    mov al, 09h
    out dx, al
    mov dx, [gus_data_low_port]
    xor ax, ax
    out dx, ax

    mov byte [voice_addr_register], 0Ah
    mov ax, [voice_begin_low]
    mov [voice_addr_low], ax
    mov ax, [voice_begin_high]
    mov [voice_addr_high], ax
    call gf1_write_voice_address
    mov byte [voice_addr_register], 02h
    mov ax, [voice_loop_low]
    mov [voice_addr_low], ax
    mov ax, [voice_loop_high]
    mov [voice_addr_high], ax
    call gf1_write_voice_address
    mov byte [voice_addr_register], 04h
    mov ax, [voice_end_low]
    mov [voice_addr_low], ax
    mov ax, [voice_end_high]
    mov [voice_addr_high], ax
    call gf1_write_voice_address

    mov dx, [gus_command_port]
    mov al, 01h
    out dx, al
    mov dx, [gus_data_low_port]
    mov ax, [voice_frequency]
    out dx, ax
    mov dx, [gus_command_port]
    mov al, 0Ch
    out dx, al
    mov dx, [gus_data_high_port]
    mov al, [voice_pan]
    out dx, al
    mov dx, [gus_command_port]
    mov al, 09h
    out dx, al
    mov dx, [gus_data_low_port]
    mov ax, [voice_volume]
    out dx, ax

    mov dx, [gus_command_port]
    xor al, al
    out dx, al
    mov dx, [gus_data_high_port]
    mov al, [voice_mode]
    and al, 0FCh
    out dx, al
    call gf1_delay
    out dx, al
    pop dx
    pop cx
    pop bx
    pop ax
    popf
    ret

gf1_write_voice_address:
    push ax
    push bx
    push cx
    push dx
    mov ax, [voice_addr_low]
    mov cx, [voice_addr_high]
    mov bx, cx
    shr ax, 7
    shr cx, 7
    shl bx, 9
    or ax, bx
    mov bx, ax
    mov dx, [gus_command_port]
    mov al, [voice_addr_register]
    out dx, al
    mov dx, [gus_data_low_port]
    mov ax, bx
    out dx, ax
    mov dx, [gus_command_port]
    mov al, [voice_addr_register]
    inc al
    out dx, al
    mov dx, [gus_data_low_port]
    mov ax, [voice_addr_low]
    shl ax, 9
    out dx, ax
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; AL = voice, BX = frequency word
gf1_voice_frequency:
    push ax
    push dx
    pushf
    cli
    mov dx, [gus_voice_port]
    out dx, al
    mov dx, [gus_command_port]
    mov al, 01h
    out dx, al
    mov dx, [gus_data_low_port]
    mov ax, bx
    out dx, ax
    popf
    pop dx
    pop ax
    ret

; AL = voice, BX = GF1 current-volume register word
gf1_voice_volume:
    push ax
    push dx
    pushf
    cli
    mov dx, [gus_voice_port]
    out dx, al
    mov dx, [gus_command_port]
    mov al, 09h
    out dx, al
    mov dx, [gus_data_low_port]
    mov ax, bx
    out dx, ax
    popf
    pop dx
    pop ax
    ret

; AL = voice
gf1_stop_voice:
    push ax
    push dx
    pushf
    cli
    mov dx, [gus_voice_port]
    out dx, al
    mov dx, [gus_command_port]
    mov al, 09h
    out dx, al
    mov dx, [gus_data_low_port]
    xor ax, ax
    out dx, ax
    mov dx, [gus_command_port]
    xor al, al
    out dx, al
    mov dx, [gus_data_high_port]
    mov al, 03h
    out dx, al
    call gf1_delay
    out dx, al
    popf
    pop dx
    pop ax
    ret

mute_music_voices:
    xor si, si
.loop:
    mov ax, si
    call gf1_stop_voice
    inc si
    cmp si, 4
    jb .loop
    ret

gus_quiet:
    pushf
    cli
    push ax
    push si
    cmp word [gus_base], 0
    je .done
    xor si, si
.voice:
    mov ax, si
    call gf1_stop_voice
    inc si
    cmp si, ACTIVE_VOICES
    jb .voice
    mov dx, [gus_command_port]
    mov al, 45h
    out dx, al
    mov dx, [gus_data_high_port]
    xor al, al
    out dx, al
.done:
    pop si
    pop ax
    popf
    ret

; ---------------------------------------------------------------------------
; Polyphonic SFX

play_requested_sfx:
    xor bx, bx
    mov bl, [requested_sfx]
    cmp bx, SFX_COUNT
    jae .done
    mov cx, bx
    mov ax, 1
    shl ax, cl
    test [sfx_present_mask], ax
    jz .done
    shl bx, 1
    mov ax, [sfx_lengths+bx]
    or ax, ax
    jz .done
    mov [voice_sample_length], ax
    mov ax, [sfx_offsets+bx]
    mov [voice_begin_low], ax
    mov [voice_loop_low], ax
    mov [voice_end_low], ax
    xor ax, ax
    mov [voice_begin_high], ax
    mov [voice_loop_high], ax
    mov [voice_end_high], ax
    mov ax, [voice_sample_length]
    dec ax
    add [voice_end_low], ax
    movzx eax, word [requested_sfx_rate]
    shl eax, 10
    add eax, 22050
    xor edx, edx
    mov ecx, 44100
    div ecx
    and ax, 0FFFEh
    mov [voice_frequency], ax
    mov byte [voice_mode], 0
    xor bx, bx
    mov bl, [sfx_round_robin]
    mov al, bl
    inc byte [sfx_round_robin]
    cmp byte [sfx_round_robin], SFX_VOICES
    jb .voice_ready
    mov byte [sfx_round_robin], 0
.voice_ready:
    add al, 4
    mov [voice_number], al
    mov byte [voice_pan], 7
    xor ax, ax
    mov al, [requested_sfx_volume]
    cmp al, 64
    jbe .request_volume_ok
    mov al, 64
.request_volume_ok:
    mov bl, [sfx_master]
    mul bl
    mov cl, 6
    shr ax, cl
    cmp ax, 64
    jbe .volume_ok
    mov ax, 64
.volume_ok:
    shl ax, 1
    mov bx, ax
    mov ax, [volume_table+bx]
    mov [voice_volume], ax
    call gf1_start_voice
    inc word [sfx_played]
.done:
    ret

; ---------------------------------------------------------------------------
; Data

%ifdef TRACE_BUILD
msg_banner       db 13,10,'CF2DIAG 0.5 - Cannon Fodder 2 GF1 transition trace',13,10,'$'
%else
msg_banner       db 13,10,'CF2GUS 0.5 - Cannon Fodder 2 native GF1 audio',13,10,'$'
%endif
msg_bad_args     db 'Usage: CF2GUS [/T] [/P-100..100] [/M0..100] [/S0..100]',13,10
                 db '               [/LON|/LOFF]',13,10
                 db '       OCP aliases: -vp, -vm, -vs',13,10,'$'
msg_pan          db 'GF1 music stereo width: $'
msg_pan_end      db '%',13,10,'$'
msg_music_volume db 'GF1 music volume: $'
msg_sfx_volume   db 'GF1 SFX volume: $'
msg_volume_percent db '%',13,10,'$'
msg_line_on      db 'GF1 line input during game: enabled',13,10,'$'
msg_line_off     db 'GF1 line input during game: muted after intro',13,10,'$'
msg_gus_config   db 'GF1 resources from ULTRASND: base $'
msg_gus_dma      db 'h, DMA $'
msg_gus_irq      db ', IRQ $'
msg_bad_config   db 'ERROR: ULTRASND must contain a supported base,DMA,DMA,IRQ,IRQ setting.',13,10,'$'
msg_no_memory    db 'ERROR: DOS could not resize the launcher memory block.',13,10,'$'
msg_no_gus       db 'ERROR: no writable GF1 DRAM found at the ULTRASND base port.',13,10,'$'
msg_probe_detail  db 'Probe base/readback: $'
msg_probe_values  db ' / $'
msg_missing_sfx  db 'WARNING: unavailable/truncated SFX files: $'
msg_missing_sfx_end db ' (those effects will be silent).',13,10,'$'
msg_exec_failed  db 'ERROR: DOS could not execute CANNON.EXE or CAN2.EXE; DOS code 0x','$'
msg_patch_ok     db 'CF2GUS: exact game image patched in memory; vectors restored.',13,10,'$'
msg_patch_missing db 'WARNING: exact game code fingerprints were not seen; audio was not patched.',13,10,'$'
msg_song_error   db 'WARNING: at least one requested AMF song was missing or invalid.',13,10,'$'
msg_audio_counts db 'GF1 events serviced: songs=$'
msg_audio_sfx    db ' sfx=$'
msg_clock_recovery db 'Recovered tracker ticks: $'
%ifdef TRACE_BUILD
msg_trace_header db 'CF2DIAG trace: events=$'
msg_trace_overflow db ' overflow=$'
msg_trace_legend db 'Columns: n type a=request/level c=current m=master t=tracker ticks b=game ticks',13,10
                 db '         o=order k=tick r=row s=state e=error d=fade-down u=fade-up',13,10
                 db '         l=fade-level p=PIC mask n=songs q=timer-reload',13,10
                 db 'Types: S=request W=fade-wait L=load V=volume G=heartbeat F=fallback',13,10,'$'
msg_trace_arg    db ' a=$'
msg_trace_current db ' c=$'
msg_trace_master db ' m=$'
msg_trace_ticks  db ' t=$'
msg_trace_bios   db ' b=$'
msg_trace_order  db ' o=$'
msg_trace_tick   db ' k=$'
msg_trace_row    db ' r=$'
msg_trace_state  db ' s=$'
msg_trace_error  db ' e=$'
msg_trace_down   db ' d=$'
msg_trace_up     db ' u=$'
msg_trace_level  db ' l=$'
msg_trace_pic    db ' p=$'
msg_trace_songs  db ' n=$'
msg_trace_reload db ' q=$'
%endif
%ifdef FADE_INTEGRATION_TEST
msg_fade_test_ok db 'Fade-transition synchronization test: PASS',13,10,'$'
msg_fade_test_fail db 'Fade-transition synchronization test: FAIL',13,10,'$'
%endif
%ifdef SELECTOR_INTEGRATION_TEST
msg_selector_test_ok db 'Unknown-selector preservation test: PASS',13,10,'$'
msg_selector_test_fail db 'Unknown-selector preservation test: FAIL',13,10,'$'
%endif
%ifdef CLOCK_STARVATION_TEST
msg_clock_test_ok db 'Clock-starvation recovery test: PASS',13,10,'$'
msg_clock_test_fail db 'Clock-starvation recovery test: FAIL',13,10,'$'
%endif
%ifdef DIAGNOSTIC_ABORT
msg_diag_calls   db 'DIAG int21=$'
msg_diag_psp     db ' child PSP=$'
msg_diag_base    db ' image base=$'
msg_diag_stage   db ' stage=$'
%endif
%ifdef DUMP_CODE
msg_patch_trigger db 'Patch trigger DOS AX=$'
msg_patch_trigger_ip db ' return IP=$'
%endif
%ifdef SELFTEST_NO_SFX
msg_test_start   db 'Self-test: playing selected AMF through GF1 hardware voices...',13,10,'$'
%else
msg_test_start   db 'Self-test: playing selected AMF and BIRD.SMP through GF1 hardware voices...',13,10,'$'
%endif
msg_test_ok      db 'Self-test passed: GF1 timer interrupts were received.',13,10,'$'
msg_test_fail    db 'Self-test failed: no GF1 timer interrupts were received.',13,10,'$'
msg_crlf         db 13,10,'$'

ultrasnd_key     db 'ULTRASND='
game_filename    db 'CANNON.EXE',0
game_filename_alt db 'CAN2.EXE',0
exec_tail        db 0,13      ; consume our switches; child receives no arguments
%ifdef DUMP_CODE
code_dump_filename db 'CODEDUMP.BIN',0
%endif
name_menu        db 'MENU.AMF',0
name_winzone     db 'WINZONE.AMF',0
name_winlevel    db 'WINLEVEL.AMF',0
name_helianim    db 'HELIANIM.AMF',0
name_loader      db 'LOADER.AMF',0
name_gameover    db 'GAMEOVER.AMF',0
name_title       db 'TITLE.AMF',0
song_id_table    db 0,6,12,7,8,15,100,0FFh
song_filename_table:
    dw name_menu,name_winzone,name_winlevel,name_helianim
    dw name_loader,name_gameover,name_title

name_bird        db 'BIRD.SMP',0
name_die1        db 'DIE1.SMP',0
name_die2        db 'DIE2.SMP',0
name_die3        db 'DIE3.SMP',0
name_duck        db 'DUCK.SMP',0
name_engine      db 'ENGINE.SMP',0
name_explosion   db 'EXPLOSN.SMP',0
name_grenade     db 'GRENADE.SMP',0
name_gun         db 'GUN.SMP',0
name_heli        db 'HELI.SMP',0
name_mgun        db 'MGUN.SMP',0
name_missile     db 'MISSILE.SMP',0
name_sheep       db 'SHEEP.SMP',0
name_rook        db 'ROOK.SMP',0
sfx_filename_table:
    dw name_bird,name_die1,name_die2,name_die3,name_duck,name_engine
    dw name_explosion,name_grenade,name_gun,name_heli,name_mgun
    dw name_missile,name_sheep,name_rook

irq_lut          db 0,0,1,3,0,2,0,4,0,0,0,5,6,0,0,7
dma_lut          db 0,1,0,2,0,3,4,5
music_pan        db 3,12,12,3     ; left/right endpoints set at startup
module_pan       db 3,12,12,3

sfx_lengths:
    dw 614,2532,3258,3226,4340,404,4740,8704,2812,748,614,9864,6118,2748
sfx_offsets:
    dw 0,614,3146,6404,9630,13970,14374,19114,27818,30630,31378,31992,41856,47974

; GF1 frequency-control words for AMF notes 0..95.  Note 60 plays at the
; instrument's nominal 8368-Hz sample rate.
note_frequency_table:
    dw 6,6,6,6,8,8,8,8
    dw 10,10,10,10,12,12,14,14
    dw 14,16,16,18,18,20,22,22
    dw 24,26,26,28,30,32,34,36
    dw 38,40,42,46,48,50,54,58
    dw 60,64,68,72,76,82,86,92
    dw 96,102,108,116,122,130,136,146
    dw 154,162,172,182,194,206,218,230
    dw 244,258,274,290,308,326,346,366
    dw 388,412,436,462,490,518,550,582
    dw 616,654,692,734,776,822,872,924
    dw 978,1036,1098,1164,1234,1306,1384,1466
vibrato_table:
    db 0,12,25,37,49,60,71,81,90,98,106,112,117,122,125,126
    db 127,126,125,122,117,112,106,98,90,81,71,60,49,37,25,12
    db 0,-12,-25,-37,-49,-60,-71,-81,-90,-98,-106,-112,-117,-122,-125,-126
    db -127,-126,-125,-122,-117,-112,-106,-98,-90,-81,-71,-60,-49,-37,-25,-12

; Independently derived linear 0..64 -> GF1 exponent/mantissa values.
volume_table:
    dw 00000h,09FF0h,0AFF0h,0B800h,0BFF0h,0C400h,0C800h,0CC00h
    dw 0CFF0h,0D200h,0D400h,0D600h,0D800h,0DA00h,0DC00h,0DE00h
    dw 0DFF0h,0E100h,0E200h,0E300h,0E400h,0E500h,0E600h,0E700h
    dw 0E800h,0E900h,0EA00h,0EB00h,0EC00h,0ED00h,0EE00h,0EF00h
    dw 0EFF0h,0F080h,0F100h,0F180h,0F200h,0F280h,0F300h,0F380h
    dw 0F400h,0F480h,0F500h,0F580h,0F600h,0F680h,0F700h,0F780h
    dw 0F800h,0F880h,0F900h,0F980h,0FA00h,0FA80h,0FB00h,0FB80h
    dw 0FC00h,0FC80h,0FD00h,0FD80h,0FE00h,0FE80h,0FF00h,0FF80h
    dw 0FFF0h

psp_segment       dw 0
gus_base          dw 0
gus_dma1          dw 0
gus_dma2          dw 0
gus_irq           dw 0
gus_midi_irq      dw 0
gus_voice_port    dw 0
gus_command_port  dw 0
gus_data_low_port dw 0
gus_data_high_port dw 0
gus_status_port   dw 0
gus_timer_control_port dw 0
gus_timer_data_port dw 0
gus_dram_port     dw 0
irq_latch         db 0
dma_latch         db 0
old_pic_master    db 0
old_pic_slave     db 0
pan_percent       db 60
pan_reverse       db 0
pan_seen          db 0
music_percent     db 81
sfx_percent       db 86
music_seen        db 0
sfx_seen          db 0
option_kind       db 0
line_mute         db 0
line_seen         db 0
irq_vector        db 0
vectors_installed db 0
timer_started     db 0
timer_control_shadow db 0
timer_reload      db 6
test_mode         db 0
patch_installed   db 0
game_line_muted   db 0
candidate_base    dw 0
patch_image_base  dw 0
patch_scan_start  dw 0
%ifdef DIAGNOSTIC_ABORT
diag_int21_calls  dw 0
diag_child_psp    dw 0
diag_candidate_base dw 0
diag_stage        db 0
diag_child_seen   db 0
diag_abort_armed  db 0
%endif
exec_failed       db 0
exec_error        dw 0
child_exit_code   db 0
bios_tick_start   dw 0
total_ticks       dw 0
clock_phase       dw 0
clock_expected    dw 0
clock_delivered   dw 0
clock_fallback_ticks dw 0
gf1_watchdog      db 0
clock_fallback_active db 0
songs_loaded      dw 0
sfx_played        dw 0
song_error        db 0
music_active      db 0
current_song      db 0FFh
requested_song    db 0
song_filename_ptr dw 0
%ifdef FADE_INTEGRATION_TEST
fade_wait_wakeups dw 0
fade_wait_completed db 0
fade_transition_tick_start dw 0
fade_test_pass    db 0
%endif
%ifdef SELECTOR_INTEGRATION_TEST
selector_test_song_count dw 0
selector_test_pass db 0
%endif
requested_sfx     db 0
requested_sfx_rate dw 8363
requested_sfx_volume db 64
sfx_round_robin   db 0
sfx_present_mask  dw 0
missing_sfx_count db 0
music_master      db 52
game_music_master db 64
sfx_master        db 55

%ifdef TRACE_BUILD
trace_count       dw 0
trace_overflow    dw 0
trace_events      times TRACE_EVENT_LIMIT*TRACE_EVENT_BYTES db 0
%endif

old_int21         dd 0
old_int65         dd 0
old_int66         dd 0
old_int64         dd 0
old_irq           dd 0
exec_params       times 14 db 0
%ifdef SFX_INTEGRATION_TEST
test_sfx_entry    dd 0
%endif

file_handle       dw 0FFFFh
bytes_remaining   dw 0
dram_addr_low     dw 0
dram_addr_high    dw 0
peek_value        db 0
probe_value0      db 0
probe_value1      db 0

amf_instrument_count db 0
amf_pattern_count db 0
amf_logical_tracks dw 0
amf_physical_tracks dw 0
track_data_used   dw 0
track_data_next   dw 0
tracker_tick_count db 1
tracker_speed     db 6
tracker_tempo     db 125
tracker_order     db 0
tracker_row       dw 0
current_pattern_rows dw 64
pending_jump      db 0
pending_order     db 0
channel_sample    times 4 db 0FFh
channel_frequency times 4 dw 0
channel_target    times 4 dw 0
channel_volume    times 4 db 0
channel_slide     times 4 db 0
channel_effect    times 4 db 0
channel_pitch_slide times 4 db 0
channel_retrigger_period times 4 db 0
channel_retrigger_count times 4 db 0
channel_porta_speed times 4 db 0
channel_vibrato_speed times 4 db 0
channel_vibrato_depth times 4 db 0
channel_vibrato_phase times 4 db 0
channel_track_ptr times 4 dw 0
channel_track_remaining times 4 dw 0

sample_start_low  times MAX_INSTRUMENTS dw 0
sample_start_high times MAX_INSTRUMENTS dw 0
sample_length     times MAX_INSTRUMENTS dw 0
sample_rate       times MAX_INSTRUMENTS dw 0
sample_loop_start times MAX_INSTRUMENTS dw 0
sample_loop_length times MAX_INSTRUMENTS dw 0
sample_volume     times MAX_INSTRUMENTS db 0

temp_note         db 0
temp_note_seen    db 0
temp_trigger      db 0
temp_freq_changed db 0
temp_volume_changed db 0
temp_tone_porta  db 0
temp_fine_slide  db 0
temp_previous_effect db 0

voice_number      db 0
voice_mode        db 0
voice_pan         db 7
voice_frequency   dw 0
voice_volume      dw 0
voice_begin_low   dw 0
voice_begin_high  dw 0
voice_loop_low    dw 0
voice_loop_high   dw 0
voice_end_low     dw 0
voice_end_high    dw 0
voice_sample_length dw 0
voice_loop_length dw 0
voice_addr_register db 0
voice_addr_low    dw 0
voice_addr_high   dw 0

io_buffer         times IO_BUFFER_BYTES db 0
amf_header        times AMF_HEADER_BYTES db 0
pattern_rows      times MAX_PATTERNS dw 0
pattern_tracks    times MAX_PATTERNS*4 dw 0
track_map         times MAX_LOGICAL_TRACKS+1 dw 0
physical_track_offset times MAX_PHYSICAL_TRACKS+1 dw 0
physical_track_count times MAX_PHYSICAL_TRACKS+1 dw 0
track_data        times TRACK_BUFFER_BYTES db 0
%ifdef DUMP_CODE
code_dumped       db 0
patch_trigger_ax  dw 0
patch_trigger_ip  dw 0
code_dump         times 1000h db 0
%endif
stack_space       times 1024 db 0
stack_top:
resident_end:

; Retain exactly 64 KiB including the PSP.  This is the LOADFIX placement
; workaround and also contains all resident code/data/stack.
RESIDENT_PARAS equ LOADFIX_PARAS
%if (resident_end - $$ + 100h) > (LOADFIX_PARAS * 16)
    %error "CF2GUS resident image exceeds its 64 KiB LOADFIX block"
%endif
