; sixfiveohtwo stage 7 smoke test.
;
; Exercises decimal mode (SED) with the NMOS/Bruce Clark model:
; ADC/SBC with D=1 in immediate, zp, abs and (zp),Y modes; carry-in
; 0/1 and borrow-in 0/1; digit-carry correction (09+01=10); the
; anchor sums 58+46=$04, 99+01=$00, 50+50=$00 (N=1 V=1 C=1) and
; differences 00-01=$99, 50-25=$25, 50-50=$00. Per the model, decimal
; ADC takes N/V from the high-nibble sum and Z from the decimal
; result; decimal SBC takes N/V/Z strictly from the binary
; difference (proven with PHP/PLA checkpoint bytes; P is pushed as
; N V 1 B D I Z C, base $3C while D=1 and I=1) while result/C come
; from the decimal correction.
;
; Also proven: CLD restores binary (99+01 = $9A, not $00) and SED
; re-enters decimal ($00 again), with D visible as bit3 of the
; PHP/PLA checkpoint bytes both ways; ORA and ASL/LSR/ROL/ROR are
; unaffected by D=1; one SBC with invalid BCD digits ($0F-$FF) where
; the binary N=0 while the decimal result $B0 has bit7 set (possible
; only with invalid digits -- with valid BCD the two never disagree).
;
; Straight-line code, no JSR; every PHP is balanced by a PLA so SP
; stays $FD. The last data write is the final marker at $F000, then
; execution falls into zero fill (unknown opcodes behave as NOPs).

        .segment "CODE"

start:
        ; ------------------------------------------------------------
        ; Decimal ADC immediate: anchors, digit carry, carry-in/out
        ; ------------------------------------------------------------
        sed                     ; D=1 for everything up to the CLD block
        clc                     ; carry-in 0
        lda #$58
        adc #$46                ; 58+46 = 104 -> $04, C=1
        sta $F100               ; [F100]=$04
        bcs dok1                ; C=1 -> taken
        lda #$D1
        sta $F1E0               ; [F1E0] fail marker, only stored if C=0 (bug)
dok1:
        clc
        lda #$99
        adc #$01                ; 99+01 = 100 -> $00, C=1, Z=1
        sta $F101               ; [F101]=$00
        adc #$00                ; $00+$00+C(1) = $01
        sta $F102               ; [F102]=$01 proves previous ADC set C=1
        clc
        lda #$09
        adc #$01                ; digit carry: 09+01 = 10 -> $10, C=0
        sta $F103               ; [F103]=$10
        sec                     ; carry-in 1
        lda #$46
        adc #$58                ; 46+58+1 = 105 -> $05, C=1
        sta $F104               ; [F104]=$05
        clc
        lda #$50
        adc #$50                ; 50+50 = 100 -> $00: N=1, V=1, C=1, Z=1
        sta $F105               ; [F105]=$00
        bvs dok2                ; V=1 -> taken
        lda #$D2
        sta $F1E1               ; [F1E1] fail marker (V=0 bug)
dok2:
        bmi dok3                ; N=1 -> taken
        lda #$D3
        sta $F1E2               ; [F1E2] fail marker (N=0 bug)
dok3:
        beq dok4                ; Z=1 -> taken
        lda #$D4
        sta $F1E3               ; [F1E3] fail marker (Z=0 bug)
dok4:
        adc #$00                ; $00+$00+C(1) = $01
        sta $F106               ; [F106]=$01 proves C=1 out of 50+50

        ; ------------------------------------------------------------
        ; Decimal ADC: zp (carry-in 1), abs, (zp),Y
        ; ------------------------------------------------------------
        lda #$46
        sta $20                 ; ADC zp operand
        lda #$32
        sta $F200               ; ADC abs operand
        lda #$45
        sta $F211               ; ADC (zp),Y operand ($F210+1)
        lda #$F2
        sta $41
        lda #$10
        sta $40                 ; pointer -> $F210
        ldy #$01
        sec                     ; carry-in 1
        lda #$58
        adc $20                 ; 58+46+1 = 105 -> $05, C=1
        sta $F107               ; [F107]=$05
        clc
        lda #$67
        adc $F200               ; 67+32 = 99 -> $99: C=0, N=1, V=1
        sta $F108               ; [F108]=$99
        bvs dok5                ; V=1 -> taken
        lda #$D5
        sta $F1E4               ; [F1E4] fail marker (V=0 bug)
