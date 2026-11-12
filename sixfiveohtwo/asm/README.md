# sixfiveohtwo smoke-test conventions

Shared rules for `asm/sN.s` + `asm/sN.exp` test programs. Read `asm/s3.s` /
`asm/s3.exp` for a complete house-style example.

## Program (ca65)

- Header: `        .segment "CODE"` then label `start:`. Code is placed
  contiguously from `$0200` (the testbench writes reset vector `$0200`).
  NO `.org`. ca65 syntax, `;` comments, labels `name:`, `<`/`>` byte
  operators available.
- Checkpoint stores go to `$F100`-`$F1FF`, one store per verified fact,
  each commented with its expected value.
- Never store directly to `$0000-$000F` or `$F000-$F0FF` (markers and
  checkpoints excepted). Never store directly to the stack page
  `$0100-$01FF` (only PHA/PHP/JSR write it).
- Scratch memory: zero page `$10`-`$5F`, absolute `$F200`-`$F5FF`.
- The final marker `lda #$XX` / `sta $F000` is the very last executed
  data write of the program, on the main flow. Leave SP = `$FD` at the
  end (balance pushes/JSR) unless the test is explicitly about SP.

## Expectations (asm/sN.exp)

Processed top-to-bottom by the testbench after reset:

- `M <addr4> <byte2>` — wait until the program stores exactly `<byte>`
  at `<addr>`. All following `F`/`R`/`C`/`P` records apply at that
  moment, until the next `M`.
- `F <flag> <0|1>` — CPU flag check; flag letters N Z C V D I.
- `R <reg> <hex>` — register check; A X Y S (=SP) P (=PC, hex4).
- `C <addr4> <hex2>` — memory comparison.
- `P <I|N> <0|1>` — drive the irq_n (I) or nmi_n (N) pin to the given
  level (active-low: 0 = asserted). Only meaningful for the interrupt
  test (s6).
- `#` starts a comment line.

First line of the file = the FIRST marker the program stores. Last
section = `M F000 <byte>` followed by the complete final snapshot:
all six flags + A/X/Y/S/P.

## Reset state (after reset, before program)

A=X=Y=0, SP=`$FD`, N=V=D=Z=C=0, I=1.

## Mandatory verification (every test)

1. Assemble + convert: `cd sixfiveohtwo && make build/sN.hex build/sN.exp.hex`
   — both must succeed.
2. Reference simulation: write a small Python 6502 simulator in `/tmp`
   (correct 6502 semantics for the ISA the test uses; reset vector
   `$0200`, SP=`$FD`, I=1; for s6 also emulate the `P` pin drives at the
   points the tb would apply them — right after the preceding marker's
   store). Load `build/sN.bin`, execute, and check EVERY exp record in
   order. Iterate until every record passes — fix the program or the
   expectations; never weaken a check without understanding why.
3. Paper-trace the final snapshot (flags, A, X, Y, SP, PC) and encode it
   exactly.

## CPU flag facts

- After reset: N=0 V=0 D=0 I=1 Z=0 C=0.
- PHP pushes P with bit5=1 and B (bit4)=1; IRQ/NMI push B=0; BRK pushes
  B=1. PLP/RTI ignore bits 4,5.
- PLA sets N,Z from the pulled value. TXS sets no flags; TSX does.
- ADC: C=carry out, V=(a7==b7)&&(r7!=a7), N=r7, Z=(r==0).
- SBC: C=no-borrow, V=(a7!=b7)&&(r7!=a7), N/Z from the binary result.
- CMP/CPX/CPY: C = reg>=mem, N/Z from (reg-mem); register unmodified.
- BIT: Z=(A&M)==0, N=M bit7, V=M bit6.
- ASL/LSR/ROL/ROR: N,Z from result, C = shifted-out bit; ROL shifts C
  into bit0, ROR into bit7. INC/DEC: N,Z only.
- Decimal mode (S7, D=1, NMOS/Bruce Clark): ADC — low=(a&0F)+(b&0F)+C,
  low_carry = low>=10, high=(a&F0)+(b&F0)+(low_carry?10:0) [9-bit],
  N=high[7], V=(a7==b7)&&(high[7]!=a7), C=high>=0xA0,
  result=((C?high+0x60:high)&F0)|((low_carry?low+6:low)&0F), Z=result==0.
  SBC — binary subtract bin=a+(~b)+C gives N,V,Z; decimal result/C:
  low=(a&0F)-(b&0F)-(1-C), if low<0 low-=6 borrow=1;
  high=(a&F0)-(b&F0)-(borrow?10:0), if high<0 high-=0x60 C=0 else C=1;
  result=(high&F0)|(low&0F).
