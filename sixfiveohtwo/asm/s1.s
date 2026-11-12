; sixfiveohtwo stage 1 smoke test.
;
; Exercises loads, stores, transfers, increments/decrements, and flag
; operations. All results are checkpointed to memory; the testbench
; compares the checkpoint area and takes two flag snapshots.
;
; Memory conventions (shared by all smoke tests):
;   $F000 = final marker (nonzero once the program ran to completion)
;   $F001 = intermediate marker (flags: N=1, Z=0 at this store)
;   $F100..$F1FF = checkpoint area read by the testbench

        .segment "CODE"

start:
        ; --- LDA immediate ---
        lda #$42
        sta $F100               ; 1: A = $42
        lda #$80
        sta $F101               ; 2: A = $80
        lda #$00
        sta $F102               ; 3: A = $00

        ; --- zero page and absolute stores and loads ---
        lda #$DE
        sta $10                 ; zero page store
        lda #$AD
        sta $F110               ; absolute store
        lda #$00
        lda $10                 ; zero page load -> $DE
        sta $F103               ; 4
        lda $F110               ; absolute load -> $AD
        sta $F104               ; 5

        ; --- LDX / LDY in all three modes ---
        ldx #$11
        stx $F105               ; 6: X = $11
        ldy #$22
        sty $F106               ; 7: Y = $22
        ldx $10                 ; X = $DE
        stx $F107               ; 8
        ldy $F110               ; Y = $AD
        sty $F108               ; 9

        ; --- STX / STY absolute ---
        stx $F109               ; 10: $DE
        sty $F10A               ; 11: $AD

        ; --- transfers ---
        lda #$5A
        tax                     ; X = $5A
        stx $F10B               ; 12
        lda #$C3
        tay                     ; Y = $C3
        sty $F10C               ; 13
        ldx #$99
        txa                     ; A = $99
        sta $F10D               ; 14
        ldy #$66
        tya                     ; A = $66
        sta $F10E               ; 15
        tsx                     ; X = SP = $FD (reset value)
        stx $F10F               ; 16
        ldx #$77
        txs                     ; SP = $77 (TXS sets no flags)
        tsx
        stx $F111               ; 17: TXS/TSX round trip

        ; --- INX / DEX / INY / DEY including wraparound ---
        inx                     ; X = $78
        stx $F112               ; 18
        dex                     ; X = $77
        stx $F113               ; 19
        iny                     ; Y = $67
        sty $F114               ; 20
        dey                     ; Y = $66
        sty $F115               ; 21
        ldx #$FF
        inx                     ; X = $00, Z=1
        stx $F116               ; 22
        dex                     ; X = $FF, N=1
        stx $F117               ; 23
        ldy #$FF
        iny                     ; Y = $00, Z=1
        sty $F118               ; 24
        dey                     ; Y = $FF, N=1
        sty $F119               ; 25

        ; --- flag operations ---
        sed                     ; D=1
        sec                     ; C=1
        sei                     ; I=1
        clv                     ; V=0
        lda #$80                ; N=1 Z=0
        sta $F001               ; intermediate marker (N=1 Z=0 here)
        lda #$00                ; N=0 Z=1
        sta $F11A               ; 26: A = $00
        ldx #$C6
        lda #$00                ; N=0 Z=1 (final flag state)
        stx $F000               ; final marker

done:
        ; Execution falls through into the zero fill that follows the
        ; program; unknown opcodes behave as one-cycle NOPs, so the
        ; CPU idles harmlessly until the testbench finishes.