dok5:
        clc
        lda #$36
        adc ($40),Y             ; -> $F211=$45: 36+45 = 81 -> $81, C=0
        sta $F109               ; [F109]=$81
        bcc dok6                ; C=0 -> taken
        lda #$D6
        sta $F1E5               ; [F1E5] fail marker (C=1 bug)
dok6:

        ; ------------------------------------------------------------
        ; Decimal SBC immediate: borrow-in/out, anchors
        ; ------------------------------------------------------------
        sec                     ; borrow-in 0
        lda #$50
        sbc #$25                ; 50-25 = 25 -> $25, C=1
        sta $F10A               ; [F10A]=$25
        sbc #$25                ; C(1): 25-25 = 0 -> $00, Z=1, C=1
        sta $F10B               ; [F10B]=$00 proves previous SBC set C=1
        sec
        lda #$00
        sbc #$01                ; 00-01 = -1 -> $99, C=0, binary N=1
        sta $F10C               ; [F10C]=$99
        bcc dok7                ; C=0 -> taken
        lda #$D7
        sta $F1E6               ; [F1E6] fail marker (C=1 bug)
dok7:
        sec
        lda #$50
        sbc #$90                ; 50-90 = -40 -> $60, C=0, binary V=1 N=1
        sta $F10D               ; [F10D]=$60
        bvs dok8                ; binary V=1 -> taken
        lda #$D8
        sta $F1E7               ; [F1E7] fail marker (V=0 bug)
dok8:
        sec
        lda #$50
        sbc #$00                ; 50-00 = 50 -> $50, C=1
        sta $F10E               ; [F10E]=$50
        clc                     ; borrow-in 1
        lda #$50
        sbc #$00                ; 50-00-1 = 49 -> $49, C=1
        sta $F10F               ; [F10F]=$49
        clc
        lda #$50
        sbc #$50                ; 50-50-1 = -1 -> $99, C=0, binary N=1
        sta $F110               ; [F110]=$99
        sec
        lda #$30
        sbc #$50                ; 30-50 = -20 -> $80, C=0, binary N=1
        sta $F111               ; [F111]=$80

        ; ------------------------------------------------------------
        ; Decimal SBC: zp, abs, (zp),Y (borrow-in 1 on the indirect)
        ; ------------------------------------------------------------
        lda #$18
        sta $21                 ; SBC zp operand
        lda #$13
        sta $F201               ; SBC abs operand
        lda #$19
        sta $F222               ; SBC (zp),Y operand ($F220+2)
        lda #$F2
        sta $43
        lda #$20
        sta $42                 ; pointer -> $F220
        ldy #$02
        sec
        lda #$52
        sbc $21                 ; 52-18 = 34 -> $34, C=1
        sta $F112               ; [F112]=$34
        sec
        lda #$50
        sbc $F201               ; 50-13 = 37 -> $37, C=1
        sta $F113               ; [F113]=$37
        clc                     ; borrow-in 1
        lda #$50
        sbc ($42),Y             ; -> $F222=$19: 50-19-1 = 30 -> $30, C=1
        sta $F114               ; [F114]=$30

        ; ------------------------------------------------------------
        ; SBC N/V/Z are strictly binary: PHP/PLA checkpoint bytes
        ; (P pushed as N V 1 B D I Z C; D=1 I=1 here, so base $3C)
        ; ------------------------------------------------------------
        sec
        lda #$50
        sbc #$25                ; binary $25: N=0 V=0 Z=0; decimal C=1
        sta $F115               ; [F115]=$25
        php
        pla                     ; A = P = $3D
        sta $F116               ; [F116]=$3D
        sec
        lda #$00
        sbc #$01                ; binary $FF: N=1 V=0 Z=0; decimal C=0
        sta $F117               ; [F117]=$99
        php
        pla                     ; A = $BC
        sta $F118               ; [F118]=$BC
        sec
        lda #$50
        sbc #$50                ; binary $00: N=0 V=0 Z=1; decimal C=1
        sta $F119               ; [F119]=$00
        php
        pla                     ; A = $3F
        sta $F11A               ; [F11A]=$3F
        sec
        lda #$50
        sbc #$90                ; binary $C0: N=1 V=1 Z=0; decimal $60 C=0
        sta $F11B               ; [F11B]=$60
        php
        pla                     ; A = $FC
        sta $F11C               ; [F11C]=$FC
        sec
        lda #$90
        sbc #$10                ; binary $80: N=1 V=0 Z=0; decimal $80 C=1
        sta $F11D               ; [F11D]=$80
        php
        pla                     ; A = $BD
        sta $F11E               ; [F11E]=$BD
        clc
        lda #$90
        sbc #$10                ; binary $7F: N=0 V=1 Z=0; decimal $79 C=1
        sta $F11F               ; [F11F]=$79
        php
        pla                     ; A = $7D
        sta $F120               ; [F120]=$7D

        ; ------------------------------------------------------------
        ; Binary N=0 while the decimal result has bit7 set: only
        ; reachable with invalid BCD digits ($0F/$FF), which the
        ; NMOS/Clark model still defines. Decimal $B0, binary $10.
        ; ------------------------------------------------------------
        sec
        lda #$0F
        sbc #$FF                ; decimal $B0 C=0; binary $10: N=0
        sta $F121               ; [F121]=$B0
        bpl iok1                ; binary N=0 -> taken
        lda #$D9
        sta $F1E8               ; [F1E8] fail marker (N=1 bug)
