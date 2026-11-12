; sixfiveohtwo stage 5 smoke test.
;
; Exercises the stage 5 read-modify-write ops: ASL, LSR, ROL, ROR
; (accumulator and memory forms) and INC/DEC (memory forms), across
; zero page, zp,X, absolute, and abs,X.
;
; Memory-mode results are written back to the same address and proven
; via C records, together with untouched decoy neighbors guarding
; against off-by-one indexing. Flag outcomes are captured with
; PHP/PLA pairs: PHP pushes P (bit5=1, B=1), PLA drops it into A,
; and the store lands the whole flag byte in a checkpoint cell
; ($34 base byte after reset: I=1). Two three-instruction shift
; chains prove carry handoff between consecutive shifts. INC/DEC
; wrap $FF->$00 (Z=1) and $00->$FF (N=1) in zp and abs, with C and V
; pinned and shown untouched. A is proven untouched by memory-mode
; ops. One INC zp,X wraps within page zero ($4F+$C9 -> $18).
;
; Straight-line code, no branches, no JMP/JSR: every push (PHP) is
; followed by its pull (PLA), so SP=$FD at the final marker. The last
; data write is the final marker at $F000.

        .segment "CODE"

start:
        ldy #$27                ; Y fixed for the whole program

        ; ============================================================
        ; ASL A: C-out 0/1, N set, zero result, C-in ignored
        ; ============================================================
        clc                     ; C=0
        lda #$01
        asl a                   ; $01<<1 = $02: C=0, N=0, Z=0
        sta $F101               ; [F101]=$02 ASL A result
        php
        pla
        sta $F100               ; [F100]=$34 flags (N0 Z0 C0 V0 I1)
        lda #$80
        clc                     ; C=0
        asl a                   ; $80<<1 = $00: C=1, Z=1, N=0
        sta $F103               ; [F103]=$00 ASL A zero result (Z=1)
        php
        pla
        sta $F102               ; [F102]=$37 flags (C1 Z1)
        lda #$40
        asl a                   ; $40<<1 = $80: N=1, C=0
        sta $F105               ; [F105]=$80 ASL A negative result
        php
        pla
        sta $F104               ; [F104]=$B4 flags (N1 C0)
        lda #$01
        sec                     ; C=1: ASL must ignore carry-in
        asl a                   ; $01<<1 = $02, C-out=0
        sta $F107               ; [F107]=$02 ASL A ignores C-in
        php
        pla
        sta $F106               ; [F106]=$34 flags (C cleared from 1)

        ; ============================================================
        ; LSR A: C-out 0/1, N cleared, zero result
        ; ============================================================
        clc                     ; C=0
        lda #$02
        lsr a                   ; $02>>1 = $01: C=0, N=0, Z=0
        sta $F109               ; [F109]=$01 LSR A result
        php
        pla
        sta $F108               ; [F108]=$34 flags
        lda #$03
        lsr a                   ; $03>>1 = $01: C=1 (old bit0)
        sta $F10B               ; [F10B]=$01 LSR A C-out 1
        php
        pla
        sta $F10A               ; [F10A]=$35 flags (C1)
        lda #$80                ; N=1
        lsr a                   ; $80>>1 = $40: N cleared, C=0
        sta $F10D               ; [F10D]=$40 LSR A result
        php
        pla
        sta $F10C               ; [F10C]=$34 flags (N0)
        lda #$01
        lsr a                   ; $01>>1 = $00: C=1, Z=1
        sta $F10F               ; [F10F]=$00 LSR A zero result
        php
        pla
        sta $F10E               ; [F10E]=$37 flags (C1 Z1)

        ; ============================================================
        ; ROL A: C-in 0/1, zero result, C-out 0/1
        ; ============================================================
        clc                     ; C=0: carry-in 0
        lda #$01
        rol a                   ; $01 rol 0 = $02: C=0, N=0, Z=0
        sta $F111               ; [F111]=$02 ROL A C-in 0 result
        php
        pla
        sta $F110               ; [F110]=$34 flags
        lda #$80
        clc                     ; C=0
        rol a                   ; $80 rol 0 = $00: C=1, Z=1
        sta $F113               ; [F113]=$00 ROL A zero result (Z=1)
        php
        pla
        sta $F112               ; [F112]=$37 flags (C1 Z1)
        lda #$01
        sec                     ; C=1: carry lands in bit0
        rol a                   ; $01 rol 1 = $03: C=0
        sta $F115               ; [F115]=$03 ROL A C-in 1 result
        php
        pla
        sta $F114               ; [F114]=$34 flags
        lda #$80
        sec                     ; C=1
        rol a                   ; $80 rol 1 = $01: C=1 (old bit7)
        sta $F117               ; [F117]=$01 ROL A result
        php
        pla
        sta $F116               ; [F116]=$35 flags (C1)

        ; ============================================================
        ; ROR A: C-in 0/1, zero result
        ; ============================================================
        clc                     ; C=0: bit7 gets 0
        lda #$02
        ror a                   ; $02 ror 0 = $01: C=0, N=0, Z=0
        sta $F119               ; [F119]=$01 ROR A C-in 0 result
        php
        pla
        sta $F118               ; [F118]=$34 flags
        lda #$01
        clc                     ; C=0
        ror a                   ; $01 ror 0 = $00: C=1, Z=1
        sta $F11B               ; [F11B]=$00 ROR A zero result (Z=1)
        php
        pla
        sta $F11A               ; [F11A]=$37 flags (C1 Z1)
        lda #$02
        sec                     ; C=1: carry lands in bit7
        ror a                   ; $02 ror 1 = $81: N=1, C=0
        sta $F11D               ; [F11D]=$81 ROR A C-in 1 result
        php
        pla
        sta $F11C               ; [F11C]=$B4 flags (N1 C0)
        lda #$00
        sec                     ; C=1
        ror a                   ; $00 ror 1 = $80: N=1, C=0
        sta $F11F               ; [F11F]=$80 ROR A result
        php
        pla
        sta $F11E               ; [F11E]=$B4 flags (N1 C0)

        ; ============================================================
        ; Shift chains: three shifts, carry handed op to op
        ; ============================================================
        clc                     ; C=0
        lda #$40
        asl a                   ; $40<<1 = $80: C=0
        rol a                   ; $80 rol 0 = $00: C=1, Z=1
        rol a                   ; $00 rol 1 = $01: C-in from ROL above
        sta $F121               ; [F121]=$01 chain 1 result
        php
        pla
        sta $F120               ; [F120]=$34 chain 1 flags
        sec                     ; C=1
        lda #$01
        lsr a                   ; $01>>1 = $00: C=1, Z=1
        ror a                   ; $00 ror 1 = $80: N=1, C=0
        ror a                   ; $80>>1 = $40: C=0
        sta $F123               ; [F123]=$40 chain 2 result
        php
        pla
        sta $F122               ; [F122]=$34 chain 2 flags

        ; ============================================================
        ; Memory-mode shifts, zero page
        ; ============================================================
        lda #$41
        sta $10                 ; ASL zp target (N set)
        lda #$A1
        sta $11                 ; ASL zp target (C-out 1)
        lda #$84
        sta $12                 ; LSR zp target (N clear)
        lda #$03
        sta $13                 ; LSR zp target (C-out 1)
        lda #$40
        sta $14                 ; ROL zp target (C-in 0)
        sta $15                 ; ROL zp target (C-in 1)
        lda #$02
        sta $16                 ; ROR zp target (C-in 1)
        lda #$03
        sta $17                 ; ROR zp target (C-out 1)

        clc                     ; C=0
        asl $11                 ; $A1 -> $42: C=1, N=0
        php
        pla
        sta $F124               ; [F124]=$35 ASL zp flags (C1)
        asl $10                 ; $41 -> $82: N=1, C=0
        php
        pla
        sta $F125               ; [F125]=$B4 ASL zp flags (N1)
        lsr $12                 ; $84 -> $42: N cleared (was 1), C=0
        php
        pla
        sta $F126               ; [F126]=$34 LSR zp flags
        lsr $13                 ; $03 -> $01: C=1, N=0
        php
        pla
        sta $F127               ; [F127]=$35 LSR zp C-out 1 flags
        clc                     ; C=0: ROL shifts 0 in
        rol $14                 ; $40 rol 0 -> $80: N=1, C=0
        php
        pla
        sta $F128               ; [F128]=$B4 ROL zp C-in 0 flags
        sec                     ; C=1: carry into bit0
        rol $15                 ; $40 rol 1 -> $81: N=1, C=0
        php
        pla
        sta $F129               ; [F129]=$B4 ROL zp C-in 1 flags
        sec                     ; C=1: ROR shifts 1 into bit7
        ror $16                 ; $02 ror 1 -> $81: N=1, C=0
        php
        pla
        sta $F12A               ; [F12A]=$B4 ROR zp C-in 1 flags
        clc                     ; C=0
        ror $17                 ; $03 ror 0 -> $01: C=1, N cleared
        php
        pla
        sta $F12B               ; [F12B]=$35 ROR zp C-out 1 flags

        ; ============================================================
        ; INC/DEC, zero page: wraps, C/V untouched, A untouched
        ; ============================================================
        lda #$7F
        sta $40
        lda #$FF
        sta $41
        lda #$01
        sta $42
        lda #$00
        sta $43

        clc                     ; C=0
        clv                     ; V=0: INC/DEC must not touch either
        lda #$99
        inc $40                 ; $7F -> $80: N=1, Z=0, A unchanged
        sta $F148               ; [F148]=$99 A unchanged by INC zp
        php
        pla
        sta $F12C               ; [F12C]=$B4 INC zp flags (N1, C0 V0)
        inc $41                 ; $FF -> $00: Z=1, N=0 (wrap!)
        php
        pla
        sta $F12D               ; [F12D]=$36 INC zp wrap flags (Z1, C0 V0)
        dec $42                 ; $01 -> $00: Z=1, N=0
        php
        pla
        sta $F12E               ; [F12E]=$36 DEC zp flags (Z1, C0 V0)
        dec $43                 ; $00 -> $FF: N=1, Z=0 (wrap!)
        php
        pla
        sta $F12F               ; [F12F]=$B4 DEC zp wrap flags (N1, C0 V0)
        sec                     ; C=1: DEC must leave C alone
        dec $43                 ; $FF -> $FE: N=1, C stays 1
        php
        pla
        sta $F130               ; [F130]=$B5 DEC zp flags (N1, C1 preserved)

        ; ============================================================
        ; Memory-mode shifts and INC/DEC, zp,X with decoy neighbors
        ; ============================================================
        lda #$11
        sta $20                 ; decoy
        lda #$22
        sta $21                 ; base cell, must stay untouched
        lda #$33
        sta $22                 ; decoy
        lda #$7F
        sta $23                 ; ASL zp,X target ($21+2)
        lda #$44
        sta $24                 ; decoy
        lda #$55
        sta $25                 ; base cell, must stay untouched
        lda #$85
        sta $26                 ; LSR zp,X target ($25+1)
        lda #$66
        sta $27                 ; decoy
        lda #$FE
        sta $28                 ; ROL zp,X target ($25+3)
        lda #$77
        sta $30                 ; base cell, must stay untouched
        lda #$88
        sta $31                 ; decoy
        lda #$7F
        sta $32                 ; ROR zp,X target ($30+2)
        lda #$99
        sta $33                 ; decoy between the RMW targets
        lda #$7F
        sta $34                 ; INC zp,X target ($30+4)
        lda #$AA
        sta $35                 ; base cell, must stay untouched
        lda #$01
        sta $36                 ; DEC zp,X target ($35+1)
        lda #$BB
        sta $37                 ; decoy

        clc                     ; C=0
        ldx #$02
        asl $21,X               ; -> $23: $7F -> $FE: N=1, C=0
        php
        pla
        sta $F131               ; [F131]=$B4 ASL zp,X flags
        stx $F132               ; [F132]=$02 X unchanged
        ldx #$01
        lsr $25,X               ; -> $26: $85 -> $42: C=1, N cleared
        php
        pla
        sta $F133               ; [F133]=$35 LSR zp,X flags
        ldx #$03
        sec                     ; C=1: carry into ROL
        rol $25,X               ; -> $28: $FE rol 1 -> $FD: N=1, C=1
        php
        pla
        sta $F134               ; [F134]=$B5 ROL zp,X flags
        ldx #$02
        clc                     ; C=0: ROR shifts 0 into bit7
        ror $30,X               ; -> $32: $7F ror 0 -> $3F: C=1, N=0
        php
        pla
        sta $F135               ; [F135]=$35 ROR zp,X flags
        ldx #$04
        inc $30,X               ; -> $34: $7F -> $80: N=1, C=1 preserved
        php
        pla
        sta $F136               ; [F136]=$B5 INC zp,X flags (C1)
        ldx #$01
        dec $35,X               ; -> $36: $01 -> $00: Z=1, C=1 preserved
        php
        pla
        sta $F137               ; [F137]=$37 DEC zp,X flags (Z1, C1)

        ; --- zp,X index wraps within page zero ---
        lda #$FE
        sta $18                 ; wrap target: ($4F + $C9) & $FF = $18
        lda #$99
        sta $4F                 ; base cell, must stay untouched
        lda #$66
        sta $19                 ; decoy above the target
        clc                     ; C=0
        ldx #$C9
        inc $4F,X               ; -> $18: $FE -> $FF: N=1, C=0
        php
        pla
        sta $F138               ; [F138]=$B4 INC zp,X wrap flags (N1)
        stx $F139               ; [F139]=$C9 X unchanged

        ; ============================================================
        ; Memory-mode shifts and INC/DEC, absolute
        ; ============================================================
        lda #$01
        sta $F200               ; ASL abs target (C-out 0)
        lda #$80
        sta $F201               ; ASL abs target (C-out 1, zero result)
        sta $F202               ; LSR abs target (N clear)
        lda #$40
        sta $F203               ; ROL abs target (C-in 1)
        lda #$01
        sta $F204               ; ROR abs target (zero result)
        lda #$FF
        sta $F205               ; INC abs target ($FF wrap)
        lda #$00
        sta $F206               ; DEC abs target ($00 wrap)

        clc                     ; C=0
        asl $F200               ; $01 -> $02: C=0, N=0, Z=0
        php
        pla
        sta $F13A               ; [F13A]=$34 ASL abs flags
        asl $F201               ; $80 -> $00: C=1, Z=1, N=0
        php
        pla
        sta $F13B               ; [F13B]=$37 ASL abs zero flags
        sec                     ; C=1: carry into ROL
        rol $F203               ; $40 rol 1 -> $81: N=1, C=0
        php
        pla
        sta $F13C               ; [F13C]=$B4 ROL abs C-in 1 flags
        lsr $F202               ; $80 -> $40: N cleared (was 1), C=0
        php
        pla
        sta $F13D               ; [F13D]=$34 LSR abs flags
        clc                     ; C=0
        ror $F204               ; $01 ror 0 -> $00: C=1, Z=1
        php
        pla
        sta $F13E               ; [F13E]=$37 ROR abs zero flags
        inc $F205               ; $FF -> $00: Z=1 (wrap!), C=1 preserved
        php
        pla
        sta $F13F               ; [F13F]=$37 INC abs wrap flags
        dec $F206               ; $00 -> $FF: N=1 (wrap!), C=1 preserved
        php
        pla
        sta $F140               ; [F140]=$B5 DEC abs wrap flags

        ; ============================================================
        ; Memory-mode shifts and INC/DEC, abs,X with decoy neighbors
        ; ============================================================
        lda #$D1
        sta $F210               ; decoy
        lda #$D2
        sta $F211               ; decoy
        lda #$D3
        sta $F212               ; decoy
        lda #$C1
        sta $F213               ; ASL abs,X target ($F210+3)
        lda #$D4
        sta $F214               ; decoy
        lda #$E1
        sta $F215               ; base cell, must stay untouched
        lda #$E2
        sta $F216               ; decoy
        lda #$41
        sta $F217               ; LSR abs,X target ($F215+2)
        lda #$E3
        sta $F218               ; decoy
        lda #$F9
        sta $F219               ; base cell, must stay untouched
        lda #$80
        sta $F21A               ; ROL abs,X target ($F219+1)
        lda #$FA
        sta $F21B               ; decoy
        lda #$00
        sta $F21C               ; ROR abs,X target ($F219+3)
        lda #$F1
        sta $F220               ; decoy
        lda #$F2
        sta $F221               ; decoy
        lda #$F3
        sta $F222               ; decoy
        lda #$FE
        sta $F223               ; INC abs,X target ($F220+3)
        lda #$F4
        sta $F224               ; decoy
        lda #$A1
        sta $F225               ; base cell, must stay untouched
        lda #$01
        sta $F226               ; DEC abs,X target ($F225+1)
        lda #$A2
        sta $F227               ; decoy

        clc                     ; C=0
        lda #$77
        ldx #$03
        asl $F210,X             ; -> $F213: $C1 -> $82: C=1, N=1, A unchanged
        sta $F149               ; [F149]=$77 A unchanged by ASL abs,X
        php
        pla
        sta $F141               ; [F141]=$B5 ASL abs,X flags
        stx $F142               ; [F142]=$03 X unchanged
        ldx #$02
        lsr $F215,X             ; -> $F217: $41 -> $20: C=1, N cleared
        php
        pla
        sta $F143               ; [F143]=$35 LSR abs,X flags
        ldx #$01
        clc                     ; C=0
        rol $F219,X             ; -> $F21A: $80 rol 0 -> $00: C=1, Z=1
        php
        pla
        sta $F144               ; [F144]=$37 ROL abs,X zero flags
        ldx #$03
        sec                     ; C=1: ROR shifts 1 into bit7
        ror $F219,X             ; -> $F21C: $00 ror 1 -> $80: N=1, C=0
        php
        pla
        sta $F145               ; [F145]=$B4 ROR abs,X flags
        ldx #$03
        inc $F220,X             ; -> $F223: $FE -> $FF: N=1, C=0 preserved
        php
        pla
        sta $F146               ; [F146]=$B4 INC abs,X flags
        ldx #$01
        dec $F225,X             ; -> $F226: $01 -> $00: Z=1, C=0 preserved
        php
        pla
        sta $F147               ; [F147]=$36 DEC abs,X flags

        ; ------------------------------------------------------------
        ; Final marker: the very last data write of the program
        ; ------------------------------------------------------------
        lda #$5A                ; A=$5A: N=0, Z=0; C=V=D=0, I=1
        sta $F000               ; [F000]=$5A final marker

done:
