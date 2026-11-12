; sixfiveohtwo stage 2 smoke test.
;
; Exercises the six indexed addressing modes (including zero page
; wrap, page crossing, and pointer wrap) and all eight branches
; (taken, not taken, and a backward-branch loop).

        .segment "CODE"

start:
        ; --- zero page,X ---
        lda #$DE
        sta $15
        ldx #$05
        lda $10,X               ; -> $15
        sta $F100
        lda #$AD
        sta $10
        ldx #$F0
        lda $20,X               ; zp wrap: $20+$F0 -> $10
        sta $F101

        ; --- zero page,Y (LDX/STX only) ---
        lda #$77
        sta $33
        ldy #$03
        ldx $30,Y               ; -> $33
        stx $F102
        lda #$EE
        sta $12
        ldy #$F5
        ldx $1D,Y               ; zp wrap: $1D+$F5 -> $12
        stx $F103

        ; --- absolute,X ---
        lda #$11
        sta $F210
        ldx #$05
        lda $F20B,X             ; -> $F210
        sta $F104
        lda #$22
        sta $F308
        ldx #$10
        lda $F2F8,X             ; page cross -> $F308
        sta $F105

        ; --- absolute,Y ---
        lda #$33
        sta $F230
        ldy #$07
        lda $F229,Y             ; -> $F230
        sta $F106
        lda #$44
        sta $F318
        ldy #$F0
        lda $F228,Y             ; page cross -> $F318
        sta $F107

        ; --- indexed stores ---
        lda #$66
        ldx #$03
        sta $F130,X             ; $F133 = $66
        ldy #$04
        sta $F140,Y             ; $F144 = $66
        lda #$77
        ldx #$02
        sta $28,X               ; $2A = $77

        ; --- (zp,X) ---
        lda #$99
        sta $F234
        lda #$34
        sta $40
        lda #$F2
        sta $41                 ; pointer at $40 = $F234
        ldx #$05
        lda ($3B,X)             ; pointer at $40
        sta $F108
        ; pointer address wraps within page zero
        lda #$AA
        sta $F380
        lda #$77
        sta $80                 ; sentinel for the wrong-page bug
        lda #$80
        sta $FF
        lda #$F3
        sta $00                 ; pointer at $FF = $F380 (high byte wraps to $00)
        ldx #$01
        lda ($FE,X)             ; pointer at $FF
        sta $F109

        ; --- (zp),Y ---
        lda #$BB
        sta $F467
        lda #$60
        sta $50
        lda #$F4
        sta $51                 ; pointer at $50 = $F460
        ldy #$07
        lda ($50),Y             ; -> $F467
        sta $F10A
        lda #$CC
        sta $F505
        lda #$FF
        sta $52
        lda #$F4
        sta $53                 ; pointer at $52 = $F4FF
        ldy #$06
        lda ($52),Y             ; page cross -> $F505
        sta $F10B
        lda #$70
        sta $54
        lda #$F4
        sta $55                 ; pointer at $54 = $F470
        lda #$DD
        ldy #$03
        sta ($54),Y             ; $F473 = $DD

        ; --- STX zp,Y / STY zp,X ---
        ldx #$88
        ldy #$09
        stx $26,Y               ; $2F = $88
        ldy #$42
        ldx #$01
        sty $30,X               ; $31 = $42

        ; --- branches: taken paths ---
        lda #$80
        bmi b1                  ; taken
        lda #$00
        sta $F10C               ; dead if BMI works
b1:     lda #$A1
        sta $F10C

        lda #$00
        bpl b2                  ; taken
        lda #$00
        sta $F10E               ; dead
b2:     lda #$C4
        sta $F10E

        clv
        lda #$50
        bvc b3                  ; taken
        lda #$00
        sta $F111               ; dead
b3:     lda #$F7
        sta $F111

        clc
        lda #$60
        bcc b4                  ; taken
        lda #$00
        sta $F112               ; dead
b4:     lda #$08
        sta $F112

        sec
        lda #$70
        bcs b5                  ; taken
        lda #$00
        sta $F113               ; dead
b5:     lda #$09
        sta $F113

        lda #$00
        beq b6                  ; taken
        lda #$00
        sta $F116               ; dead
b6:     lda #$0C
        sta $F116

        lda #$42
        bne b7                  ; taken
        lda #$00
        sta $F117               ; dead
b7:     lda #$0D
        sta $F117

        ; --- branches: not-taken paths ---
        lda #$80
        bpl b8                  ; not taken (N=1)
        lda #$B2
        sta $F10D
b8:
        lda #$00
        bmi b9                  ; not taken
        lda #$D5
        sta $F10F
b9:
        clv
        lda #$40
        bvs b10                 ; not taken (V=0)
        lda #$E6
        sta $F110
b10:
        clc
        lda #$30
        bcs b11                 ; not taken (C=0)
        lda #$0A
        sta $F114
b11:
        sec
        lda #$20
        bcc b12                 ; not taken (C=1)
        lda #$0B
        sta $F115
b12:
        lda #$43
        beq b13                 ; not taken (Z=0)
        lda #$0E
        sta $F118
b13:
        lda #$00
        bne b14                 ; not taken (Z=1)
        lda #$0F
        sta $F119
b14:

        ; --- backward branch loop ---
        ldx #$03
loop:
        dex
        bne loop                ; three backward branches
        stx $F11A               ; X = $00

        ; --- final marker ---
        lda #$7E
        sta $F000

done: