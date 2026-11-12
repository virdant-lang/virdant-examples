; sixfiveohtwo stage 6 smoke test.
;
; Exercises the stage 6 interrupt machinery: level-sensitive IRQ
; (masked by I), edge-triggered NMI (unmaskable), BRK, RTI, and the
; runtime-written interrupt vectors $FFFE/$FFFF and $FFFA/$FFFB.
;
; Choreography (marker -> testbench action):
;   1  $F001/$F002: irq level asserted while I=1 -> masked, $30 stays 0
;   2  $F003: CLI; level asserted -> IRQ taken, $30=1, RTI restores I=0
;   3  $F005: SEI; NMI edge -> taken despite I=1, $31=1
;   4  $F007: BRK pushes PC+2 with B=1; RTI resumes at the continuation
;   5  $F008/$F009: CLI/SEC/LDA #$80; IRQ taken; RTI restores N/C/I and
;      the ISR preserves A/X/Y (checkpoints + register snapshot)
;
; The ISR discipline: TSX must see the entry SP so that $0101,X is the
; stacked P byte, so X round-trips through zero-page scratch ($4E)
; instead of the stack; A and Y round-trip through the stack with
; PHA/PLA (+TAY/TYA). Each ISR increments its per-source counter
; ($30 irq, $31 nmi, $32 brk) through Y so the preservation dance is
; load-bearing.
;
; The BRK padding byte is .byte $00 and is never executed: BRK pushes
; PC+2, so RTI resumes at brk_cont. It doubles as a tripwire -- a
; buggy PC+1 push would land on it, re-enter the ISR and push $32 to
; 2. The BRK ISR also checkpoints the stacked PC to prove the pushed
; return address is exactly the continuation ($0245).

        .segment "CODE"

start:
        ; ------------------------------------------------------------
        ; Setup: mask interrupts, write the interrupt vectors at
        ; runtime (testbench memory is zero-filled)
        ; ------------------------------------------------------------
        sei                     ; I=1
        lda #<irq_isr
        sta $FFFE
        lda #>irq_isr
        sta $FFFF               ; IRQ/BRK vector -> irq_isr ($0276)
        lda #<nmi_isr
        sta $FFFA
        lda #>nmi_isr
        sta $FFFB               ; NMI vector -> nmi_isr ($028D)

        ; ------------------------------------------------------------
        ; Phase 1: IRQ level asserted while I=1 -> masked
        ; ------------------------------------------------------------
        lda #$11
        sta $F001               ; [F001]=$11 marker 1 (I=1, vectors set)
        lda #$22
        ldx #$44
        sta $F002               ; [F002]=$22 marker 2 (still masked: $30=0)

        ; ------------------------------------------------------------
        ; Phase 2: CLI unmasks; the pending level is taken
        ; ------------------------------------------------------------
        cli                     ; I=0
        lda #$33
        sta $F003               ; [F003]=$33 marker 3 (I=0, irq level next)
        lda #$55                ; hijacked here; re-executed after RTI
        sta $F004               ; [F004]=$55 marker 4 (post-IRQ: $30=1, I=0)

        ; ------------------------------------------------------------
        ; Phase 3: NMI edge taken even with I=1
        ; ------------------------------------------------------------
        sei                     ; I=1
        lda #$66
        sta $F005               ; [F005]=$66 marker 5 (I=1, NMI edge next)
        lda #$77                ; hijacked here; re-executed after RTI
        sta $F006               ; [F006]=$77 marker 6 (post-NMI: $31=1)

        ; ------------------------------------------------------------
        ; Phase 4: BRK pushes PC+2 with B=1; RTI resumes at brk_cont
        ; ------------------------------------------------------------
        lda #<brk_isr
        sta $FFFE
        lda #>brk_isr
        sta $FFFF               ; IRQ/BRK vector -> brk_isr ($02A4)
        lda #$99                ; flags at BRK: N=1, Z=0, I=1
        brk                     ; pushes brk_cont ($0245) with B=1
        .byte $00               ; padding: never executed (tripwire)
brk_cont:
        lda #<irq_isr
        sta $FFFE
        lda #>irq_isr
        sta $FFFF               ; restore irq_isr for phase 5
        lda #$88
        sta $F007               ; [F007]=$88 marker 7 (post-BRK: $32=1)

        ; ------------------------------------------------------------
        ; Phase 5: RTI restores N/C/I; ISR preserves A/X/Y
        ; ------------------------------------------------------------
        cli                     ; I=0: the pushed P will carry I=0
        ldx #$66
        ldy #$33
        sec                     ; C=1
        lda #$80                ; N=1, Z=0 (flags at hijack: N=1 C=1 I=0)
        sta $F008               ; [F008]=$80 marker 8
        sta $F120               ; [F120]=$80 A preserved across the IRQ
        stx $F121               ; [F121]=$66 X preserved across the IRQ
        sty $F122               ; [F122]=$33 Y preserved across the IRQ
        php                     ; push P (B=1, bit5=1)
        pla                     ; A = the pushed P byte: $B1
        sta $F123               ; [F123]=$B1 proves N=1, C=1, I=0 after RTI
        sta $F009               ; [F009]=$B1 marker 9 (register snapshot)

        ; ------------------------------------------------------------
        ; Final marker: the very last data write of the program
        ; ------------------------------------------------------------
        clc                     ; C=0
        lda #$E5                ; N=1, Z=0
        sta $F000               ; [F000]=$E5 final marker (SP=$FD, I=0)

done:

; --------------------------------------------------------------
; IRQ service routine ($FFFE for phases 2 and 5)
; --------------------------------------------------------------
irq_isr:
        stx $4E                 ; save the interrupted X (TSX clobbers X)
        tsx                     ; X = SP at entry: stacked P at $0101,X
        pha                     ; save the interrupted A
        tya
        pha                     ; save the interrupted Y
        lda $0101,X             ; stacked P (B=0; I=0 phase 2, I=0 phase 5)
        sta $F110               ; [F110]=$20 then $A1 stacked P, IRQ
        ldy $30
        iny
        sty $30                 ; irq counter++
        pla
        tay                     ; restore the interrupted Y
        pla                     ; restore the interrupted A
        ldx $4E                 ; restore the interrupted X
        rti                     ; pulls P (I=0 restored) and PC

; --------------------------------------------------------------
; NMI service routine ($FFFA)
; --------------------------------------------------------------
nmi_isr:
        stx $4E
        tsx
        pha
        tya
        pha
        lda $0101,X             ; stacked P (B=0, I=1)
        sta $F111               ; [F111]=$24 stacked P, NMI
        ldy $31
        iny
        sty $31                 ; nmi counter++
        pla
        tay
        pla
        ldx $4E
        rti                     ; pulls P (I=1 restored) and PC

; --------------------------------------------------------------
; BRK service routine ($FFFE during phase 4)
; --------------------------------------------------------------
brk_isr:
        stx $4E
        tsx
        pha
        tya
        pha
        lda $0101,X             ; stacked P (B=1, I=1)
        sta $F112               ; [F112]=$B4 stacked P, BRK
        lda $0102,X             ; stacked PCL = brk_cont low
        sta $F113               ; [F113]=$45 BRK pushed PC+2 (PCL)
        lda $0103,X             ; stacked PCH = brk_cont high
        sta $F114               ; [F114]=$02 BRK pushed PC+2 (PCH)
        ldy $32
        iny
        sty $32                 ; brk counter++
        pla
        tay
        pla
        ldx $4E
        rti                     ; resumes at brk_cont ($0245)