iok1:
        php
        pla                     ; A = $3C
        sta $F122               ; [F122]=$3C

        ; ------------------------------------------------------------
        ; ORA and the shifts are unaffected by D=1
        ; ------------------------------------------------------------
        lda #$0F
        ora #$80                ; $0F|$80 = $8F: N=1
        sta $F123               ; [F123]=$8F
        lda #$03
        asl a                   ; $06
        asl a                   ; $0C
        asl a                   ; $18
        asl a                   ; $30
        asl a                   ; $60
        asl a                   ; $C0
        asl a                   ; $80: C=1 (bit7 shifted out)
        sta $F124               ; [F124]=$80
        bcs sok1                ; C=1 -> taken
        lda #$DA
        sta $F1E9               ; [F1E9] fail marker (C=0 bug)
sok1:
        rol a                   ; C(1): $01, C=1 (bit7 out)
        sta $F125               ; [F125]=$01
        ror a                   ; C(1): $80, C=1 (bit0 out)
        sta $F126               ; [F126]=$80
        lsr a                   ; $40, C=0
        sta $F127               ; [F127]=$40
        lda #$01
        lsr a                   ; $00: Z=1, C=1
        sta $F128               ; [F128]=$00
        beq sok2                ; Z=1 -> taken
        lda #$DB
        sta $F1EA               ; [F1EA] fail marker (Z=0 bug)
sok2:

        ; ------------------------------------------------------------
        ; CLD restores binary; SED re-enters decimal; D visible in P
        ; ------------------------------------------------------------
        cld                     ; D=0
        clc
        lda #$99
        adc #$01                ; binary: $9A, C=0 (decimal would be C=1)
        sta $F129               ; [F129]=$9A
        bcc cok1                ; C=0 -> taken
        lda #$DC
        sta $F1EB               ; [F1EB] fail marker (still decimal bug)
cok1:
        php
        pla                     ; A = P with D=0: $B4
        sta $F12A               ; [F12A]=$B4
        sed                     ; D=1
        clc
        lda #$99
        adc #$01                ; decimal: $00, C=1, Z=1
        sta $F12B               ; [F12B]=$00
        bcs cok2                ; C=1 -> taken
        lda #$DD
        sta $F1EC               ; [F1EC] fail marker (still binary bug)
cok2:
        php
        pla                     ; A = P with D=1: $BF
        sta $F12C               ; [F12C]=$BF

        ; ------------------------------------------------------------
        ; Final marker: the very last data write of the program
        ; ------------------------------------------------------------
        cld                     ; D=0 for the final snapshot
        lda #$A7                ; N=1, Z=0
        sta $F000               ; [F000]=$A7 final marker

done:
