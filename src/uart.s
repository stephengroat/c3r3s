.macro push a, b
  stp \a, \b, [sp, #-16]!
.endm

.macro pop a, b
  ldp \a, \b, [sp], #16
.endm

.set GPIO_BASE, 0x3f200000
.set UART_BASE, 0x3f201000

// uart registers:
.set DR, 0
.set RDRECR, 4
.set FR, 0x18
.set IBRD, 0x24
.set FBRD, 0x28
.set LCRH, 0x2c
.set CR, 0x30
.set IFLS, 0x34
.set IMSC, 0x38
.set RIS, 0x3c
.set MIS, 0x40
.set ICR, 0x44
.set DMACR, 0x48

// gpio registers:
.set GPPUD, 0x94
.set GPPUDCLK0, 0x98
.set GPPUDCLK1, 0x9c

.set MODE_OFF, 0
.set TXD0, 14
.set RXD0, 15

.set USE_FIFO_8N1, 0x70
.set MASK_ALL, 0x7ff
.set ENABLE_RX_TX, 0x301

.set BIT_FR_TX_FULL, 6

.set FR_TX_EMPTY, 0x80
.set FR_TX_FULL, 0x20
.set FR_RX_EMPTY, 0x10

.text

// [w0: uart_clock, w1: bps]
.global uart_init
uart_init:
  push fp, lr

  // the baud divisor is stored as a 16Q6 fixed point, with the integer
  // part in IBRD and the fraction in FBRD. the manual says the divisor is
  // calculated from `uart_clock / (16 * bps)`.
  mov w0, w0, lsl #2
  udiv w0, w0, w1
  and w5, w0, #0x3f
  mov w4, w0, lsr #6

  // shut off the uart
  ldr w3, =UART_BASE
  str wzr, [x3, #CR]

  // configure the RX/TX pins so they're not attached to the pulldown
  ldr w2, =GPIO_BASE
  mov w0, #MODE_OFF
  str w0, [x2, #GPPUD]
  bl delay_small
  mov w0, #((1 << TXD0) | (1 << RXD0))
  str w0, [x2, #GPPUDCLK0]
  str wzr, [x2, #GPPUDCLK1]
  bl delay_small
  str wzr, [x2, #GPPUDCLK0]
  str wzr, [x2, #GPPUDCLK1]

  // clear all pending interrupts
  ldr w0, =MASK_ALL
  str w0, [x3, #ICR]

  // set bps
  str w4, [x3, #IBRD]
  str w5, [x3, #FBRD]

  // use fifo, set 8N1, and re-enable the uart
  mov w0, #USE_FIFO_8N1
  str w0, [x3, #LCRH]
  ldr w0, =MASK_ALL
  str w0, [x3, #IMSC]
  ldr w0, =ENABLE_RX_TX
  str w0, [x3, #CR]

  pop fp, lr
  ret

// [w0] -> uart
// trash: x0 - x2
.global uart_write
uart_write:
  dmb sy
  ldr w2, =UART_BASE
1:
  ldr w1, [x2, #FR]
  tbnz w1, #BIT_FR_TX_FULL, 1b
  str w0, [x2, #DR]
  ret

// write 32 bits as 8 hex digits
// [w3] -> uart
// trash: x0 - x6
.global uart_write_hex
uart_write_hex:
  mov w4, #32
  mov w5, #0xf0000000
  mov x6, lr
1:
  sub w4, w4, #4
  and w0, w3, w5
  lsr w0, w0, w4
  add w0, w0, #'0'
  cmp w0, #'9'
  bls 2f
  add w0, w0, #('a' - '9' - 1)
2:
  bl uart_write
  lsr w5, w5, #4
  cbnz w4, 1b
  ret x6

// write the 4 letters pointed to by x3
// [x3] -> uart
// trash: x0 - x5
.global uart_write_word
uart_write_word:
  add x4, x3, #4
  // fall thru

// [x3: start, x4: end] -> uart
// trash: x0 - x5
.global uart_write_string
uart_write_string:
  mov x5, lr
1:
  ldrb w0, [x3], #1
  bl uart_write
  cmp x3, x4
  b.ne 1b
  ret x5


// [r0: data]
//.global uart_write_u32
//uart_write_u32:
//  // r1 = shift
//  mov r1, #0
//  ldr r3, =UART_BASE
//1:
//  dmb
//  ldr r2, [r3, #FR]
//  tst r2, #FR_TX_FULL
//  bne 1b
//  mov r2, r0, lsr r1
//  strb r2, [r3, #DR]
//  add r1, #8
//  cmp r1, #32
//  blo 1b
//  bx lr

// -> [w0: byte if Z is clear]
// trash: x0 - x2
.global uart_probe
uart_probe:
  dmb sy
  ldr w2, =UART_BASE
  ldr w1, [x2, #FR]
  ldr w0, [x2, #DR]
  and w0, w0, #0xff
  tst w1, #FR_RX_EMPTY
  ret

// read LSB 32-bit from uart
// -> [w3]
// trash: x0 - x5
.global uart_read_u32
uart_read_u32:
  mov x5, lr
  // w3 = accumulator, w4 = shift
  mov w3, #0
  mov w4, #0
1:
  bl uart_probe
  b.ne 1b
    bl uart_write
  lsl w0, w0, w4
  add w3, w3, w0
  add w4, w4, #8
  tbz w4, #5, 1b
  ret x5

// [x6: start_addr, x7: end_addr] (align 4)
// trash: x0 - x8
.global uart_read_block
uart_read_block:
  mov x8, lr
1:
  bl uart_read_u32
  str w3, [x6], #4
  cmp x6, x7
  b.lo 1b
  ret x8

// [r0: start_addr, r1: end_addr] (align 4)
//.global uart_read_block
//uart_read_block:
//  push {r4, r5, lr}
//  mov r4, r0
//  mov r5, r1
//1:
//  bl uart_read_u32
//  str r0, [r4], #4
//  cmp r4, r5
//  blo 1b
//  pop {r4, r5, lr}
//  bx lr
