; sixfiveohtwo stage 3 smoke test.
;
; Exercises the stage 3 ALU ops: ORA, AND, EOR, ADC, SBC, CMP, CPX,
; CPY, BIT (binary mode only -- SED is never used).
;
; ADC and SBC run in all seven non-immediate addressing modes. Flag
; outcomes are proven three ways: results stored to $F100-$F145,
; carry/borrow chained into a following adc #$00 probe, and short
; forward branches guarding fail-marker stores.
;
; Straight-line code, no stack ops, no JMP/JSR: the last data write
; is the final marker at $F000, then execution falls into zero fill
; (unknown opcodes behave as NOPs).

        .segment "CODE"

start:
        ; ------------------------------------------------------------
        ; ADC immediate: carry-in, carry-out, V, N, Z
        ; ------------------------------------------------------------
        clc                     ; C=0: carry-in 0
        lda #$10
        adc #$20                ; $10+$20 = $30
        sta $F100               ; [F100]=$30 ADC imm, no carry-in
        sec                     ; C=1: carry-in 1
        lda #$10
        adc #$20                ; $10+$20+1 = $31
        sta $F101               ; [F101]=$31 ADC imm, carry-in effect
        clc                     ; C=0
        lda #$FF
        adc #$01                ; $FF+$01 = $00: carry-out C=1, Z=1
        sta $F102               ; [F102]=$00 ADC imm zero result (Z=1)
        adc #$00                ; $00+$00+C(1) = $01
        sta $F103               ; [F103]=$01 proves previous ADC set C=1
        clc                     ; C=0
        lda #$50
        adc #$50                ; $50+$50 = $A0: V=1 (signed overflow), N=1
        sta $F104               ; [F104]=$A0 ADC imm V=1, N=1
        bvs vok1                ; V=1 -> branch taken
        lda #$B9
        sta $F144               ; [F144] fail marker, only stored if V=0 (bug)
vok1:
        clc                     ; C=0
        lda #$80
        adc #$80                ; $80+$80 = $00: C=1, V=1, Z=1
        sta $F105               ; [F105]=$00 ADC imm zero (Z=1)
        adc #$00                ; $00+$00+C(1) = $01
        sta $F106               ; [F106]=$01 proves previous ADC set C=1

        ; ------------------------------------------------------------
        ; SBC immediate: borrow-in, borrow-out, V, Z
        ; ------------------------------------------------------------
        sec                     ; C=1: no borrow-in
        lda #$50
        sbc #$30                ; $50-$30 = $20, no borrow -> C=1
        sta $F107               ; [F107]=$20 SBC imm basic
        sbc #$20                ; $20-$20-C(1) = $00: C=1, Z=1
        sta $F108               ; [F108]=$00 proves previous SBC set C=1; Z=1
        sec                     ; C=1
        lda #$30
        sbc #$50                ; $30-$50 = $E0: borrow -> C=0, N=1
        sta $F109               ; [F109]=$E0 SBC imm borrow (C=0)
        clc                     ; C=0: borrow-in effect
        lda #$30
        sbc #$30                ; $30-$30-1 = $FF: C=0, N=1
        sta $F10A               ; [F10A]=$FF SBC imm borrow-in effect
        sec                     ; C=1
        lda #$50
        sbc #$B0                ; $50-$B0 = $A0: V=1, N=1, C=0
        sta $F10B               ; [F10B]=$A0 SBC imm V=1
        bvs vok2                ; V=1 -> branch taken
        lda #$BA
        sta $F145               ; [F145] fail marker, only stored if V=0 (bug)
