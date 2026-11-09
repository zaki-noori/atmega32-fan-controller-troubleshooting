;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Control.asm                                                               ;
;                                                                           ;
;   Below 40C      -> all fans OFF                                          ;
;   40C - 50C      -> Fan1 + Fan2 ON                                        ;
;   50C - 60C      -> Fan2 + Fan3 ON                                        ;
;   60C - 75C      -> Fan1 + Fan3 ON                                        ;
;   Above 75C      -> all fans ON                                           ;
; Auto switch (PA1) ON = automatic, OFF = manual (M1/M2/M3 -> fans).        ;
; Current loop broken annunciator: PA6 input -> PB6 LED.                    ;
; Auto annunciator LED on PB3.                  ;
;                                                                           ;
; ADC to Temperature values                                                 ;
; 40C = $019A, 50C = $0200, 60C = $0260, 75C = $0300                        ;
;                                                                           ;
; Created: 17/10/2024 8:00:00 AM                                            ;
; Original: Sukhvir Singh Judge (teacher template)                          ;
; Modified: Zaki Noori - new fan table, Auto/Manual override,               ;
;           annunciators, subroutine structure (2026)                       ;
;                                                                           ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.def temp = r16


.equ AUTO_SW = PA1
.equ M1_SW   = PA2
.equ M2_SW   = PA3
.equ M3_SW   = PA4
.equ LOOP_IN  = PA6              ; current loop broken signal input
.equ LOOP_LED = PB6              ; current loop broken annunciator LED 

.CSEG

    .org $0
    rjmp start                  ; reset - jump to main program

    .org $0E
    jmp Control_routine         ; Timer1 compare match A - every 1 second

    .org $60

start:

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Setup Stack Pointer                                                      ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    ldi temp, high(RAMEND)      ; high byte of RAMEND ($08)
    out SPH, temp               ; stack pointer high
    ldi temp, low(RAMEND)       ; low byte of RAMEND ($5F)
    out SPL, temp               ; stack pointer low

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Setup PB0, PB1, PB2 (FAN1, FAN2, FAN3) and PB3 (Auto LED) as outputs     ;
; Setup Port A as input port (PA0 = ADC temperature)                       ;
; Setup PD5 as output (OC1A - heater)                                      ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    ldi temp, $4F               ; $4F (0100 1111) - PB0-PB3 + PB6 outputs
    out DDRB, temp

    ldi temp, $00               ; $00 (0000 0000) - all Port A inputs
    out DDRA, temp

    ldi temp, $20               ; $20 (0010 0000) - PD5 output (heater)
    out DDRD, temp

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Setup A/D converter                                                      ;
; ADCSRA=$80 ; ADMUX=$40                                                   ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    ldi temp, $80               ; $80 (1000 0000) - ADEN = 1, ADC enabled
    out ADCSRA, temp
    ldi temp, $40               ; $40 (0100 0000) - AVCC reference, channel ADC0 (PA0)
    out ADMUX, temp

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Setup Timer1A to generate an interrupt at every one second to read       ;
; temperature and control fans accordingly                                 ;
; TCCR1A=$40; TCCR1B=$0C ; TIMSK=$10; OCR1AH=$7A; OCR1AL=$12               ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    ldi temp, $40               ; COM1A0 = 1 - toggle OC1A (PD5 heater) on compare match
    out TCCR1A, temp
    ldi temp, $7A               ; OCR1A = $7A12 = 31250 - write high byte first
    out OCR1AH, temp
    ldi temp, $12               ; low byte - both halves go in together
    out OCR1AL, temp
    ldi temp, $10               ; OCIE1A = 1 - allow compare match A interrupt
    out TIMSK, temp
    ldi temp, $0C               
    out TCCR1B, temp

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Enable interrupt                                                         ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    sei                         ; global interrupt enable

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; User program                                                             ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
here:
    rjmp here                   ; wait - timer interrupt does the work

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Interrupt routine - runs every 1 second                                  ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

Control_routine:
        call Read_ADC           ; subroutine: read temperature into Z
        call Check_Loop         ; subroutine: current loop broken annunciator

        sbic PINA, AUTO_SW      ; Auto switch OFF (0)? -> skip next   
        call Auto_Mode          ;   Auto ON  -> automatic fan table
        sbis PINA, AUTO_SW      ; Auto switch ON (1)? -> skip next
        call Manual_Mode        ; Auto OFF -> manual M1/M2/M3

        reti                    ; return from interrupt

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; SUBROUTINE: Read Analog Value, convert to Digital and store in Z         ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

Read_ADC:
        sbi ADCSRA, ADSC        ; start conversion
loop1:  sbic ADCSRA, ADSC       ; ADSC cleared = conversion finished -> skip next
        rjmp loop1              ; not finished - keep waiting
        in ZL, ADCL             ; Read ADCL first (locks full 10-bit result)
        in ZH, ADCH             ; Then read ADCH
        ret                     ; return from subroutine

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; SUBROUTINE: Auto_Mode - compare Z (temperature) with each value in X     ;
; and turn the fans ON/OFF as per the Case 2 table                         ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

Auto_Mode:
        sbi PORTB, PB3          ; Auto annunciator LED ON

        ldi XL, $9A             ; X = $019A (40C)
        ldi XH, $01
        cp  ZL, XL              ; compare low bytes
        cpc ZH, XH              ; compare high bytes (with carry)
        brlo All_Off            ; below 40C -> all fans off

        ldi XL, $00             ; X = $0200 (50C)
        ldi XH, $02
        cp  ZL, XL
        cpc ZH, XH
        brlo Fan_12             ; 40-50C -> fans 1 + 2

        ldi XL, $60             ; X = $0260 (60C)
        ldi XH, $02
        cp  ZL, XL
        cpc ZH, XH
        brlo Fan_23             ; 50-60C -> fans 2 + 3

        ldi XL, $00             ; X = $0300 (75C)
        ldi XH, $03
        cp  ZL, XL
        cpc ZH, XH
        brlo Fan_13             ; 60-75C -> fans 1 + 3
                                ; otherwise fall through -> above 75C
All_On:
        sbi PORTB, PB0          ; fan 1 ON
        sbi PORTB, PB1          ; fan 2 ON
        sbi PORTB, PB2          ; fan 3 ON
        rjmp Fans_Done

All_Off:
        cbi PORTB, PB0          ; fan 1 OFF
        cbi PORTB, PB1          ; fan 2 OFF
        cbi PORTB, PB2          ; fan 3 OFF
        rjmp Fans_Done

Fan_12:
        sbi PORTB, PB0          ; fan 1 ON
        sbi PORTB, PB1          ; fan 2 ON
        cbi PORTB, PB2          ; fan 3 OFF
        rjmp Fans_Done

Fan_23:
        cbi PORTB, PB0          ; fan 1 OFF
        sbi PORTB, PB1          ; fan 2 ON
        sbi PORTB, PB2          ; fan 3 ON
        rjmp Fans_Done

Fan_13:
        sbi PORTB, PB0          ; fan 1 ON
        cbi PORTB, PB1          ; fan 2 OFF
        sbi PORTB, PB2          ; fan 3 ON

Fans_Done:
        ret                     ; return from subroutine

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; SUBROUTINE: Manual_Mode - M1/M2/M3 switches control each fan directly    ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

Manual_Mode:
        cbi PORTB, PB3          ; Auto annunciator LED OFF

        sbic PINA, M1_SW        ; M1 OFF? -> skip next
        sbi  PORTB, PB0         ;   M1 ON  -> fan 1 ON
        sbis PINA, M1_SW        ; M1 ON? -> skip next
        cbi  PORTB, PB0         ;   M1 OFF -> fan 1 OFF

        sbic PINA, M2_SW        ; M2 OFF? -> skip next
        sbi  PORTB, PB1         ;   M2 ON  -> fan 2 ON
        sbis PINA, M2_SW        ; M2 ON? -> skip next
        cbi  PORTB, PB1         ;   M2 OFF -> fan 2 OFF

        sbic PINA, M3_SW        ; M3 OFF? -> skip next
        sbi  PORTB, PB2         ;   M3 ON  -> fan 3 ON
        sbis PINA, M3_SW        ; M3 ON? -> skip next
        cbi  PORTB, PB2         ;   M3 OFF -> fan 3 OFF

        ret                     ; return from subroutine

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; SUBROUTINE: Check_Loop - current loop broken annunciator                 ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

Check_Loop:
        sbic PINA, LOOP_IN      ; loop signal OFF (0)? -> skip next
        sbi  PORTB, LOOP_LED    ;   loop broken -> annunciator LED ON
        sbis PINA, LOOP_IN      ; loop signal ON (1)? -> skip next
        cbi  PORTB, LOOP_LED    ;   loop OK -> annunciator LED OFF
        ret                     ; return from subroutine
