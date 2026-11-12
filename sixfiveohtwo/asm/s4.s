; sixfiveohtwo stage 4 smoke test.
;
; Exercises the stage 4 stack and flow ops: PHA, PLA, PHP, PLP, JMP
; abs, JMP (ind), JSR, RTS.
;
; PHA/PLA round trips are proven by the pulled value and by the N/Z
; flags PLA sets. PHP pushes the exact status byte (B=1, bit5=1),
; read back with PLA; PLP restores a pushed status byte (C and Z
; cases). SP is tracked with TSX through pushes, pulls, and JSR/RTS.
; Two-level nested JSR/RTS leaves return-1 bytes at $01FA-$01FD,
; C-checked while the markers inside the subroutines are stored
; (JSR pushes return-1; RTS adds 1 back). JMP abs skips a poison
; store; JMP (ind) runs a normal zero-page pointer and the NMOS
; page-wrap pointer ($10FF: the high byte is read from $1000). Each
; ind jump has a decoy high byte that sends a buggy CPU to a poison
; stub, and each is followed by an inline poison store that a
; fall-through mis-decode would execute.
;
; Stack-page writes come only from PHA/PHP/JSR. The $10FF/$1000/
; $1100 stores are runtime pointer setup for the page-wrap case
; (the wrap reads the pointer high byte from $xx00, so the pointer
; low byte must live at $xxFF with xx != $01). ca65's "jmp (abs)
; across page border" warning on the $10FF jump is expected: it
; flags exactly the wrap case under test.

        .segment "CODE"

start:
        ; ------------------------------------------------------------
        ; PHA/PLA round trip, PLA N/Z effects, SP tracking via TSX
        ; ------------------------------------------------------------
        lda #$C3
        pha                     ; push $C3 (SP $FD -> $FC)
        tsx
        stx $F100               ; [F100]=$FC SP after one push
        lda #$00                ; trash A: Z=1, N=0
        pla                     ; A=$C3: N=1, Z=0 (SP $FC -> $FD)
        sta $F101               ; [F101]=$C3 PHA/PLA round trip
        tsx
        stx $F102               ; [F102]=$FD SP restored after PLA
        sta $F001               ; marker 1: [F001]=$C3, N=1 Z=0 here
        lda #$00
        pha                     ; push $00 (SP $FD -> $FC)
        lda #$FF                ; N=1, Z=0 before the pull
        pla                     ; A=$00: N=0, Z=1 (SP $FC -> $FD)
        sta $F103               ; [F103]=$00 PLA zero result
        stx $F002               ; marker 2: [F002]=$FD (X), N=0 Z=1 here

        ; ------------------------------------------------------------
        ; PHP -> PLA: exact status byte on the stack (B=1, bit5=1)
        ; ------------------------------------------------------------
        clc                     ; C=0
        clv                     ; V=0
        lda #$01                ; N=0, Z=0
        php                     ; pushes P = %00110100 = $34
        pla                     ; A=$34: N=0, Z=0
        sta $F104               ; [F104]=$34 exact P byte (B=1, bit5=1)
        sec                     ; C=1
        lda #$80                ; N=1, Z=0
        php                     ; pushes P = %10110101 = $B5
        pla                     ; A=$B5: N=1, Z=0
        sta $F105               ; [F105]=$B5 exact P byte, N=1 C=1

        ; ------------------------------------------------------------
        ; PLP: restore a pushed status byte (C and Z cases)
        ; ------------------------------------------------------------
        sec                     ; C=1
        lda #$01                ; N=0, Z=0
        php                     ; pushes P = $35 (C=1, I=1)
        clc
        lda #$FF                ; C=0, N=1, Z=0: flags clobbered
        plp                     ; restore: C=1, N=0, Z=0 (bits 4,5 ignored)
        bcc pl1                 ; taken iff C=0 (bug)
        bmi pl1                 ; taken iff N=1 (bug)
        lda #$40
        adc #$00                ; $40+$00+C(1) = $41
        sta $F106               ; [F106]=$41 proves PLP restored C=1
        jmp pl2
pl1:    lda #$B2
        sta $F141               ; fail marker, only stored if PLP C/N broken
pl2:    lda #$00                ; Z=1, N=0
        php                     ; pushes P = $36 (Z=1, I=1)
        lda #$FF                ; Z=0, N=1: flags clobbered
        plp                     ; restore: Z=1, N=0, C=0
        bne pl3                 ; taken iff Z=0 (bug)
        bmi pl3                 ; taken iff N=1 (bug)
        lda #$60
        sta $F107               ; [F107]=$60 reached only if Z=1 and N=0
        jmp pl4
pl3:    lda #$B3
        sta $F142               ; fail marker, only stored if PLP Z/N broken
pl4:

        ; ------------------------------------------------------------
        ; JSR/RTS: two-level nesting, return-1 on the stack,
        ; subroutine-internal PHA/PLA discipline
        ; ------------------------------------------------------------
        jsr sub1
        tsx
        stx $F10B               ; [F10B]=$FD SP restored after both RTS
        jmp jsec                ; skip over the subroutine bodies

sub1:   tsx
        stx $F108               ; [F108]=$FB SP inside sub1 (outer JSR pushed 2)
        lda #$5A
        pha                     ; save A (SP $FB -> $FA)
        lda #$00                ; trash A: Z=1, N=0
        pla                     ; A=$5A restored (SP $FA -> $FB)
        cmp #$5A                ; Z=1, C=1 iff stack discipline held
        bne sb1                 ; taken iff A broken (bug)
        jmp sb2
sb1:    lda #$B4
        sta $F140               ; fail marker, only stored if PHA/PLA broken
sb2:    jsr sub2
        lda #$3C
        sta $F10A               ; [F10A]=$3C reached only if sub2 returned
        lda #$D1
        sta $F004               ; marker 4: inside sub1, after inner call
        rts

sub2:   tsx
        stx $F10F               ; [F10F]=$F9 SP inside sub2 (both JSRs pushed)
        lda #$7E
        sta $F109               ; [F109]=$7E stored inside sub2
        lda #$D2
        sta $F003               ; marker 3: inside sub2 (deepest level)
        rts

jsec:
        ; ------------------------------------------------------------
        ; JMP abs: skip a poison store
        ; ------------------------------------------------------------
        jmp over1
        lda #$BB
        sta $F143               ; poison fail marker, only stored if
                                ; JMP abs falls through (bug)
over1:  lda #$11
        sta $F10C               ; [F10C]=$11 proves JMP abs skipped the poison

        ; ------------------------------------------------------------
        ; JMP (ind): normal zero-page pointer
        ; ------------------------------------------------------------
        lda #$00
        sta $52                 ; pointer low ($00: indt1 is 256-aligned)
        lda #>indt1
        sta $53                 ; pointer high
        lda #>poison2
        sta $54                 ; decoy: reading the pointer high byte
                                ; from $54 (bug) lands in the poison stub
        jmp ($52)               ; -> indt1
        lda #$BB
        sta $F146               ; poison fail marker, only stored if
                                ; JMP (ind) falls through (bug)
        .align 256

indt1:
        lda #$33
        sta $F10D               ; [F10D]=$33 proves JMP (ind) landed correctly
        lda #$D5
        sta $F005               ; marker 5: ind stub (normal pointer)
        jmp resume2

        .align 256

poison2:
        lda #$BB
        sta $F144               ; fail marker, only stored if the pointer
                                ; high byte was read from $54 (bug)
        jmp resume2

resume2:
        ; ------------------------------------------------------------
        ; JMP (ind): page-wrap pointer ($10FF; NMOS bug reads the
        ; pointer high byte from $1000, not $1100)
        ; ------------------------------------------------------------
        lda #$00
        sta $10FF               ; pointer low ($00: wrapt1 is 256-aligned)
        lda #>wrapt1
        sta $1000               ; pointer high, read through the page wrap
        lda #>poison3
        sta $1100               ; decoy: a CPU without the wrap reads the
                                ; pointer high byte from $1100 -> poison
        jmp ($10FF)             ; low from $10FF, high from $1000 -> wrapt1
        lda #$BB
        sta $F147               ; poison fail marker, only stored if
                                ; JMP (ind) falls through (bug)
        .align 256

wrapt1:
        lda #$55
        sta $F10E               ; [F10E]=$55 proves the page wrap is emulated
        lda #$D4
        sta $F006               ; marker 6: ind stub (page-wrap pointer)
        jmp resume3

        .align 256

poison3:
        lda #$BB
        sta $F145               ; fail marker, only stored if the pointer
                                ; high byte was read from $1100 (no wrap)
        jmp resume3

resume3:
        ; ------------------------------------------------------------
        ; Final marker: the very last data write of the program
        ; ------------------------------------------------------------
        ldx #$E7
        ldy #$38
        clv                     ; V=0
        sec                     ; C=1
        lda #$96                ; A=$96: N=1, Z=0
        sta $F000               ; [F000]=$96 final marker

done:
        ; Execution falls through into the zero fill that follows the
        ; program; unknown opcodes behave as one-cycle NOPs, so the
        ; CPU idles harmlessly until the testbench finishes.