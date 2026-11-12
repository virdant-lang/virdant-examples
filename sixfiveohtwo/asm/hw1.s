; hw1: Fomu color-cycling demo.
;
; Cycles the RGB LED through all 8 color combinations with a visible
; ~440 ms delay between each step. No touch-pad interaction needed.
;
; Memory map: $FF00 write lights the LED (bit0 red, bit1 green, bit2
; blue; set = on); $FF00 reads return touch-pad state (ignored here).

        .segment "CODE"

start:
        ; ------------------------------------------------------------
        ; Init: signal we're live, light the first color (red)
        ; ------------------------------------------------------------
        sei                     ; I=1 (interrupts off, unused)
        lda #$A5
        sta $F000               ; init marker: program is running
        lda #$01
        sta $FF00               ; first color: red
        sta $F001               ; checkpoint $01

        ; ------------------------------------------------------------
        ; Color-cycle loop: forever
        ; ------------------------------------------------------------
main_loop:
        inc $00                 ; 1→2→3→4→5→6→7→0→1→...
        lda $00
        and #$07                ; keep in 0-7 range
        sta $00                 ; commit masked value
        sta $FF00               ; write to LED
        sta $F001               ; checkpoint for simulation

        ; -- visible delay (~440 ms at 6 MHz sys_clk) --
        lda #$08
        sta $01                 ; outer: 8
dly_outer:
        ldx #$00                ; middle: 256
dly_mid:
        ldy #$00                ; inner: 256
dly_inner:
        dey
        bne dly_inner
        dex
        bne dly_mid
        dec $01
        bne dly_outer

        jmp main_loop