vok2:

        ; ------------------------------------------------------------
        ; Memory setup for indexed/indirect ADC and SBC
        ; ------------------------------------------------------------
        lda #$40
        sta $20                 ; ADC zp operand
        lda #$AA
        sta $21                 ; zp,X base decoy (X=1 skips it)
        lda #$20
        sta $22                 ; ADC zp,X operand ($21+1)
        lda #$0F
        sta $25                 ; SBC zp operand
        lda #$EE
        sta $26                 ; zp,X base decoy (X=2 skips it)
        lda #$10
        sta $28                 ; SBC zp,X operand ($26+2)
        lda #$60
        sta $34                 ; (zp,X) pointer low -> $F260
        lda #$F2
        sta $35                 ; (zp,X) pointer high
        lda #$70
        sta $40                 ; (zp),Y pointer low -> $F270
        lda #$F2
        sta $41                 ; (zp),Y pointer high
        lda #$80
        sta $42                 ; (zp),Y pointer low -> $F280
        lda #$F2
        sta $43                 ; (zp),Y pointer high
        lda #$30
        sta $F210               ; SBC abs operand
        lda #$15
        sta $F245               ; ADC abs,X operand ($F240+5)
        lda #$20
        sta $F252               ; SBC abs,Y operand ($F250+2)
        lda #$70
        sta $F281               ; ADC (zp),Y operand ($F280+1)
        lda #$30
        sta $F271               ; SBC (zp),Y operand ($F270+1)
        lda #$80
        sta $F260               ; ADC (zp,X) target

        ; ------------------------------------------------------------
        ; ADC/SBC in every non-immediate addressing mode
        ; ------------------------------------------------------------
        clc                     ; C=0
        lda #$10
        adc $20                 ; $10+$40 = $50
        sta $F10C               ; [F10C]=$50 ADC zp
        clc                     ; C=0
        ldx #$01
        lda #$05
        adc $21,X               ; -> $22=$20: $05+$20 = $25
        sta $F10D               ; [F10D]=$25 ADC zp,X
        sec                     ; C=1
        lda #$50
        sbc $F210               ; $50-$30 = $20: C=1
        sta $F10E               ; [F10E]=$20 SBC abs
        clc                     ; C=0
        ldx #$05
        lda #$20
        adc $F240,X             ; -> $F245=$15: $20+$15 = $35
        sta $F10F               ; [F10F]=$35 ADC abs,X
        ldy #$02
        sec                     ; C=1
        lda #$40
        sbc $F250,Y             ; -> $F252=$20: $40-$20 = $20, C=1
        sta $F110               ; [F110]=$20 SBC abs,Y
        clc                     ; C=0
        ldx #$04
        lda #$10
        adc ($30,X)             ; pointer at $34 -> $F260=$80: $10+$80 = $90
        sta $F111               ; [F111]=$90 ADC (zp,X)
        ldy #$01
        sec                     ; C=1
        lda #$A0
        sbc ($40),Y             ; $F270+1 -> $F271=$30: $A0-$30 = $70, V=1
        sta $F112               ; [F112]=$70 SBC (zp),Y
        clc                     ; C=0
        lda #$90
        adc ($42),Y             ; $F280+1 -> $F281=$70: $90+$70 = $00, Z=1
        sta $F113               ; [F113]=$00 ADC (zp),Y zero result
        sec                     ; C=1
        lda #$35
        sbc $25                 ; $35-$0F = $26: C=1
        sta $F114               ; [F114]=$26 SBC zp
        sec                     ; C=1
        ldx #$02
        lda #$30
        sbc $26,X               ; -> $28=$10: $30-$10 = $20, C=1
        sta $F115               ; [F115]=$20 SBC zp,X

        ; ------------------------------------------------------------
        ; Memory setup for logic ops
        ; ------------------------------------------------------------
        lda #$F0
        sta $2A                 ; AND zp operand
        lda #$55
        sta $2B                 ; EOR zp operand
        lda #$80
        sta $2C                 ; ORA zp operand
        lda #$0F
        sta $2D                 ; zp,X base decoy (X=1 skips it)
        lda #$F0
        sta $2E                 ; EOR zp,X operand ($2D+1)
        lda #$D0
        sta $36                 ; (zp,X) pointer low -> $F2D0
        lda #$F2
        sta $37                 ; (zp,X) pointer high
        lda #$B0
        sta $44                 ; (zp),Y pointer low -> $F2B0
        lda #$F2
        sta $45                 ; (zp),Y pointer high
        lda #$E0
        sta $46                 ; (zp),Y pointer low -> $F2E0
        lda #$F2
        sta $47                 ; (zp),Y pointer high
        lda #$D0
        sta $3C                 ; (zp,X) pointer low -> $F2D0 (base $3A, X=2)
        lda #$F2
        sta $3D                 ; (zp,X) pointer high
        lda #$C3
        sta $F290               ; AND abs operand
        lda #$0F
        sta $F291               ; ORA abs operand
        lda #$FF
        sta $F292               ; EOR abs operand
        lda #$11
        sta $F2A0               ; abs,Y base decoy (Y=1 skips it)
        lda #$22
        sta $F2A1               ; ORA abs,Y operand ($F2A0+1)
        lda #$00
        sta $F2C0               ; abs,X base decoy (X=3 skips it)
        lda #$3C
        sta $F2C3               ; AND abs,X operand ($F2C0+3)
        lda #$0F
        sta $F2D0               ; ORA (zp,X) target
        lda #$DE
        sta $F2B0               ; (zp),Y decoy at offset 0
        lda #$EF
        sta $F2B1               ; AND (zp),Y operand ($F2B0+1)
        lda #$00
        sta $F2E0               ; (zp),Y decoy at offset 0
        lda #$AA
        sta $F2E1               ; EOR (zp),Y operand ($F2E0+1)

        ; ------------------------------------------------------------
        ; ORA / AND / EOR: results and N/Z outcomes
        ; ------------------------------------------------------------
        lda #$F0
        and #$0F                ; $F0&$0F = $00: Z=1, N=0
        sta $F116               ; [F116]=$00 AND imm zero (Z=1)
        lda #$0F
        ora #$80                ; $0F|$80 = $8F: N=1
        sta $F117               ; [F117]=$8F ORA imm negative (N=1)
        lda #$FF
        eor #$FF                ; $FF^$FF = $00: Z=1
        sta $F118               ; [F118]=$00 EOR imm zero (Z=1)
        lda #$F0
        and $2A                 ; $F0&$F0 = $F0: N=1
        sta $F119               ; [F119]=$F0 AND zp negative (N=1)
        lda #$AA
        eor $2B                 ; $AA^$55 = $FF: N=1
        sta $F11A               ; [F11A]=$FF EOR zp
        lda #$01
        ora $2C                 ; $01|$80 = $81: N=1
        sta $F11B               ; [F11B]=$81 ORA zp
        ldx #$01
        lda #$FF
        eor $2D,X               ; -> $2E=$F0: $FF^$F0 = $0F
        sta $F11C               ; [F11C]=$0F EOR zp,X
        lda #$3C
        and $F290               ; $3C&$C3 = $00: Z=1
        sta $F11D               ; [F11D]=$00 AND abs zero (Z=1)
        lda #$F0
        ora $F291               ; $F0|$0F = $FF: N=1
        sta $F11E               ; [F11E]=$FF ORA abs
        lda #$0F
        eor $F292               ; $0F^$FF = $F0: N=1
        sta $F11F               ; [F11F]=$F0 EOR abs
        ldx #$03
        lda #$F0
        and $F2C0,X             ; -> $F2C3=$3C: $F0&$3C = $30
        sta $F120               ; [F120]=$30 AND abs,X
        ldy #$01
        lda #$44
        ora $F2A0,Y             ; -> $F2A1=$22: $44|$22 = $66
        sta $F121               ; [F121]=$66 ORA abs,Y
        ldx #$02
        lda #$70
        ora ($3A,X)             ; pointer at $3C -> $F2D0=$0F: $70|$0F = $7F
        sta $F122               ; [F122]=$7F ORA (zp,X)
        lda #$FF
        and ($44),Y             ; $F2B0+1 -> $F2B1=$EF: $FF&$EF = $EF
        sta $F123               ; [F123]=$EF AND (zp),Y
        lda #$FF
        eor ($46),Y             ; $F2E0+1 -> $F2E1=$AA: $FF^$AA = $55
        sta $F124               ; [F124]=$55 EOR (zp),Y

        ; ------------------------------------------------------------
        ; CMP immediate: equal, greater, less; A untouched;
        ; carry outcome probed with adc #$00
        ; ------------------------------------------------------------
        lda #$42
        cmp #$42                ; $42-$42 = $00: C=1, Z=1
        bne p1                  ; not taken (Z=1)
        sta $F125               ; [F125]=$42 A unchanged by CMP
        lda #$11
        sta $F126               ; [F126]=$11 reached only if Z=1
p1:
        lda #$40
        adc #$00                ; $40+$00+C(1) = $41
        sta $F127               ; [F127]=$41 proves CMP equal set C=1
        lda #$50
        cmp #$30                ; $50-$30 = $20: C=1, Z=0
        beq p2                  ; not taken (Z=0)
        sta $F128               ; [F128]=$50 A unchanged (A > operand)
        lda #$22
        sta $F129               ; [F129]=$22 reached only if Z=0
p2:
        lda #$40
        adc #$00                ; $40+$00+C(1) = $41
        sta $F12A               ; [F12A]=$41 proves CMP greater set C=1
        lda #$30
        cmp #$50                ; $30-$50 = $E0: C=0, N=1, Z=0
        bcs p3                  ; not taken (C=0)
        bpl p4                  ; not taken (N=1)
        sta $F12B               ; [F12B]=$30 A unchanged (A < operand)
        lda #$33
        sta $F12C               ; [F12C]=$33 reached only if C=0 and N=1
p3:
p4:
        lda #$40
        adc #$00                ; $40+$00+C(0) = $40
        sta $F12D               ; [F12D]=$40 proves CMP less cleared C

        ; ------------------------------------------------------------
        ; CMP abs and CMP (zp),Y
        ; ------------------------------------------------------------
        lda #$40
        sta $F2A2               ; CMP abs operand
        lda #$50
        cmp $F2A2               ; $50-$40 = $10: C=1
        bcc p5                  ; not taken (C=1)
        lda #$44
        sta $F12E               ; [F12E]=$44 CMP abs C=1
p5:
        lda #$F0
        sta $48                 ; (zp),Y pointer low -> $F2F0
        lda #$F2
        sta $49                 ; (zp),Y pointer high
        lda #$AA
        sta $F2F0               ; (zp),Y decoy at offset 0
        lda #$20
        sta $F2F1               ; CMP (zp),Y operand ($F2F0+1)
        ldy #$01
        lda #$50
        cmp ($48),Y             ; -> $F2F1=$20: $50-$20 = $30, C=1
        bcc p6                  ; not taken (C=1)
        lda #$55
        sta $F12F               ; [F12F]=$55 CMP (zp),Y C=1, A unchanged
p6:

        ; ------------------------------------------------------------
        ; CPX: equal, less, zp, abs; X untouched
        ; ------------------------------------------------------------
        ldx #$30
        cpx #$30                ; $30-$30 = $00: C=1, Z=1
        bne q1                  ; not taken (Z=1)
        stx $F130               ; [F130]=$30 X unchanged by CPX
        lda #$77
        sta $F131               ; [F131]=$77 reached only if Z=1
q1:
        lda #$40
        adc #$00                ; $40+$00+C(1) = $41
        sta $F132               ; [F132]=$41 proves CPX equal set C=1
        ldx #$10
        cpx #$30                ; $10-$30 = $E0: C=0, N=1
        bcs q2                  ; not taken (C=0)
        stx $F133               ; [F133]=$10 X unchanged (less case)
        lda #$88
        sta $F134               ; [F134]=$88 reached only if C=0
q2:
        lda #$30
        sta $4A                 ; CPX zp operand
        ldx #$50
        cpx $4A                 ; $50-$30 = $20: C=1, Z=0
        bcc q3                  ; not taken (C=1)
        lda #$5A
        sta $F135               ; [F135]=$5A CPX zp C=1
q3:
        lda #$15
        sta $F2A4               ; CPX abs operand
        ldx #$10
        cpx $F2A4               ; $10-$15 = $FB: C=0, N=1
        bcs q4                  ; not taken (C=0)
        bpl q5                  ; not taken (N=1)
        lda #$A5
        sta $F136               ; [F136]=$A5 CPX abs C=0 and N=1
q4:
q5:

        ; ------------------------------------------------------------
        ; CPY: equal, less, zp, abs; Y untouched
        ; ------------------------------------------------------------
        ldy #$40
        cpy #$40                ; $40-$40 = $00: C=1, Z=1
        bne r1                  ; not taken (Z=1)
        sty $F137               ; [F137]=$40 Y unchanged by CPY
        lda #$99
        sta $F138               ; [F138]=$99 reached only if Z=1
r1:
        lda #$40
        adc #$00                ; $40+$00+C(1) = $41
        sta $F139               ; [F139]=$41 proves CPY equal set C=1
        ldy #$10
        cpy #$40                ; $10-$40 = $D0: C=0, N=1
        bcs r2                  ; not taken (C=0)
        sty $F13A               ; [F13A]=$10 Y unchanged (less case)
        lda #$66
        sta $F13B               ; [F13B]=$66 reached only if C=0
r2:
        lda #$90
        sta $4B                 ; CPY zp operand
        ldy #$90
        cpy $4B                 ; $90-$90 = $00: C=1, Z=1
        bne r3                  ; not taken (Z=1)
        sty $F13C               ; [F13C]=$90 Y unchanged by CPY zp
        lda #$9B
        sta $F13D               ; [F13D]=$9B reached only if Z=1
r3:
        lda #$33
        sta $F2A5               ; CPY abs operand
        ldy #$80
        cpy $F2A5               ; $80-$33 = $4D: C=1, Z=0
        bcc r4                  ; not taken (C=1)
        lda #$C5
        sta $F13E               ; [F13E]=$C5 CPY abs C=1
r4:

        ; ------------------------------------------------------------
        ; BIT zp and BIT abs: N, V, Z outcomes; A untouched
        ; ------------------------------------------------------------
        lda #$00
        sta $2F                 ; BIT zp operand: $00 -> Z=1
        lda #$C0
        sta $31                 ; BIT zp operand: $C0 -> N=1, V=1
        lda #$40
        sta $F2A3               ; BIT abs operand: $40 -> V=1, N=0
        lda #$BE
        bit $2F                 ; $BE&$00 = $00: Z=1, N=0, V=0
        bne t1                  ; not taken (Z=1)
        sta $F13F               ; [F13F]=$BE BIT zp $00: Z=1, A unchanged
t1:
        lda #$FF
        bit $31                 ; $FF&$C0 = $C0: Z=0, N=1, V=1
        sta $F140               ; [F140]=$FF A unchanged by BIT
        bpl t2                  ; not taken (N=1)
        bvc t3                  ; not taken (V=1)
        lda #$C2
        sta $F141               ; [F141]=$C2 reached only if N=1 and V=1
t2:
t3:
        lda #$40
        bit $F2A3               ; $40&$40 = $40: Z=0, N=0, V=1
        sta $F142               ; [F142]=$40 A unchanged by BIT abs
        bvc t4                  ; not taken (V=1)
        bmi t5                  ; not taken (N=0)
        lda #$D4
        sta $F143               ; [F143]=$D4 reached only if V=1 and N=0
t4:
t5:

        ; ------------------------------------------------------------
        ; Final marker: the very last data write of the program
        ; ------------------------------------------------------------
        clv                     ; V=0
        sec                     ; C=1
        lda #$A5                ; A=$A5: N=1, Z=0
        sta $F000               ; [F000]=$A5 final marker

done: