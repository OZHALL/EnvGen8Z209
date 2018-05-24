; TODO INSERT CONFIG CODE HERE USING CONFIG BITS GENERATOR
; ozh - note I followed the configurations from another project which was MCC generated
;2018-05-03 ozh - updated port_init with MCC generated pin_manager.  It compiles, but ...
;		looks like I broke the funcdtionality.  Need to debug this new code.
;2018-05-03 ozh - ANSELC configuration issue.  LEDs are digital pins, not analog
;		  code works to flash LED
;2018-05-06 ozh - once I configured SPI Mode 0, the DAC output works with the following:
;	RB7 - SPI Data Out (MOSI)
;       RB6 - SPI Clock
;       RB5 - SPI /CS (for MCP4922)
;       RC2 - SPI Data Out (MISO) - have to allocate the pin, though we don't use it
;       RA0 thru RA7(AN0-AN7) are all faders - analog inputs
;       RB0 thru RB4 are outputs driving the LEDs on the faders (0-4)
;       RC5 thru RC7 are outputs driving the LEDs on the faders (5-7)  
;2018-05-06 ozh - debug outputting to both DAC0 and DAC1  
;2018-05-07 ozh - hand optimize where I can
;2018-05-07 ozh - add EnvGen8 code and integrate with my hardware config and DAC output
;2018-05-08 ozh - got the interrupt timer working.  I press the gate & LED 1 flashes!!! 
;2018-05-08 ozh - I've got an envelope of sorts, but the output is goofy.  Multiple ramps per stage
;		    I think this is a "Dacout" impedance mismatch.
;		    Fixed this by changing the 16 bit output value to 12 bits
; TODO: still have a problem cuz Release jumps up to 100% from sustain level before going to 0
;	Next up: get the ADSR parameters input from the faders
;2018-05-10 ozh - ADSR from faders is working!   Release issue solved (thx Tom W.!)
;2018-05-11 ozh - memory copy routine written/debugged to save/restore 20 essential variables.  
;		    this will support executing the interrupt code twice - once for each EG
;2018-05-12 ozh - call CopyFromModel at the beginning of the interrupt breaks the code, even with just one EG
;                 I'm not sure why.  stepping through the code seems to work correctly. (double check variables at offset 16)
;		  There may be some missing variables in the "model".  
;2018-05-13 ozh - rearrange memory & stick the "models" in banks 1 & 2, with main variables in bank 0
;		  at this point, w/o using the copy routines, envelope 0 works
;2018-05-13 ozh - added an indicator (Sustain LED on EG1) if there is an overrun in the interrupt service routine
;2018-05-15 ozh - move START_HI/_LO and OUTPUT_HI/_LO to bank switched ram
;		  FSR0 is used in the main routine.  FSR1 in the interrupt routine.
;		  save off FSR0 on entering the Int Svc Rtn (ISR) and restore it just before retfie
;2018-05-15 ozh - clean up the Model Copy routines
;2018-05-18 ozh - change model to set up for bank switching.  bank 0 is EG0 bank 2 is EG1
;		  EG0 still works, but we're only using the CopyToModel to copy EG0 to EG1.  CopyFromModel is unused
;		  note also that the EG0 model is mapped to the "original" variables.  
;                 We've just added alternate M0_ names to the same memory locations
;          * * * EG0 works, but the bank switching is completely untested * * *
;2018-05-22 ozh - hardcoded bank 1 (for EG1) and it works, if you preserve BSR before accessing PORTC and LATB
;		  I have the second Sustain controlling EG0 correctly
;2018-05-23 ozh - this is starting to work.  I have an envelope output on DAC1 (vs DAC0).  attack/decay are coming from EG0 :(
;2018-05-23 ozh - it believe the separate gate logic is working now
;		  BTW, there was a problem with BSR getting changed somehow.   The problem is that TEMP_BSR was used by 
;		  both the main and interrupt code (stupid!).  I created TEMP_BSR_INTR for use in the interrupt code. - problem solved
;2018-05-23 ozh	- looks like I have a fully functional EG1, but I have not tried servicing both in one interrupt
;		  I'm almost there with both, but not quite.  
	
;"Never do single bit output operations on PORTx, use LATx 
;   instead to avoid the Read-Modify-Write (RMW) effects"
;
	
; PIC16F18855 Configuration Bit Settings

; Assembly source line config statements
	LIST R=DEC
	#include "p16f18855.inc"
	Errorlevel -302 

; CONFIG1
; __config 0x3FEC
 __CONFIG _CONFIG1, _FEXTOSC_OFF & _RSTOSC_HFINT1 & _CLKOUTEN_OFF & _CSWEN_ON & _FCMEN_ON
; CONFIG2
; __config 0x3FFF
 __CONFIG _CONFIG2, _MCLRE_ON & _PWRTE_OFF & _LPBOREN_OFF & _BOREN_ON & _BORV_LO & _ZCD_OFF & _PPS1WAY_ON & _STVREN_ON
; CONFIG3
; __config 0x3F9F
 __CONFIG _CONFIG3, _WDTCPS_WDTCPS_31 & _WDTE_OFF & _WDTCWS_WDTCWS_7 & _WDTCCS_SC
; CONFIG4
; __config 0x1FFF
 __CONFIG _CONFIG4, _WRT_OFF & _SCANE_available & _LVP_OFF
; CONFIG5
; __config 0x3FFF
 __CONFIG _CONFIG5, _CP_OFF & _CPD_OFF

 
;-------------------------------------
;	DEFINE STATEMENTS
;-------------------------------------

; Useful bit definitions for clarity	
#define NOT_CS		PORTB,5         ; RB5 
#define BIT0 		b'00000001'
#define BIT1 		b'00000010'
#define BIT2 		b'00000100'
#define BIT3 		b'00001000'
#define BIT4 		b'00010000'
#define BIT5 		b'00100000'
#define BIT6 		b'01000000'
#define BIT7 		b'10000000'
#define STEPSIZE	0x10
#define DAC0		0x00
#define DAC1		BIT7
#define SAVETOW		0x00
#define SAVETOF		0x01
#define USEACCESSBANK	0x00 ;untested
#define USEBSR		0x01 ;untested


;================================================================
; begin orig ENVGEN8 code
;================================================================
 
  title  "DUAL ADSR"
;============================================================================
;	ELECTRIC DRUID VOLTAGE CONTROLLED ADSR VERSION 8
;============================================================================
; Legal stuff
; Copyright 2018 Tom Wiltshire for Electric Druid. Some rights reserved.
; This code is shared under a Creative Commons
; Attribution-NonCommercial-ShareAlike 4.0 International Licence
; For full details see www.electricdruid.net/legalstuff
; or get in touch at www.electricdruid.net/contact.
;============================================================================
 
; This program provides a versatile envelope generator on a single chip.
; It is designed as a modern version of the CEM3312 or SSM2056 ICs.
; Analogue output is provided by the 10 bit DAC, via the op-amp buffer.
; Envelope level control is using the DAC's Ref+ input, so no resolution is
; lost at low output amplitude.
;
; Hardware Notes:
;	PIC16F1764 running at 32 MHz using the internal clock
; 1  +5V
; 2  RA5			: Punch On/Off 0=APDSR, 1=ADSR (fixed 5msec hold stage)
; 3  RA4			: 0-5V Mode CV
; 4  RA3/~MCLR/Vpp	: Envelope Type (0=Lin/1=Exp)
; 5  RC5			: Gate Input
; 6  RC4			: Trigger Input
; 7  RC3			: 0-5V Time CV
; 8  RC2/OPA1 OUT	: Envelope Output
; 9  RC1/AN5		: 0-5V Release CV
; 10  RC0/AN4		: 0-5V Sustain CV
; 11  RA2/AN2		: 0-5V Decay CV
; 12  RA1/DAC1REF+	: 0-5V Level CV
; 13  RA0/AN0		: 0-5V Attack CV
; 14  Gnd
;
;	1) Change pin assignments in the ENVGEN8 code to match my PIC16F18855 hardware:
;
;	Function    Existing        My New Hardware
;
;	Attack -     RA1/AN0    RA0/ANA0
;
;	Decay -     RA2/AN2    RA1/ANA1
;
;	Sustain -   RC0/AN4    RA2/ANA2
;
;	Release -   RC1/AN5    RA3/ANA3
;
;	Trigger -    RA0            RC0
;
;	Gate -         RA1            RC0 (merge trigger &amp; gate cuz DOTCOM only has Gate)  
; This version started as ENVGEN7B.ASM, the ultimate version of my 16F684
; envelope code, developed between 29th Aug 2006 and 14th May 2008
;
; 28th Jan 2018: ENVGEN8.ASM
; Combined the features of LOOPENV1B and ENVGEN7B into one chip.
; Reconfigured things to take advantage of the 10-bit DAC and it's Vref+ input
; for level control without loss of resolution.
;
; 4 Feb 2018 - finishing off
; Adding fixed-length Punch stage and selector input. Testing Time CV.
; Tidying up code.


;	LIST R=DEC
;	INCLUDE <p16f1764.inc>
;	Errorlevel -302

; 16F1764/5 Configuration
; __CONFIG _CONFIG1, _FOSC_INTOSC & _WDTE_OFF & _PWRTE_ON & _MCLRE_OFF & _CP_OFF & _BOREN_OFF & _CLKOUTEN_OFF & _IESO_OFF & _FCMEN_OFF
; __CONFIG _CONFIG2, _WRT_OFF & _PLLEN_ON & _STVREN_ON & _BORV_LO & _LPBOR_OFF & _LVP_OFF

; Assembler has a problem with these: PPS1WAY_OFF & ZCD_OFF
; Weird, since they're in the include file

;------------------------------
;	Variables
;------------------------------

 CBLOCK 0x020
	; begin 20 variables which are EG specific
	; The current stage 
	STAGE	; 0=Wait, 1=Attack, 2=Punch, 3=Decay, 4=Sustain, 5=Release, 0=Wait
	; The debounce counters for GATE and TRIGGER
	DEBOUNCE_HI
	DEBOUNCE_LO
	STATES						; The output state from the debounce
	CHANGES						; The bits that have altered
	; The 24 bit phase accumulator
	PHASE_HI
	PHASE_MID
	PHASE_LO
	; The 20 bit frequency increments
	; These are stored separately for Attack, Decay, & Release
	; Note that these increments have been adjusted to reflect
	; changes due to TIME_CV, whereas the raw CVs haven't
	ATTACK_INC_LO
	ATTACK_INC_MID
	ATTACK_INC_HI
	PUNCH_INC_LO				; Punch stage is not variable
	PUNCH_INC_MID
	PUNCH_INC_HI
	DECAY_INC_LO
	DECAY_INC_MID
	DECAY_INC_HI
	RELEASE_INC_LO
	RELEASE_INC_MID
	RELEASE_INC_HI	

	; The current output level when an Attack or Release starts
	START_HI	
	START_LO
	; The 12 bit output level
	OUTPUT_HI	
	OUTPUT_LO

	; The current control voltage(CV) values (8 bit)
	ATTACK_CV					; These first four aren't actually used any more
	DECAY_CV					; Instead we find a PHASE INC value and use that
	SUSTAIN_CV
	RELEASE_CV
;	ATTACK1_CV					; These first four aren't actually used any more
;	DECAY1_CV					; Instead we find a PHASE INC value and use that
;	SUSTAIN1_CV
;	RELEASE1_CV		
	; The working storage for the interpolation subroutine
	INPUT_X_HI					; Two inputs, X and Y
	INPUT_X_LO
	INPUT_Y_HI
	INPUT_Y_LO
	CURVE_OUT_HI				; The final, interpolated, curve output
	CURVE_OUT_LO
	; Working storage for the 10x10-bit multiply subroutine
	MULT_IN_HI
	MULT_IN_LO					; CURVE_OUT is the other input
	MULT_OUT_HI
	MULT_OUT_LO

	TIME_CV						; TIME is used directly
	MODE_CV						; Used to set the LFO_MODE and LOOPING flags
	
  ENDC
  
  ;bank 2
  CBLOCK 0x120	
	; begin model for EG 1
	; The current stage 
	M1_STAGE	; 0=Wait, 1=Attack, 2=Punch, 3=Decay, 4=Sustain, 5=Release, 0=Wait
	; The debounce counters for GATE and TRIGGER
	M1_DEBOUNCE_HI
	M1_DEBOUNCE_LO
	M1_STATES						; The output state from the debounce
	M1_CHANGES						; The bits that have altered
	; The 24 bit phase accumulator
	M1_PHASE_HI
	M1_PHASE_MID
	M1_PHASE_LO
	; The 20 bit frequency increments
	; These are stored separately for Attack, Decay, & Release
	; Note that these increments have been adjusted to reflect
	; changes due to TIME_CV, whereas the raw CVs haven't
	M1_ATTACK_INC_LO
	M1_ATTACK_INC_MID
	M1_ATTACK_INC_HI
	M1_PUNCH_INC_LO				; Punch stage is not variable
	M1_PUNCH_INC_MID
	M1_PUNCH_INC_HI
	M1_DECAY_INC_LO
	M1_DECAY_INC_MID
	M1_DECAY_INC_HI
	M1_RELEASE_INC_LO
	M1_RELEASE_INC_MID
	M1_RELEASE_INC_HI
	; The current output level when an Attack or Release starts
	M1_START_HI	
	M1_START_LO
	; The 12 bit output level
	M1_OUTPUT_HI	
	M1_OUTPUT_LO
	
	; The current control voltage(CV) values (8 bit)
	M1_ATTACK_CV					; These first four aren't actually used any more
	M1_DECAY_CV					; Instead we find a PHASE INC value and use that
	M1_SUSTAIN_CV
	M1_RELEASE_CV
	
	; The working storage for the interpolation subroutine
	M1_INPUT_X_HI					; Two inputs, X and Y
	M1_INPUT_X_LO
	M1_INPUT_Y_HI
	M1_INPUT_Y_LO
	M1_CURVE_OUT_HI				; The final, interpolated, curve output
	M1_CURVE_OUT_LO
	; Working storage for the 10x10-bit multiply subroutine
	M1_MULT_IN_HI
	M1_MULT_IN_LO					; CURVE_OUT is the other input
	M1_MULT_OUT_HI
	M1_MULT_OUT_LO

	; end EG 1
 ENDC

; 0x70-0x7F  Common RAM - Special variables available in all banks
 CBLOCK 0x070
	TEMP						; Useful working storage
	FLAGS						; See Defines below
	; The current A/D channel and value
	ADC_CHANNEL	;0x72
	ADC_VALUE

	; temp variables
	WORK_HI		;0x78
	WORK_LO
	DAC_NUMBER	;0x7A
	LOOP_COUNTER
	GIE_STATE	;0x7C
	OVERRUN_FLAG
	;temp storage
	TEMP_BSR	;0x7E
	TEMP_BSR_INTR	;for use in Interrupt ONLY
	TEMP_W_INTR
	FAKE_PUNCH_EXPO
;	TEST_COUNTER_HI
;	TEST_COUNTER_LO
 ENDC

;-------------------------------------
;	DEFINE STATEMENTS
;-------------------------------------

; Useful bit definitions for clarity	
#define ZERO		STATUS,Z	; Zero Flag
#define CARRY		STATUS,C	; Carry Flag
#define BORROW		STATUS,C	; Borrow is the same as Carry

; Options selection definitions
;#define USE_ADSR	PORTA, 5	; Add Punch stage? (0=APSDR, 1=Standard ADSR)
;#define USE_EXPO	PORTA, 3	; Linear or exponential envelope?	(1=Expo)
#define USE_ADSR	FAKE_PUNCH_EXPO, 5	; Add Punch stage? (0=APSDR, 1=Standard ADSR)
#define USE_EXPO	FAKE_PUNCH_EXPO, 3	; Linear or exponential envelope?	(1=Expo)
 
; Flag bit definitions
#define LFO_MODE	FLAGS, 0	; LFO mode (makes env loop endslessly)
#define LOOPING		FLAGS, 1	; Looping (Makes env loop whilst GATE high)

; Input definitions
#define TRIG_CHANGED	CHANGES, 0	; RC0 = TRIGGER input
#define TRIGGER		STATES, 0
#define GATE_CHANGED	CHANGES, 0	; RC0 = GATE input
#define GATE		STATES, 0
#define TRIG1_CHANGED	CHANGES, 1	; RC1 = TRIGGER 1 input
#define TRIGGER1	STATES, 1
#define GATE1_CHANGED	CHANGES, 1	; RC1 = GATE 1 input
#define GATE1		STATES, 1
; Note I use the debounced variables, not the input directly
;Z209 defines
;If you're doing a read-modify-write (for example a BSF), you generally want to use the LATCH.
#define GATE_LED0 LATB,0	; 
#define GATE_LED1 LATB,4
#define LEDLAST	  LATC,7  ; last LED on pin 7 of port C
 

;----------------------------------------------------------------------
; Begin Executable Code Segment
;----------------------------------------------------------------------
 org     0x000					; Processor reset vector
	nop							; For ICD use
	goto    Main				; Go to the main program

;------------------------------------------------------------------------------
; Timer 2 Interrupt Service Routine
; This is the sample rate timebase of 31.25KHz, and all necessary calculation
; for the next sample is carried out here.
;------------------------------------------------------------------------------
 org     0x004					; Interrupt vector location

InterruptEnter:
; Sample rate timebase at 31.25KHz
	movlb	D'14'				; Bank 14
	btfss	PIR4, TMR2IF			; Check if TMR2 interrupt
	goto	FinishedEG1 ;InterruptExit
	bcf	PIR4, TMR2IF			; Clear TMR2 interrupt flag

	movlb	D'0'				; Bank 0 ;D'2' ; Bank 2 ;
;	;Test ONLY Z209 code  (16 bit counter to toggle Sustain LED of ADSR 0)	
;	incfsz	TEST_COUNTER_LO, f
;	goto	EndTest
;	incfsz	TEST_COUNTER_HI, f
;	goto	EndTest	
;	;bcf	GATE_LED0
;	movlw	BIT2
;	xorwf	LATB,f		; XOR toggles the and bit set in prev value

;EndTest:
	; end test

CheckOverrun:
	; Check for overrun (this is tested)
	; an overrun is indicated by the #7 LED (of 8,i.e. sustain for second EG) being on.
	btfsc	OVERRUN_FLAG,0	; if last LED is set (indicating an overrun)
	bsf	LATC,6		; turn on next to last LED (permanently)
	; if we start w/ LEDLAST "off" and toggle twice (here and at the end of the Int Rtn)
	; LED will be off most of the time
	; if we "overrun" the interrupt routine, the light will stay on (until we overrun again)
	movlw	BIT0
	xorwf	OVERRUN_FLAG,f		; XOR toggles the bit 
;default - DAC0
	movlw	DAC0		;start with DAC0 ;DAC1;
	bcf	DAC_NUMBER,7    ; clear bit 7 of DAC_NUMBER 
IntLoop:
	btfss	WREG,7		; check DAC0 or DAC1
	goto	ILContinue	; if bit 7 was set, this goto gets skipped
	; set up for DAC1
	movlb	D'2'		; Bank 2 - EG1 (128 byte banks)
	bsf	DAC_NUMBER,7     ; set bit 7 of DAC_NUMBER 
ILContinue:	;process EG0 or EG1
    
	; If we're in LFO mode, we can ignore the GATE and TRIGGER inputs
	btfsc	LFO_MODE
	goto	GenerateEnvelope

;---------------------------------------------------------
;	Test and debounce the digital inputs
;---------------------------------------------------------
; Do Scott Dattalo's vertical counter debounce (www.dattalo.com)
; This could debounce eight inputs, but I'm using only two:
; RC0 Trigger/Gate
; RC1 Trigger/Gate
	
; Z209 consolidate Gate & Trigger & use RC0 for channel 0, RC1 for channel 1
	
	; First, increment the debounce counters
	movfw	DEBOUNCE_LO	
	xorwf	DEBOUNCE_HI, f		; HI+ = HI XOR LO
	comf	DEBOUNCE_LO, f		; LO+ = ~LO
	; See if any changes occured
	movf	BSR,w			; this bank "preservation" while accessing PORTC works, it is expensive
	movwf	TEMP_BSR_INTR
	movlb	D'0' ; Bank 0
	movfw	PORTC				; Get current data from GATE & TRIG inputs
	movwf	TEMP_W_INTR
	movf	TEMP_BSR_INTR,w
	movwf	BSR
	movfw	TEMP_W_INTR
	xorwf	STATES, w			; Find the changes
	; Reset counters where no change occured
	andwf	DEBOUNCE_LO, f
	andwf	DEBOUNCE_HI, f
	; If there is a pending change and the count has rolled over,
	; then the key has been debounced
	xorlw	D'255'				; Invert the changes
	iorwf	DEBOUNCE_HI, w		; If count is 0, both
	iorwf	DEBOUNCE_LO, w		; HI and LO are 0
	; Any bit in W that is clear at this point means that the
	; input has changed and the count rolled over.
	xorlw	D'255'
	; Now a 1 in W represents a 'switch just changed'
	movwf	CHANGES				; Store the changes
	; Update the changes to the keyboard state
	xorwf	STATES, f
	
; Test the GATE and TRIGGER Pins for changes
;--------------------------------------------
; The logic here is straight-forward. If the Trigger goes high, the envelope
; starts an attack. If the Gate goes low, it starts a release.
	
TestTrigger:
	btfsc	BSR,1		    ; see if we are in bank 2 (0x02 = b'00000010')
	goto	TestTrigger1	    ; if so, service trigger 1
	; Has TRIGGER changed?
	btfss	TRIG_CHANGED
	goto	TestGate

	; TRIGGER has changed, but has it gone high?
; Z209 - we need to reverse this cuz my hardware inverts the gate input
;	btfss	TRIGGER
	btfsc	TRIGGER
	goto	TestGate			; No, so skip
	movf	BSR,w			; this bank "preservation" works
	movlb	D'0' ; Bank 0
	bsf	GATE_LED0
	movwf	BSR
	goto	StartEnvelope
	
TestTrigger1:
	btfss	TRIG1_CHANGED
	goto	TestGate

	; TRIGGER has changed, but has it gone high?
; Z209 - we need to reverse this cuz my hardware inverts the gate input
;	btfss	TRIGGER
	btfsc	TRIGGER1
	goto	TestGate		; No, so skip
	movf	BSR,w			; this bank "preservation" works
	movlb	D'0' ; Bank 0
	bsf	GATE_LED1
	movwf	BSR
	
StartEnvelope:
; If TRIGGER has gone high, change to ATTACK stage
	; Zero the accumulator
	clrf	PHASE_HI
	clrf	PHASE_MID
	clrf	PHASE_LO
	; What's the current output level?
	movf	OUTPUT_HI, w
	movwf	START_HI
	movf	OUTPUT_LO, w
	movwf	START_LO
	; Move to ATTACK stage
	movlw	D'1'
	movwf	STAGE
	goto	GenerateEnvelope	

TestGate:
	btfsc	BSR,1		    ; see if we are in bank 2 (0x02 = b'00000010')
	goto	TestGate1	    ; if so, service gate 1
	
	; Has GATE changed?
	btfss	GATE_CHANGED
	goto	GenerateEnvelope
	
	; GATE has changed, but has it gone low?
; Z209 - we need to reverse this cuz my hardware inverts the gate input
;	btfsc	GATE
	btfss	GATE
	goto	GenerateEnvelope	; No, so skip
	movf	BSR,w			; this bank "preservation" works
	movlb	D'0' ; Bank 0
	bcf	GATE_LED0
	movwf	BSR
	goto	EndEnvelope
TestGate1:
	; Has GATE changed?
	btfss	GATE1_CHANGED
	goto	GenerateEnvelope
	
	; GATE has changed, but has it gone low?
; Z209 - we need to reverse this cuz my hardware inverts the gate input
;	btfsc	GATE
	btfss	GATE1
	goto	GenerateEnvelope	; No, so skip
	movf	BSR,w			; this bank "preservation" works
	movlb	D'0' ; Bank 0
	bcf	GATE_LED1
	movwf	BSR
	
EndEnvelope:
; If GATE has gone low, change to RELEASE stage
	; Zero the accumulator
	clrf	PHASE_HI
	clrf	PHASE_MID
	clrf	PHASE_LO
	; What's the current output level?
	movf	OUTPUT_HI, w
	movwf	START_HI
	movf	OUTPUT_LO, w
	movwf	START_LO
	; Move to RELEASE stage
	movlw	D'5'
	movwf	STAGE


GenerateEnvelope:
; Do we need to increment the phase accumulator?
; If so, what FSR offset should we use?
	movf	STAGE, w			; Get current stage
	brw
	goto	Wait				; No PHASE_INC required for WAIT
	goto	GetAttackOffset
	goto	GetPunchOffset	
	goto	GetDecayOffset
	goto	Sustain				; No PHASE_INC required for SUSTAIN
	goto	GetReleaseOffset	
;  There are shorter ways to do this, but this way has the advantage that I
; can easily short-circuit the Wait and Sustain stages.
	
GetAttackOffset:
	movlw	#ATTACK_INC_LO
	goto	IncrementPhase

GetPunchOffset:
	movlw	#PUNCH_INC_LO
	goto	IncrementPhase

GetDecayOffset:
	movlw	#DECAY_INC_LO
	goto	IncrementPhase

GetReleaseOffset:
	movlw	#RELEASE_INC_LO
	

; Increment the phase accumulator PHASE (24+20 bit addition)
IncrementPhase:
	movwf	FSR1L				; Store offset
	movlw	D'1'				; bank 2  (128*2=256=FSR1H=1)
	movwf	FSR1H				; Set up for Indirect Addressing
	btfss	DAC_NUMBER,7			; if EG1 (bank 2), skip next statement
	clrf	FSR1H				; correct to bank 0 if needed
	; Which set of increments are we using?
	moviw	FSR1++				; Add FREQ_INC to PHASE
	addwf	PHASE_LO, f
	moviw	FSR1++
	addwfc	PHASE_MID, f
	moviw	FSR1++
	addwfc	PHASE_HI, f
	btfss	CARRY				; Has it overflowed?
	goto	SelectStage			; No, so continue directly

; Accumulator has overflowed, so move to the next stage
NextStage:
	; First zero the accumulator..
	clrf	PHASE_HI
	clrf	PHASE_MID
	clrf	PHASE_LO
	; ..then increment the STAGE
	incf	STAGE, f

TestPunch:
; Do we use the Punch stage?
;	Z209 - hard code Punch usage
;	comment out the next line to hardcode punch (i.e. goto TestLooping)
;	or the next TWO lines so skip punch
;	btfss	USE_ADSR		; Standard ADSR, so skip Punch
;	goto	TestLooping
SkipPunch:
	; Are we on the Punch stage?
	movf	STAGE, w		; We're about to examine what STAGE we're on
	xorlw	D'2'
	btfss	ZERO			; Is STAGE==2 yet? (PUNCH)
	goto	TestLooping
	incf	STAGE, f		; Move directly to Decay
	goto	SelectStage
	
TestLooping:	
; Are we looping? (Could be either Env Looping or LFO mode)
	movf	STAGE, w		; We're about to examine what STAGE we're on
	btfss	LOOPING
	goto	NormalEnvelope

LoopingEnvelopeOrLFOMode:
; If we're looping, two things are different:
; 1. If STAGE==4, SUSTAIN, we jump straight to STAGE=5, RELEASE 
; 2. If STAGE==6, then we jump back to STAGE=1, ATTACK
	xorlw	D'4'
	btfss	ZERO			; Is STAGE==4 yet? (SUSTAIN)
	goto	TestLoopingEnd
SkipSustain:				; Yes, so move directly to RELEASE
	incf	STAGE, f
	movf	OUTPUT_HI, w	; What's the current output level?
	movwf	START_HI
	movf	OUTPUT_LO, w
	movwf	START_LO
	goto	SelectStage
TestLoopingEnd:
	xorlw	D'2'			; Equivalent to "XORLW 4" then "XORLW 6"
	btfss	ZERO			; Is STAGE==6 yet? (Envelope finished release)
	goto	SelectStage		; STAGE !=6, so skip the rest
	; Envelope has finished release, and we're either in LFO mode,
	; or Gated Looping
	; We need to determine which, and either go back to the Attack, or finish.
	btfsc	GATE			; If the Gate is high, it doesn't matter which..
	goto	LoopToAttack	; ..since we go back to the Attack in either case
	; GATE is Low, so which should it be?
	btfsc	LFO_MODE		; Are we in LFO mode?
	goto	LoopToAttack	; If it's LFO Mode we go back to Attack
	; Gated Looping mode, Release has finished
	clrf	STAGE			; Reset STAGE to zero, WAIT
	goto	SelectStage

LoopToAttack:				; Yes, so reset it to ATTACK
	movlw	D'1'
	movwf	STAGE
	movf	OUTPUT_HI, w	; What's the current output level?
	movwf	START_HI
	movf	OUTPUT_LO, w
	movwf	START_LO
	goto	SelectStage

NormalEnvelope:
	xorlw	D'6'
	btfsc	ZERO			; Is STAGE==6 yet?
	clrf	STAGE			; Yes, so reset it to zero, WAIT


; We need to produce different output values depending on which stage we're at
SelectStage:
	movf	STAGE, w			; Get current stage
	brw
SelectStageBranch:
	goto	Wait				; (Only gets called from here after 'NextStage')
	goto	Attack
	goto	Punch	
	goto	Decay
	goto	Sustain				; (Only gets called from here after 'NextStage')
	goto	Release

Wait:
	; Do nothing. GATE is low, and release stage has finished
	clrf	OUTPUT_HI			; Ensure we output zero when waiting
	clrf	OUTPUT_LO
	goto	DACOutput

Attack:
	; Attack needs scaling by 1-START level,
	; then needs START level adding to it
	comf	START_HI, w
	movwf	MULT_IN_HI
	comf	START_LO, w
	movwf	MULT_IN_LO
	; Set up CURVE_OUT with the linear value (in case)
	movf	PHASE_HI, w
	movwf	CURVE_OUT_HI
	movf	PHASE_MID, w
	movwf	CURVE_OUT_LO
	; Do we use the linear value directly, or do an expo lookup?
	btfss	USE_EXPO
	goto	AttackScaling

ExponentialAttack:
	; Set up the exponential lookup index
	clrf	FSR1H
	lslf	PHASE_HI, w		; Shift it up for 16-bit table
	movwf	FSR1L
	rlf	FSR1H, f
	; Add the table base address
	movlw	LOW AttackCurve		; Get the table base address
	addwf	FSR1L, f			; Add it to the index
	movlw	HIGH AttackCurve
	addwfc	FSR1H, f
	; Get the required value for an exponential Attack curve
	call	LookupAndInterp		; Returns values in CURVE_OUT

AttackScaling:
	call	Multiply10x10		; Do the scaling
	; Add START level
	movf	START_LO, w
	addwf	MULT_OUT_LO, w
	movwf	OUTPUT_LO
	movf	START_HI, w
	addwfc	MULT_OUT_HI, w
	movwf	OUTPUT_HI
	goto	DACOutput

	
Punch:
	; This is a short fixed Hold stage
	movlw	D'255'
	movwf	OUTPUT_HI			; Ensure we output high
	movwf	OUTPUT_LO
	goto	DACOutput


Decay:
	; Decay needs scaling by 1-SUSTAIN and then inverting
	comf	SUSTAIN_CV, w
	movwf	MULT_IN_HI
	movwf	MULT_IN_LO
	; Set up CURVE_OUT with the linear value (in case)
	movf	PHASE_HI, w
	movwf	CURVE_OUT_HI
	movf	PHASE_MID, w
	movwf	CURVE_OUT_LO
	; Do we use the linear value directly, or do an expo lookup?
	btfss	USE_EXPO
	goto	DecayScaling

ExponentialDecay:
	; Set up the exponential lookup index
	clrf	FSR1H
	lslf	PHASE_HI, w			; Shift it up for 16-bit table
	movwf	FSR1L
	rlf	FSR1H, f
	; Add the table base address
	movlw	LOW DecayCurve		; Get the table base address
	addwf	FSR1L, f			; Add it to the index
	movlw	HIGH DecayCurve
	addwfc	FSR1H, f
	; Get the required value for an exponential Decay curve
	call	LookupAndInterp		; Returns values in CURVE_OUT

DecayScaling:
	call	Multiply10x10		; Do the scaling
	; Invert the result
	comf	MULT_OUT_HI, w
	movwf	OUTPUT_HI
	comf	MULT_OUT_LO, w
	movwf	OUTPUT_LO
	goto	DACOutput


Sustain:
	; Do nothing. Gate is high, and decay stage has finished
	movf	SUSTAIN_CV, w		; Ensure that we output the sustain level
	movwf	OUTPUT_HI
	movwf	OUTPUT_LO
	goto	DACOutput


Release:
	; Release needs scaling by START level, then
	; 1-START level adding, then inverting
	movf	START_HI, w
	movwf	MULT_IN_HI
	movf	START_LO, w
	movwf	MULT_IN_LO
	; Set up CURVE_OUT with the linear value (in case)
	movf	PHASE_HI, w
	movwf	CURVE_OUT_HI
	movf	PHASE_MID, w
	movwf	CURVE_OUT_LO
	; Do we use the linear value directly, or do an expo lookup?
	btfss	USE_EXPO
	goto	ReleaseScaling

ExponentialRelease:
	; Set up the exponential lookup index
	clrf	FSR1H
	lslf	PHASE_HI, w			; Shift it up for 16-bit table
	movwf	FSR1L
	rlf	FSR1H, f
	; Add the table base address
	movlw	LOW DecayCurve		; Get the table base address
	addwf	FSR1L, f			; Add it to the index
	movlw	HIGH DecayCurve
	addwfc	FSR1H, f
	; Get the required value for an exponential Decay curve
	call	LookupAndInterp

ReleaseScaling:
	call	Multiply10x10		; Do the scaling
	; Add 1-START level
	comf	START_LO, w
	addwf	MULT_OUT_LO, w
	movwf	OUTPUT_LO
	comf	START_HI, w
	addwfc	MULT_OUT_HI, w
	movwf	OUTPUT_HI
	
	; Invert the result
	comf	OUTPUT_HI,f
	comf	OUTPUT_LO,f

; Set DAC Output
;---------------------------------------
DACOutput:
;	output to MCP4922, not the internal DAC	

	; take 16 bits down to 12 bits
	movf	OUTPUT_HI,w
	movwf	WORK_HI
	movf	OUTPUT_LO,w
	movwf	WORK_LO
	;clrc	don't need it	    ; clear carry flag = 0 
	lsrf	WORK_HI, f  ; move lsb into carry
	rrf	WORK_LO, f  ; move cary into msb and lsb into carry	
	lsrf	WORK_HI, f  ; move lsb into carry
	rrf	WORK_LO, f  ; move cary into msb and lsb int
	lsrf	WORK_HI, f  ; move lsb into carry
	rrf	WORK_LO, f  ; move cary into msb and lsb int
	lsrf	WORK_HI, f  ; move lsb into carry
	rrf	WORK_LO, f  ; move cary into msb and lsb int

;	movlw DAC0	; TODO: change this hardcoded DAC0 to a variable
;        ; pass in the DAC # (in bit 7) via 
;	iorlw 0x30	    ;bit 6=0 (n/a); bit 5=1(GAin x1); bit 4=1 (/SHDN)
;        movwf DAC_NUMBER   
	
	; output the WORK_HI and WORK_LO to the DAC# (0 or 1) specified in W
	movlb D'0'		; PORTB
	bcf   NOT_CS	; Take ~CS Low
	nop		; settling time
	
	movlb D'3'
;    // Clear the Write Collision flag, to allow writing
	bcf SSP2CON1,WCOL   ;    SSP2CON1bits.WCOL = 0;
	movf  SSP2BUF,w  ; Do a dummy read to clear flags
	
	; first send high byte plus commands/configuration
	movf WORK_HI,w
	andlw 0x0F	; we will only want least significant4 bits
	;for DAC0 or DAC1 - dac # (bit 7) 
	;                 bit 15 A/B: DACA or DACB Selection bit
	iorwf DAC_NUMBER,0 ; clr or set bit based on DAC.  0=save into W 
	; this works, but let's do all of this at the beginning
;	;               ; 0 = unbuffered - bit 14  VREF Input Buffer Control bit
;	iorlw BIT5	; set gain of 1 - bit 13 Output Gain Selection bit
;	iorlw BIT4	; 0x10 - bit 12 SHDN: Output Shutdown Control bit
	
	; now W has the commands plus data bits 12-9
	movwf SSP2BUF	; load the buffer
WriteByteHiWait:
	btfss	SSP2STAT, BF		; Wait while it sends
	goto	WriteByteHiWait	

	movf  SSP2BUF,w  ; Do a dummy read to clear flags
	; second send the low byte
	movf WORK_LO,w
	movwf SSP2BUF	; load the buffer
WriteByteLoWait:
	btfss	SSP2STAT, BF		; Wait while it sends
	goto	WriteByteLoWait	
	
	; end of write
	movlb D'0'		; PORTB
	bsf   NOT_CS	; Take ~CS high

	;Note that bank has been reset at this point
;----------------------------------------
InterruptExit:
;	we don't care what bank we're in at this point
;	we will either loop and set the bank or exit and restore it from the shadow registers
	btfsc	DAC_NUMBER,7		; if bit 7 is set, we finished DAC1
	goto	FinishedEG1
;	now process DAC1
	movlw	DAC1
	goto	IntLoop
FinishedEG1:
;   force an overrun
;	movlb	D'0'				; Bank 0
;	call Delay25us
	; second toggle for the CheckOverrun
	movlw	BIT0
	xorwf	OVERRUN_FLAG,f		; XOR toggles the bit 
;	should not need this
;	movlb	D'0'				; Bank 0
	retfie

;------------------------------------------------------
;	10 bit x 10 bit Multiply Subroutine
; This is used by the Attack, Decay and Release stages to
; scale their output.
; The value in CURVE_OUT is multipled by MULT_IN.
; Both are 10-bit, left-aligned.
; 16 bit Output is in MULT_OUT_HI/LO
;------------------------------------------------------
Multiply10x10:
	; Clear the output
	clrf	MULT_OUT_HI
	clrf	MULT_OUT_LO

MultBit0:
	clrc						; Only important if we skip
	btfss	MULT_IN_LO, 6		; Do the test
	goto	MultBit1			; Skip if bit not set

	movf	CURVE_OUT_LO, w		; Add to output if bit set
	addwf	MULT_OUT_LO, f
	movf	CURVE_OUT_HI, w
	addwfc	MULT_OUT_HI, f

MultBit1:
	rrf		MULT_OUT_HI, f		; Shift down
	rrf		MULT_OUT_LO, f

	clrc						; Only important if we skip
	btfss	MULT_IN_LO, 7		; Do test
	goto	MultBit2			; Skip if bit not set

	movf	CURVE_OUT_LO, w		; Add to output if bit set
	addwf	MULT_OUT_LO, f
	movf	CURVE_OUT_HI, w
	addwfc	MULT_OUT_HI, f

MultBit2:
	rrf		MULT_OUT_HI, f		; etc..
	rrf		MULT_OUT_LO, f

	clrc
	btfss	MULT_IN_HI, 0
	goto	MultBit3

	movf	CURVE_OUT_LO, w
	addwf	MULT_OUT_LO, f
	movf	CURVE_OUT_HI, w
	addwfc	MULT_OUT_HI, f

MultBit3:
	rrf		MULT_OUT_HI, f
	rrf		MULT_OUT_LO, f

	clrc
	btfss	MULT_IN_HI, 1
	goto	MultBit4

	movf	CURVE_OUT_LO, w
	addwf	MULT_OUT_LO, f
	movf	CURVE_OUT_HI, w
	addwfc	MULT_OUT_HI, f

MultBit4:
	rrf		MULT_OUT_HI, f
	rrf		MULT_OUT_LO, f

	clrc
	btfss	MULT_IN_HI, 2
	goto	MultBit5

	movf	CURVE_OUT_LO, w
	addwf	MULT_OUT_LO, f
	movf	CURVE_OUT_HI, w
	addwfc	MULT_OUT_HI, f

MultBit5:
	rrf		MULT_OUT_HI, f
	rrf		MULT_OUT_LO, f

	clrc
	btfss	MULT_IN_HI, 3
	goto	MultBit6

	movf	CURVE_OUT_LO, w
	addwf	MULT_OUT_LO, f
	movf	CURVE_OUT_HI, w
	addwfc	MULT_OUT_HI, f

MultBit6:
	rrf		MULT_OUT_HI, f
	rrf		MULT_OUT_LO, f

	clrc
	btfss	MULT_IN_HI, 4
	goto	MultBit7

	movf	CURVE_OUT_LO, w
	addwf	MULT_OUT_LO, f
	movf	CURVE_OUT_HI, w
	addwfc	MULT_OUT_HI, f

MultBit7:
	rrf		MULT_OUT_HI, f
	rrf		MULT_OUT_LO, f

	clrc
	btfss	MULT_IN_HI, 5
	goto	MultBit8

	movf	CURVE_OUT_LO, w
	addwf	MULT_OUT_LO, f
	movf	CURVE_OUT_HI, w
	addwfc	MULT_OUT_HI, f

MultBit8:
	rrf		MULT_OUT_HI, f
	rrf		MULT_OUT_LO, f

	clrc
	btfss	MULT_IN_HI, 6
	goto	MultBit9

	movf	CURVE_OUT_LO, w
	addwf	MULT_OUT_LO, f
	movf	CURVE_OUT_HI, w
	addwfc	MULT_OUT_HI, f

MultBit9:
	rrf		MULT_OUT_HI, f
	rrf		MULT_OUT_LO, f

	clrc
	btfss	MULT_IN_HI, 7
	goto	MultEnd

	movf	CURVE_OUT_LO, w
	addwf	MULT_OUT_LO, f
	movf	CURVE_OUT_HI, w
	addwfc	MULT_OUT_HI, f

MultEnd:
	; Do the last down shift and we're done!
	rrf		MULT_OUT_HI, f
	rrf		MULT_OUT_LO, f
; Note:
; The original 8x8 routine was 66 instructions.
; This is 82, so it's only 16 instructions worse. Actual runtime
; is variable depending on how many bits of MULT_IN are set, but average
; time will be 62-odd instructions. Not half bad!
	return


;------------------------------------------------------
;	Linear Interpolation Subroutine
; This is used by the Attack, Decay, and Release stages.
; The routine expects to be given an FSR pointer from where it can read
; two 16-bit values to interpolate between: INPUT_X and INPUT_Y
; It also assumes that PHASE_MID is to be used as interpolation index.
; The interpolation result goes into CURVE_OUT.
; Since I only want a 10-bit result, we stop the calculation quite early,
; only doing a 3-bit interp (one extra bit for good measure).
;------------------------------------------------------
LookupAndInterp:
	; Get the two samples
	moviw	FSR1++
	movwf	INPUT_X_LO			; Fetch Input X
	movwf	CURVE_OUT_LO		; We start with Input X
	moviw	FSR1++
	movwf	INPUT_X_HI
	movwf	CURVE_OUT_HI		; and here too
	moviw	FSR1++
	movwf	INPUT_Y_LO			; Fetch Input Y
	moviw	FSR1++
	movwf	INPUT_Y_HI

; Do the Interpolation between the two samples

	; Interp bit 0
	movf	INPUT_X_LO, w		; Assume Input X
	btfsc	PHASE_MID, 5
	movf	INPUT_Y_LO, w		; Use Input Y if set
	addwf	CURVE_OUT_LO, f		; Add selected byte to output
	movf	INPUT_X_HI, w		; Do same again for high byte
	btfsc	PHASE_MID, 5
	movf	INPUT_Y_HI, w
	addwfc	CURVE_OUT_HI, f
	rrf		CURVE_OUT_HI, f		; Shift down
	rrf		CURVE_OUT_LO, f
	; Interp bit 1
	movf	INPUT_X_LO, w		; Assume Input X
	btfsc	PHASE_MID, 6
	movf	INPUT_Y_LO, w		; Use Input Y if set
	addwf	CURVE_OUT_LO, f		; Add selected byte to output
	movf	INPUT_X_HI, w		; Do same again for high byte
	btfsc	PHASE_MID, 6
	movf	INPUT_Y_HI, w
	addwfc	CURVE_OUT_HI, f
	rrf		CURVE_OUT_HI, f		; Shift down
	rrf		CURVE_OUT_LO, f
	; Interp bit 2
	movf	INPUT_X_LO, w		; Assume Input X
	btfsc	PHASE_MID, 7
	movf	INPUT_Y_LO, w		; Use Input Y if set
	addwf	CURVE_OUT_LO, f		; Add selected byte to output
	movf	INPUT_X_HI, w		; Do same again for high byte
	btfsc	PHASE_MID, 7
	movf	INPUT_Y_HI, w
	addwfc	CURVE_OUT_HI, f
	rrf		CURVE_OUT_HI, f		; Shift down
	rrf		CURVE_OUT_LO, f
	return


;----------------------------------------
;	Analogue to Digital conversion subroutine
; This is used by the main code loop
;----------------------------------------
DoADConversion:
	movlb	D'1'				; Bank 1
	; set the ADC channel
	;movwf	ADCON0
	movwf	ADPCH				;ADC Positive Channel Selection

	; Short delay whilst the channel settles
	movlw   D'50'
	movwf   TEMP
	decfsz  TEMP, f
	bra	$-1

	; Start the conversion
	bsf	ADCON0, ADGO		;GO_NOT_DONE
	; Wait for it to finish
	btfsc	ADCON0, ADGO		;GO_NOT_DONE	; Is it done?
	bra		$-1

	;  Read the ADC Value and store it
	movf	ADRESH, w
	movwf	ADC_VALUE
	movlb	D'0'				; Bank 0
	return

; TODO: flesh this out
; call this in three places
; 1 - after variable init - copy WK to model 0 & 1
; 2 - beginning of Interrupt - copy model 0 to WK, do routine copy WK to model 0
;	repeat for model 1
; 3 - end of Interrupt - copy WK to model 0 or 1 as appropriate
;
; copy variables To the working storage from the "model"
; in w, pass in 0 for EG-0 or 1 for EG-1
; FSR0 is source
; FSR1 is destination
	
CopyToModel: 
	; note: process EG0 or EG1 based on bit 7 of w
	; set up CopyMemoryBlock  
	    clrf   FSR1H	    ;default: copy to bank 0 (EG0) (note: 128 byte banks!)
	    btfsc   WREG,7	    ;test bit 7 in w if it is clear, skip next instruction
	    goto    CTMContinue
CTMEG1:	; set up EG1
	    movlw   0x01	    ;copy to bank 2 (EG1)
	    movwf   FSR1H
CTMContinue:
	    movlw   0x20	    ;model is at 0x20, regardless of bank
	    movwf   FSR1L	    ;model is destination

	    clrf    FSR0H	    ;copy from bank 0 
	    movlw   #STAGE          ;get the address of STAGE variable 
	    movwf   FSR0L	    ;put it in the source FSR
	    goto    CopyMemoryBlock
	    
CopyFromModel:
	; note: process EG0 or EG1 based on bit 7 of w
	; set up CopyMemoryBlock 
	; default EG0
	    clrf    FSR0H	    ;default: copy from bank 0 (EG0) (note: 128 byte banks!)
	; test incoming WREG bit 7 for EG0/EG1
	    btfsc   WREG,7	    ; test bit 7 in w if it is clear, skip next instruction
	    goto    CFMContinue
CFMEG1:	; set up EG1
	    movlw   0x01	    ;copy from bank 2
	    movwf   FSR0H
CFMContinue:
    	    movlw   0x20	    ;model is at 0x20, regardless of bank
	    movwf   FSR0L	    ;model is source
	    
	    clrf    FSR1H	    ;copy to bank 0 
	    movlw  #STAGE           ;get the address of STAGE variable 
	    movwf   FSR1L	    ;put it in the destination FSR
	    goto    CopyMemoryBlock

CopyMemoryBlock:	    
	    movlw   d'28'	    ; # of bytes to move
	    movwf   LOOP_COUNTER
CopyLoop:
	    moviw   INDF0++
	    movwi   INDF1++
	    decfsz  LOOP_COUNTER
	    bra	    CopyLoop
CopyDone:
	    return
; 25 uS delay
; generated from this site: http://www.piclist.com/techref/piclist/codegen/delay.htm?key=delay+routine&from
;
; Delay = 2.5e-005 seconds
; Clock frequency = 32 MHz

; Actual delay = 2.5e-005 seconds = 200 cycles
; Error = 0 %

	cblock 0x04F
	d1
	endc
Delay25us:
			;199 cycles
	movlw	0x42
	movlw	0x20	; chg the time to make it work ... note 0x21 fails!
	movwf	d1
Delay_0:
	decfsz	d1, f
	goto	Delay_0

			;1 cycle
	nop
	return
; Generated by http://www.piclist.com/cgi-bin/delay.exe (December 7, 2005 version)
; Tue Dec 26 20:16:14 2017 GMT
; S
;----------------------------------------
;	The main program
; This reads the A/D channels and provides
; values for the DDS
;----------------------------------------
Main:
	movlb	D'0'				; Bank 0

	call Init_Osc
	call Init_Ports
	;Test ONLY Z209 code
	bcf	GATE_LED0
	nop	; this seems to be required!!! ozh
	bcf	GATE_LED1
	; end test

	clrf	OVERRUN_FLAG		;init this flag
	
	; Set up the interrupts (INTCON is a SFR available all banks)
	bsf	INTCON, GIE		; Enable interrupts
	bsf	INTCON, PEIE		; Enable peripheral interrupts
;	bsf	INTCON, IOCIE		; Enable interrupt-on-change
	movlb	D'14'			; Bank 14	
	bsf	PIE4, TMR2IE		; Enable the output sample rate interrupt
	
	; Set up Timer2 as sample rate timebase
	; Z209 - this code is reviewed against the PIC16F18855 datasheet, but unproven as of 5/8/18
	movlb	D'5'				; Bank 5		
	movlw	B'00000001'			
	movwf	T2CLKCON			; Fosc/4 = 8MHz clock for timer
;	movlw	B'00110000'			; Prescale /8 = 1MHz, Postscale /1, Tmr Off
	movlw	B'01000000'			; Prescale /16 = 0.5MHz, Postscale /1, Tmr Off
	movwf	T2CON					
	movlw	0x1F				; Set up Timer2 period register (/32)
	; T2PR = 28Dh same as PR2
	movwf	PR2				; Interrupts at 1MHz/32 = 31.25KHz

; TODO: review this setup
	movlb	D'1'				; Bank 1
	; set up the A/D clock
	movlw	B'00000101'			; Fosc/16
	movwf	ADCLK
	; ADCON0 - turn ADC on see 23.6 
;	movlw	B'00000001'			; AN0, ADC on
	movlw	B'10000000'			; ADON,ADCON,n/a,ADCS (clock source 0 = Fosc)
						; ADFRM( 0 = left justified)
	movwf	ADCON0				; ADGO ( set to 1 to start the conversion)
	; ADCON1
	movlw	B'00000001'				; ADDPOL 0 TODO: recheck this)
						; ADIPEN 0 recheck
						; ADGPOL 0 recheck
	movwf	ADCON1				; ADDSEN 1 enable double sample
						
;	movlw	B'01100000'			; Left-justified, Fosc/64, Vss to Vdd range.
;	movwf	ADCON1
	; ADCON2
	movlw	B'01000000' ;ADPSIS 0=send ADFLTR filtered results to ADPREV
			    ;ADCRS 100 - LP filter time is 2 ADCRS, filter gain 1:1
			    ;ADACLR 0  - not started
			    ;ADMD (mode) 000 Basic Mode (for now)
	movwf	ADCON2
	; ADCON3
	movlw	B'00000000'    ;ADCALC TODO: recheck this 000 first derivative of single measurement
			    ;ADSOI 0 ADGO is not cleard by hardware - do it in software
			    ;ADTMD 000 (ADTIF is disabled)
	movwf	ADCON3
	
	;ADREF
	movlw	B'00000000'    ; ADNREF 0 VREF- is AVSS;	ADPREF 00 VREF+ is VDD
	movwf	ADREF
	
	; set channel using ADPCH - pretty straight forward
	; 00000000 = ANA0
	; 00000111 = ANA7

	
; Set up initial values of the variables
;-----------------------------------------
	movlb	D'0'					; Bank 0
	
	; Set up both indirection pointers for Bank0
	clrf	FSR0H
	clrf	FSR1H

	; Set up DAC_NUMBER for use with Dacoutput to MCP4922
	movlw DAC0	    ; init for DAC0, toggle bit 7 in the Copy routines
        ; pass in the DAC # (in bit 7) via 
	iorlw 0x30	    ;bit 6=0 (n/a); bit 5=1(GAin x1); bit 4=1 (/SHDN)
        movwf DAC_NUMBER     

	; Set up initial values of the variables
	clrf	ATTACK_CV			; Default to minimum time of 1mS
	clrf	DECAY_CV
	clrf	SUSTAIN_CV
	clrf	RELEASE_CV
;	clrf	ATTACK1_CV			; Default to minimum time of 1mS
;	clrf	DECAY1_CV
;	clrf	SUSTAIN1_CV
;	clrf	RELEASE1_CV
	clrf	TIME_CV				; Default to no time modulation
	clrf	MODE_CV				; Default to standard ADSR, no looping
	clrf	STAGE
	; Clear the Phase Accumulator
	clrf	PHASE_LO
	clrf	PHASE_MID
	clrf	PHASE_HI
	; Clear the increments too
	clrf	ATTACK_INC_LO
	clrf	ATTACK_INC_MID
	clrf	ATTACK_INC_HI
	clrf	DECAY_INC_LO
	clrf	DECAY_INC_MID
	clrf	DECAY_INC_HI
	clrf	RELEASE_INC_LO
	clrf	RELEASE_INC_MID
	clrf	RELEASE_INC_HI

	; Set up the Punch increment (fixed stage length of about 5msecs)
	movlw	D'160'
	movwf	PUNCH_INC_LO
	movwf	PUNCH_INC_MID
	movlw	D'1'
	movwf	PUNCH_INC_HI
	
	; set up punch & expo as hardcoded values.  See defines USE_ADSR and USE_EXPO
;	movlw	0x28			; punch 1, expo 1 = 0010 1000 = 0x28
	movlw	0x08			; punch 0, expo 1 = 0000 1000 = 0x08
	movwf	FAKE_PUNCH_EXPO		;use this variable instead of PORTA bits 3 (expo) & 5 (punch)
	
	; Clear the output buffers
	clrf	OUTPUT_HI
	clrf	OUTPUT_LO
	; Set up the ADC channel scan (to roll over)
	movlw	0x07
	movwf	ADC_CHANNEL			; Start with ATTACK_CV
	; The first Attack starts at zero
	clrf	START_HI
	clrf	START_LO
	; Set up the GATE & TRIGGER debounce
	clrf	DEBOUNCE_HI
	clrf	DEBOUNCE_LO
	clrf	STATES
	clrf	CHANGES

	bcf	LEDLAST		    ; begin w/the last LED off - see CheckOverrun

; now copy the 20 registers which define the operation of the EG0 to EG1 model

	movlw	DAC1		; same for both at this point
	call	CopyToModel
; Ok, that's all the setup done, let's get going

	; Start outputting signals (enable TMR2, start interrupts )	
	movlb	D'5'				; Bank 5	
	bsf	T2CON, TMR2ON		; Turn timer 2 on	

	movlb	D'0'				; Bank 0
MainLoop:
	; Change to next A/D channel
	incf	ADC_CHANNEL, f
	
; We need to do different things depending on which value we're reading:
SelectADCChannel:
	movf	ADC_CHANNEL, w		; Get current channel
	andlw	0x07			; Only want 3 LSBs
	brw				; Computed branch
	goto	AttackCV
	goto	DecayCV
	goto	SustainCV
	goto	ReleaseCV
	goto	Attack1CV
	goto	Decay1CV
	goto	Sustain1CV
	goto	Release1CV
	; don't process these channels, leave them hardcoded
;	goto	TimeCV
;	goto	ModeCV

ScannedAllChannels:
	; Reset ADC channel 
	movlw	D'7'
	movwf	ADC_CHANNEL
	goto	MainLoop


; Update the Attack CV
AttackCV:
	movlw	D'0'		; ANA0
	call	DoADConversion
	movwf	ATTACK_CV
	; Subtract the TIME_CV (Increasing TIME_CV shortens the Env)
	movfw	TIME_CV
	subwf	ATTACK_CV, w
	btfss	BORROW
	movlw	D'0'				; If value is <0, use minimum
	; Get the new phase increment for the ATTACK stage
	movwf	FSR0L				; Store index
	movlw	HIGH ControlLookupHi; Get table page
	movwf	FSR0H
	movf	INDF0, w			; Get high byte
	movwf	ATTACK_INC_HI		; Store it
	incf	FSR0H, f			; Move to mid table
	movf	INDF0, w			; etc..
	movwf	ATTACK_INC_MID
	incf	FSR0H, f			; Move to lo table
	movf	INDF0, w
	movwf	ATTACK_INC_LO
	goto	MainLoop

Attack1CV:
	;DoADConversion will set bank to 0
	movlw	D'4'		; ANA4
	call	DoADConversion

	movwf	TEMP		;save WREG in the TEMP variable
	movfw	BSR		;preserve BSR
	movwf	TEMP_BSR
	movfw	TEMP		;restore WREG
	movlb	D'2'		; Bank 2
	movwf	ATTACK_CV
	; Subtract the TIME_CV (Increasing TIME_CV shortens the Env)
	movfw	TIME_CV
	subwf	ATTACK_CV, w
	btfss	BORROW
	movlw	D'0'				; If value is <0, use minimum
	; Get the new phase increment for the ATTACK stage
	movwf	FSR0L				; Store index
	movlw	HIGH ControlLookupHi; Get table page
	movwf	FSR0H
	movf	INDF0, w			; Get high byte
	movwf	ATTACK_INC_HI		; Store it
	incf	FSR0H, f			; Move to mid table
	movf	INDF0, w			; etc..
	movwf	ATTACK_INC_MID
	incf	FSR0H, f			; Move to lo table
	movf	INDF0, w
	movwf	ATTACK_INC_LO
	movf	TEMP_BSR,w		; restore BSR
	movwf	BSR
	goto	MainLoop

	
; Update the Decay CV
DecayCV:
	movlw	D'1'		; ANA1
	call	DoADConversion
	movwf	DECAY_CV
	; Subtract the TIME_CV (Increasing TIME_CV shortens the Env)
	movfw	TIME_CV
	subwf	DECAY_CV, w
	btfss	BORROW
	movlw	D'0'				; If value is <0, use minimum
	; Get the new phase increment for the DECAY stage
	movwf	FSR0L				; Store index
	movlw	HIGH ControlLookupHi; Get table page
	movwf	FSR0H
	movf	INDF0, w			; Get high byte
	movwf	DECAY_INC_HI		; Store it
	incf	FSR0H, f			; Move to mid table
	movf	INDF0, w			; etc..
	movwf	DECAY_INC_MID
	incf	FSR0H, f			; Move to lo table
	movf	INDF0, w
	movwf	DECAY_INC_LO
	goto	MainLoop

Decay1CV:	
	movlw	D'5'		; ANA5
	call	DoADConversion

	movwf	TEMP		;save WREG in the TEMP variable
	movfw	BSR		;preserve BSR
	movwf	TEMP_BSR
	movfw	TEMP		;restore WREG
	movlb	D'2'		; Bank 2
	movwf	DECAY_CV
	; Subtract the TIME_CV (Increasing TIME_CV shortens the Env)
	movfw	TIME_CV
	subwf	DECAY_CV, w
	btfss	BORROW
	movlw	D'0'				; If value is <0, use minimum
	; Get the new phase increment for the DECAY stage
	movwf	FSR0L				; Store index
	movlw	HIGH ControlLookupHi; Get table page
	movwf	FSR0H
	movf	INDF0, w			; Get high byte
	movwf	DECAY_INC_HI		; Store it
	incf	FSR0H, f			; Move to mid table
	movf	INDF0, w			; etc..
	movwf	DECAY_INC_MID
	incf	FSR0H, f			; Move to lo table
	movf	INDF0, w
	movwf	DECAY_INC_LO
	movf	TEMP_BSR,w		; restore BSR
	movwf	BSR
	goto	MainLoop
	
; Update the Sustain CV
SustainCV:
	movlw	D'2'		; ANA2
	call	DoADConversion
	movwf	SUSTAIN_CV			; Simply store this one- easy!
	goto	MainLoop

; Update the Sustain CV
Sustain1CV:
	movlw	D'6'		; ANA6
	call	DoADConversion
	movlb	D'2'		; change to bank 2
	movwf	SUSTAIN_CV	; Simply store this one- easy!
	movlb	D'0'		; change back to bank 0
	goto	MainLoop
	
; Update the Release CV
ReleaseCV:
;	movlw	b'00010101'			; AN5, ADC On
	movlw	D'3'		; ANA3
	call	DoADConversion
	movwf	RELEASE_CV
	; Subtract the TIME_CV (Increasing TIME_CV shortens the Env)
	movfw	TIME_CV
	subwf	RELEASE_CV, w
	btfss	BORROW
	movlw	D'0'				; If value is <0, use minimum
	; Get the new phase increment for the RELEASE stage
	movwf	FSR0L				; Store index
	movlw	HIGH ControlLookupHi; Get table page
	movwf	FSR0H
	movf	INDF0, w			; Get high byte
	movwf	RELEASE_INC_HI		; Store it
	incf	FSR0H, f			; Move to mid table
	movf	INDF0, w			; etc..
	movwf	RELEASE_INC_MID
	incf	FSR0H, f			; Move to lo table
	movf	INDF0, w
	movwf	RELEASE_INC_LO
	goto	MainLoop

; Update the Release CV
Release1CV:
	movlw	D'7'		; ANA7
	call	DoADConversion

	movwf	TEMP		;save WREG in the TEMP variable
	movfw	BSR		;preserve BSR
	movwf	TEMP_BSR
	movfw	TEMP		;restore WREG
	movlb	D'2'		; Bank 2
	movwf	RELEASE_CV
	; Subtract the TIME_CV (Increasing TIME_CV shortens the Env)
	movfw	TIME_CV
	subwf	RELEASE_CV, w
	btfss	BORROW
	movlw	D'0'				; If value is <0, use minimum
	; Get the new phase increment for the RELEASE stage
	movwf	FSR0L				; Store index
	movlw	HIGH ControlLookupHi; Get table page
	movwf	FSR0H
	movf	INDF0, w			; Get high byte
	movwf	RELEASE_INC_HI		; Store it
	incf	FSR0H, f			; Move to mid table
	movf	INDF0, w			; etc..
	movwf	RELEASE_INC_MID
	incf	FSR0H, f			; Move to lo table
	movf	INDF0, w
	movwf	RELEASE_INC_LO
	movf	TEMP_BSR,w		; restore BSR
	movwf	BSR
	goto	MainLoop
	
    ; ***** Miscellaneous Routines*********************************************

; -----------------------------------------------------------------------
; The pins on the PIC are organized into ports.  Each port is about 8 bits wide.  However this
; is only a general rule and your device may vary.

; To setup a particular pin, we need to put values into the corresponding Analog Select
; register, and Tri-state register.  This ensures that our pin will be an output, and that
; it will be a digital output.
Init_Ports:
	
; TODO: validate all ports
	
; convert working C code from DualEG (mcc generated) to ASM
;void PIN_MANAGER_Initialize(void)
	movlb D'0'
	clrf LATA   ;    LATA = 0x00;
	movlw 0x20
	movwf LATB  ;    LATB = 0x20;  
	clrf LATC   ;    LATC = 0x00; 

;	movlb D'0'
	movlw 0xFF
	movwf TRISA ;    TRISA = 0xFF;
	clrf TRISB  ;    TRISB = 0x00;
	movlw 0x1F
	movwf TRISC ;    TRISC = 0x1F;

;   analog/digital (GPIO)
	movlb d'30'
	movlw 0x04
	movwf ANSELC	;    ANSELC = 0x04;  ( why is RC2 ANALOG?)
	movlw 0x00
	movwf ANSELB	;    ANSELB = 0x00;
	movlw 0xFF
	movwf ANSELA	;    ANSELA = 0xFF;
	
;   weak pullup
;	movlb d'30'
	clrf WPUE   ;    WPUE = 0x00;
	movlw 0xE0
	movwf WPUB  ;    WPUB = 0xE0;
	clrf WPUA   ;    WPUA = 0x00;
	clrf WPUC   ;    WPUC = 0x00;

;   open drain
;	movlb d'30'
	clrf ODCONA ;    ODCONA = 0x00;
	clrf ODCONB ;    ODCONB = 0x00;
	clrf ODCONC ;    ODCONC = 0x00;   
	
;   preserve the GIE state - global interrupt enable
;    bool state = (unsigned char)GIE;
	movf  INTCON,w
	andlw b'10000000'   ;isolate bit 7
	movwf GIE_STATE
;    GIE = 0;	shut it off for to do the config
	movf  INTCON,w
	andlw b'01111111'   ;clear bit 7
	movwf INTCON
	
;   PPSLOCK takes a special sequence to unlock
	movlb d'29'
	movlw 0x55
	movwf PPSLOCK ;    PPSLOCK = 0x55;
	movlw 0xAA
	movwf PPSLOCK ;    PPSLOCK = 0xAA;
;   unlock to make a change (note PPSLOCKED is bit 0, the only active bit in PPSLOCK byte
	clrf PPSLOCK  ;    PPSLOCKbits.PPSLOCKED = 0x00; // unlock PPS

;   set up I2C on SSP1	
;	movlb d'29'
	movlw 0x13
	movwf SSP1DATPPS ;    SSP1DATPPSbits.SSP1DATPPS = 0x13;   //RC3->MSSP1:SDA1;
	movlw 0x14
	movwf SSP1CLKPPS ;    SSP1CLKPPSbits.SSP1CLKPPS = 0x14;   //RC4->MSSP1:SCL1;
	
	movlb d'30'
	movlw 0x15
	movwf RC3PPS ;    RC3PPS = 0x15;   //RC3->MSSP1:SDA1;
	movlw 0x14
	movwf RC4PPS ;    RC4PPS = 0x14;   //RC4->MSSP1:SCL1

;   set up SPI on SSP2	
	movlb d'29'
	movlw 0x12
	movwf SSP2DATPPS ;    SSP2DATPPSbits.SSP1DATPPS = 0x12;   //RB7->MSSP2:SPIDAT;
	movlw 0x0E
	movwf SSP2CLKPPS ;    SSP2CLKPPSbits.SSP1CLKPPS = 0x0E;   //RB6->MSSP2:SPICL1;
	movlw 0x0E
	movwf SSP2SSPPS  ;
	
	movlb d'30'
	movlw 0x17
	movwf RB7PPS ;    RB7PPS = 0x17;   //RB7->MSSP2:SPIDAT;
	movlw 0x16
	movwf RB6PPS ;    RB6PPS = 0x16;   //RB6->MSSP2:SPICL1;
	
;   PPSLOCK takes a special sequence to lock
	movlb d'29'
	movlw 0x55
	movwf PPSLOCK ;    PPSLOCK = 0x55;
	movlw 0xAA
	movwf PPSLOCK ;    PPSLOCK = 0xAA;
	
	movlw 0x01
	movwf PPSLOCK ;    PPSLOCKbits.PPSLOCKED = 0x01; // lock PPS
;
;    GIE = state;
	movf  INTCON,w	    ; get the current value
	iorwf GIE_STATE	    ; OR with isolated bit 7
	movwf INTCON	    ; store it
;}  
;   set up SPI on SSP2
	call Init_SPI2	; SPI for DAC
	
	movlb D'0'		; reset to bank 0
	return
	
; convert working C code from DualEG (mcc generated) to ASM
Init_SPI2:
;    // Set the SPI2 module to the options selected in the User Interface
	movlb D'3'
;    // SMP Middle; CKE Idle to Active; = 0x00 MODE 1 when CKP Idle:Low, Active:High (not supported by MCP4922)
;    // SMP Middle; CKE Active to Idle; = 0x40 MODE 0 when CKP Idle:Low, Active:High ( IS supported by MCP4922)
;       0x20 is same as 0x40, but change clock to FOSC4 (8000kHz).  This was apparently too fast!!!	
	movlw 0x40
	movwf SSP2STAT   ;SSP2STAT = 0x00;
;    
;    // SSPEN enabled; CKP Idle:Low, Active:High; SSPM FOSC/4_SSPxADD;
	movlw 0x2A
	movwf SSP2CON1	;SSP2CON1 = 0x2A;
;   
;    // SSPADD 24; 
	movlw 0x02     ;chg to 2 ( 1 did not work)
	movwf SSP2ADD	;SSP2ADD = 0x02;
	return
	
; convert working C code from DualEG (mcc generated) to ASM
;void OSCILLATOR_Initialize(void)
;{
Init_Osc:
	movlb d'17'
    ;// NOSC HFINTOSC; NDIV 1; 
    ;OSCCON1 = 0x60;
	movlw 0x60
	movwf OSCCON1
    ;// CSWHOLD may proceed; SOSCPWR Low power; 
    ;OSCCON3 = 0x00;
    	movlw 0x00		; yes, I know I can 'clrf' this, but it may change later
	movwf OSCCON3
    ;// MFOEN disabled; LFOEN disabled; ADOEN disabled; SOSCEN disabled; EXTOEN disabled; HFOEN disabled; 
    ;OSCEN = 0x00;
     	movlw 0x00
	movwf OSCEN
    ;// HFFRQ 32_MHz; 
    ;OSCFRQ = 0x06;
     	movlw 0x06
	movwf OSCFRQ
    ;// HFTUN 0; 
    ;OSCTUNE = 0x00;
     	movlw 0x00
	movwf OSCTUNE
    return
;}

	
;-------------------------------------------------------
;	Control Lookup Tables (3 tables of 256 x 8-bit)
; Converts from 0-255 CV input to 20 bit PHASE_INC value
; The tables should be aligned to a 256-byte page boundary
;-------------------------------------------------------

; org     0x300					; Need to start at 0x100 boundary
 org     0x400					; Need to start at 0x100 boundary
ControlLookupHi:
	dt	D'11', D'10', D'10', D'9', D'8', D'8', D'7', D'7'
	dt	D'7', D'6', D'6', D'5', D'5', D'5', D'5', D'4'
	dt	D'4', D'4', D'4', D'4', D'3', D'3', D'3', D'3'
	dt	D'3', D'3', D'3', D'2', D'2', D'2', D'2', D'2'
	dt	D'2', D'2', D'2', D'2', D'2', D'1', D'1', D'1'
	dt	D'1', D'1', D'1', D'1', D'1', D'1', D'1', D'1'
	dt	D'1', D'1', D'1', D'1', D'1', D'1', D'1', D'1'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'

	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'

	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'

	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'


ControlLookupMid:
	dt	D'179', D'225', D'38', D'126', D'231', D'94', D'226', D'112'
	dt	D'8', D'168', D'80', D'254', D'178', D'107', D'41', D'235'
	dt	D'178', D'123', D'72', D'24', D'235', D'192', D'152', D'114'
	dt	D'77', D'43', D'10', D'235', D'206', D'178', D'151', D'125'
	dt	D'101', D'77', D'55', D'34', D'13', D'250', D'231', D'213'
	dt	D'196', D'179', D'163', D'148', D'133', D'119', D'106', D'93'
	dt	D'80', D'68', D'57', D'45', D'35', D'24', D'14', D'5'
	dt	D'252', D'243', D'234', D'226', D'218', D'210', D'203', D'196'

	dt	D'189', D'182', D'176', D'170', D'164', D'158', D'152', D'147'
	dt	D'142', D'137', D'132', D'128', D'123', D'119', D'115', D'111'
	dt	D'107', D'103', D'99', D'96', D'92', D'89', D'86', D'83'
	dt	D'80', D'77', D'75', D'72', D'69', D'67', D'65', D'62'
	dt	D'60', D'58', D'56', D'54', D'52', D'50', D'48', D'47'
	dt	D'45', D'43', D'42', D'40', D'39', D'38', D'36', D'35'
	dt	D'34', D'32', D'31', D'30', D'29', D'28', D'27', D'26'
	dt	D'25', D'24', D'23', D'22', D'22', D'21', D'20', D'19'

	dt	D'19', D'18', D'17', D'17', D'16', D'16', D'15', D'14'
	dt	D'14', D'13', D'13', D'12', D'12', D'11', D'11', D'11'
	dt	D'10', D'10', D'10', D'9', D'9', D'8', D'8', D'8'
	dt	D'8', D'7', D'7', D'7', D'6', D'6', D'6', D'6'
	dt	D'6', D'5', D'5', D'5', D'5', D'5', D'4', D'4'
	dt	D'4', D'4', D'4', D'4', D'3', D'3', D'3', D'3'
	dt	D'3', D'3', D'3', D'3', D'2', D'2', D'2', D'2'
	dt	D'2', D'2', D'2', D'2', D'2', D'2', D'2', D'1'

	dt	D'1', D'1', D'1', D'1', D'1', D'1', D'1', D'1'
	dt	D'1', D'1', D'1', D'1', D'1', D'1', D'1', D'1'
	dt	D'1', D'1', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'
	dt	D'0', D'0', D'0', D'0', D'0', D'0', D'0', D'0'


ControlLookupLo:
	dt	D'238', D'158', D'109', D'192', D'180', D'241', D'137', D'231'
	dt	D'181', D'214', D'87', D'106', D'93', D'152', D'149', D'224'
	dt	D'21', D'217', D'222', D'222', D'155', D'222', D'117', D'50'
	dt	D'239', D'134', D'215', D'195', D'48', D'5', D'43', D'141'
	dt	D'24', D'187', D'102', D'9', D'151', D'3', D'65', D'70'
	dt	D'8', D'125', D'157', D'94', D'186', D'169', D'35', D'36'
	dt	D'163', D'157', D'11', D'232', D'48', D'222', D'238', D'91'
	dt	D'34', D'63', D'175', D'110', D'122', D'207', D'106', D'72'

	dt	D'104', D'198', D'97', D'53', D'66', D'132', D'249', D'161'
	dt	D'120', D'126', D'177', D'14', D'149', D'68', D'25', D'19'
	dt	D'50', D'115', D'213', D'87', D'249', D'184', D'149', D'141'
	dt	D'160', D'205', D'20', D'114', D'232', D'117', D'23', D'207'
	dt	D'154', D'122', D'108', D'112', D'135', D'174', D'230', D'45'
	dt	D'132', D'234', D'94', D'224', D'111', D'11', D'179', D'104'
	dt	D'40', D'243', D'201', D'170', D'148', D'137', D'134', D'141'
	dt	D'157', D'180', D'212', D'252', D'44', D'99', D'161', D'229'

	dt	D'49', D'130', D'218', D'56', D'155', D'4', D'115', D'230'
	dt	D'95', D'220', D'94', D'228', D'110', D'253', D'144', D'39'
	dt	D'193', D'95', D'0', D'165', D'77', D'248', D'166', D'87'
	dt	D'11', D'194', D'123', D'55', D'245', D'181', D'120', D'61'
	dt	D'4', D'205', D'152', D'101', D'51', D'4', D'214', D'170'
	dt	D'127', D'86', D'46', D'8', D'227', D'191', D'157', D'124'
	dt	D'92', D'61', D'32', D'3', D'231', D'205', D'179', D'154'
	dt	D'131', D'108', D'85', D'64', D'43', D'23', D'4', D'242'

	dt	D'224', D'207', D'190', D'174', D'159', D'144', D'130', D'116'
	dt	D'102', D'90', D'77', D'65', D'54', D'43', D'32', D'22'
	dt	D'12', D'2', D'249', D'240', D'231', D'223', D'215', D'207'
	dt	D'200', D'193', D'186', D'179', D'173', D'167', D'161', D'155'
	dt	D'149', D'144', D'139', D'134', D'129', D'124', D'120', D'116'
	dt	D'111', D'107', D'104', D'100', D'96', D'93', D'90', D'86'
	dt	D'83', D'80', D'77', D'75', D'72', D'69', D'67', D'64'
	dt	D'62', D'60', D'58', D'56', D'54', D'52', D'50', D'48'


;------------------------------------------------------------------------------
;	Curve Lookup Tables (2 tables of 257 x 16-bit, Low byte, high byte)
; The Attack and Decay/Release curves are stored separately.
; This is because the Attack curve heads towards 6.5V but stops at 5V,
; whereas the Decay/Release curves actually arrive at their destination value.
; Note that because the linear count goes UP in all cases and
; hence needs inverting for Decay/Release, the Decay/Release curve is the same
; way up as the Attack. This way it gets the same inversion as the linear count,
; which makes life marginally simpler.
;------------------------------------------------------------------------------
; org     0x600					; Need to start at page boundary
 org     0x700					; Need to start at page boundary
AttackCurve:
	dt	D'0', D'0', D'231', D'1', D'202', D'3', D'171', D'5'
	dt	D'138', D'7', D'101', D'9', D'62', D'11', D'20', D'13'
	dt	D'232', D'14', D'185', D'16', D'135', D'18', D'82', D'20'
	dt	D'27', D'22', D'225', D'23', D'165', D'25', D'102', D'27'
	dt	D'37', D'29', D'225', D'30', D'154', D'32', D'81', D'34'
	dt	D'6', D'36', D'183', D'37', D'103', D'39', D'20', D'41'
	dt	D'190', D'42', D'102', D'44', D'12', D'46', D'175', D'47'
	dt	D'80', D'49', D'239', D'50', D'139', D'52', D'37', D'54'

	dt	D'188', D'55', D'81', D'57', D'228', D'58', D'116', D'60'
	dt	D'3', D'62', D'143', D'63', D'24', D'65', D'160', D'66'
	dt	D'37', D'68', D'168', D'69', D'41', D'71', D'167', D'72'
	dt	D'35', D'74', D'158', D'75', D'22', D'77', D'140', D'78'
	dt	D'255', D'79', D'113', D'81', D'224', D'82', D'78', D'84'
	dt	D'185', D'85', D'34', D'87', D'138', D'88', D'239', D'89'
	dt	D'82', D'91', D'179', D'92', D'18', D'94', D'111', D'95'
	dt	D'202', D'96', D'35', D'98', D'122', D'99', D'207', D'100'

	dt	D'35', D'102', D'116', D'103', D'195', D'104', D'17', D'106'
	dt	D'92', D'107', D'166', D'108', D'238', D'109', D'51', D'111'
	dt	D'119', D'112', D'186', D'113', D'250', D'114', D'56', D'116'
	dt	D'117', D'117', D'176', D'118', D'233', D'119', D'32', D'121'
	dt	D'86', D'122', D'137', D'123', D'187', D'124', D'236', D'125'
	dt	D'26', D'127', D'71', D'128', D'114', D'129', D'155', D'130'
	dt	D'195', D'131', D'233', D'132', D'13', D'134', D'48', D'135'
	dt	D'81', D'136', D'112', D'137', D'141', D'138', D'169', D'139'

	dt	D'196', D'140', D'221', D'141', D'244', D'142', D'9', D'144'
	dt	D'29', D'145', D'48', D'146', D'65', D'147', D'80', D'148'
	dt	D'94', D'149', D'106', D'150', D'117', D'151', D'126', D'152'
	dt	D'133', D'153', D'139', D'154', D'144', D'155', D'147', D'156'
	dt	D'149', D'157', D'149', D'158', D'148', D'159', D'145', D'160'
	dt	D'141', D'161', D'135', D'162', D'128', D'163', D'120', D'164'
	dt	D'110', D'165', D'99', D'166', D'86', D'167', D'72', D'168'
	dt	D'56', D'169', D'40', D'170', D'21', D'171', D'2', D'172'

	dt	D'237', D'172', D'215', D'173', D'191', D'174', D'166', D'175'
	dt	D'140', D'176', D'112', D'177', D'84', D'178', D'53', D'179'
	dt	D'22', D'180', D'245', D'180', D'211', D'181', D'176', D'182'
	dt	D'139', D'183', D'102', D'184', D'63', D'185', D'22', D'186'
	dt	D'237', D'186', D'194', D'187', D'150', D'188', D'105', D'189'
	dt	D'59', D'190', D'11', D'191', D'218', D'191', D'169', D'192'
	dt	D'117', D'193', D'65', D'194', D'12', D'195', D'213', D'195'
	dt	D'157', D'196', D'101', D'197', D'42', D'198', D'239', D'198'

	dt	D'179', D'199', D'118', D'200', D'55', D'201', D'248', D'201'
	dt	D'183', D'202', D'117', D'203', D'50', D'204', D'238', D'204'
	dt	D'169', D'205', D'99', D'206', D'28', D'207', D'212', D'207'
	dt	D'138', D'208', D'64', D'209', D'245', D'209', D'168', D'210'
	dt	D'91', D'211', D'12', D'212', D'189', D'212', D'108', D'213'
	dt	D'27', D'214', D'201', D'214', D'117', D'215', D'33', D'216'
	dt	D'203', D'216', D'117', D'217', D'30', D'218', D'197', D'218'
	dt	D'108', D'219', D'18', D'220', D'183', D'220', D'90', D'221'

	dt	D'253', D'221', D'159', D'222', D'64', D'223', D'225', D'223'
	dt	D'128', D'224', D'30', D'225', D'188', D'225', D'88', D'226'
	dt	D'244', D'226', D'143', D'227', D'40', D'228', D'193', D'228'
	dt	D'90', D'229', D'241', D'229', D'135', D'230', D'29', D'231'
	dt	D'177', D'231', D'69', D'232', D'216', D'232', D'106', D'233'
	dt	D'252', D'233', D'140', D'234', D'28', D'235', D'171', D'235'
	dt	D'57', D'236', D'198', D'236', D'82', D'237', D'222', D'237'
	dt	D'105', D'238', D'243', D'238', D'124', D'239', D'4', D'240'

	dt	D'140', D'240', D'19', D'241', D'153', D'241', D'30', D'242'
	dt	D'163', D'242', D'39', D'243', D'170', D'243', D'44', D'244'
	dt	D'174', D'244', D'47', D'245', D'175', D'245', D'46', D'246'
	dt	D'173', D'246', D'43', D'247', D'168', D'247', D'36', D'248'
	dt	D'160', D'248', D'27', D'249', D'149', D'249', D'15', D'250'
	dt	D'136', D'250', D'0', D'251', D'120', D'251', D'239', D'251'
	dt	D'101', D'252', D'219', D'252', D'80', D'253', D'196', D'253'
	dt	D'55', D'254', D'170', D'254', D'28', D'255', D'142', D'255'
 org     0x900					; Need to start at page boundary
	; One extra to make interp simple
	dt	D'255', D'255'

DecayCurve:
	dt	D'0', D'0', D'45', D'3', D'81', D'6', D'108', D'9'
	dt	D'125', D'12', D'132', D'15', D'131', D'18', D'120', D'21'
	dt	D'101', D'24', D'73', D'27', D'36', D'30', D'246', D'32'
	dt	D'192', D'35', D'129', D'38', D'58', D'41', D'235', D'43'
	dt	D'147', D'46', D'52', D'49', D'204', D'51', D'93', D'54'
	dt	D'230', D'56', D'103', D'59', D'225', D'61', D'83', D'64'
	dt	D'190', D'66', D'33', D'69', D'126', D'71', D'211', D'73'
	dt	D'33', D'76', D'104', D'78', D'168', D'80', D'226', D'82'

	dt	D'20', D'85', D'64', D'87', D'102', D'89', D'133', D'91'
	dt	D'157', D'93', D'175', D'95', D'187', D'97', D'193', D'99'
	dt	D'193', D'101', D'186', D'103', D'174', D'105', D'155', D'107'
	dt	D'131', D'109', D'101', D'111', D'66', D'113', D'24', D'115'
	dt	D'234', D'116', D'181', D'118', D'123', D'120', D'60', D'122'
	dt	D'248', D'123', D'174', D'125', D'95', D'127', D'11', D'129'
	dt	D'178', D'130', D'84', D'132', D'241', D'133', D'137', D'135'
	dt	D'29', D'137', D'171', D'138', D'53', D'140', D'186', D'141'

	dt	D'59', D'143', D'183', D'144', D'46', D'146', D'161', D'147'
	dt	D'16', D'149', D'122', D'150', D'224', D'151', D'66', D'153'
	dt	D'160', D'154', D'250', D'155', D'79', D'157', D'160', D'158'
	dt	D'238', D'159', D'55', D'161', D'125', D'162', D'191', D'163'
	dt	D'253', D'164', D'55', D'166', D'109', D'167', D'160', D'168'
	dt	D'207', D'169', D'251', D'170', D'35', D'172', D'71', D'173'
	dt	D'104', D'174', D'134', D'175', D'160', D'176', D'183', D'177'
	dt	D'203', D'178', D'219', D'179', D'232', D'180', D'242', D'181'

	dt	D'249', D'182', D'253', D'183', D'254', D'184', D'251', D'185'
	dt	D'246', D'186', D'238', D'187', D'226', D'188', D'212', D'189'
	dt	D'195', D'190', D'175', D'191', D'153', D'192', D'127', D'193'
	dt	D'99', D'194', D'68', D'195', D'35', D'196', D'255', D'196'
	dt	D'216', D'197', D'175', D'198', D'131', D'199', D'85', D'200'
	dt	D'36', D'201', D'241', D'201', D'187', D'202', D'131', D'203'
	dt	D'73', D'204', D'12', D'205', D'205', D'205', D'139', D'206'
	dt	D'72', D'207', D'2', D'208', D'186', D'208', D'112', D'209'

	dt	D'35', D'210', D'213', D'210', D'132', D'211', D'50', D'212'
	dt	D'221', D'212', D'134', D'213', D'46', D'214', D'211', D'214'
	dt	D'118', D'215', D'24', D'216', D'183', D'216', D'85', D'217'
	dt	D'240', D'217', D'138', D'218', D'34', D'219', D'185', D'219'
	dt	D'77', D'220', D'224', D'220', D'113', D'221', D'0', D'222'
	dt	D'142', D'222', D'26', D'223', D'164', D'223', D'45', D'224'
	dt	D'180', D'224', D'57', D'225', D'189', D'225', D'64', D'226'
	dt	D'192', D'226', D'64', D'227', D'189', D'227', D'58', D'228'

	dt	D'180', D'228', D'46', D'229', D'166', D'229', D'28', D'230'
	dt	D'145', D'230', D'5', D'231', D'119', D'231', D'232', D'231'
	dt	D'88', D'232', D'198', D'232', D'51', D'233', D'159', D'233'
	dt	D'9', D'234', D'115', D'234', D'218', D'234', D'65', D'235'
	dt	D'167', D'235', D'11', D'236', D'110', D'236', D'208', D'236'
	dt	D'49', D'237', D'145', D'237', D'239', D'237', D'76', D'238'
	dt	D'169', D'238', D'4', D'239', D'94', D'239', D'183', D'239'
	dt	D'15', D'240', D'102', D'240', D'188', D'240', D'17', D'241'

	dt	D'101', D'241', D'184', D'241', D'10', D'242', D'91', D'242'
	dt	D'171', D'242', D'250', D'242', D'72', D'243', D'149', D'243'
	dt	D'226', D'243', D'45', D'244', D'119', D'244', D'193', D'244'
	dt	D'10', D'245', D'82', D'245', D'153', D'245', D'223', D'245'
	dt	D'36', D'246', D'105', D'246', D'173', D'246', D'240', D'246'
	dt	D'50', D'247', D'115', D'247', D'180', D'247', D'244', D'247'
	dt	D'51', D'248', D'113', D'248', D'175', D'248', D'236', D'248'
	dt	D'40', D'249', D'99', D'249', D'158', D'249', D'216', D'249'

	dt	D'17', D'250', D'74', D'250', D'130', D'250', D'185', D'250'
	dt	D'240', D'250', D'38', D'251', D'91', D'251', D'144', D'251'
	dt	D'196', D'251', D'248', D'251', D'43', D'252', D'93', D'252'
	dt	D'143', D'252', D'192', D'252', D'241', D'252', D'33', D'253'
	dt	D'80', D'253', D'127', D'253', D'173', D'253', D'219', D'253'
	dt	D'8', D'254', D'53', D'254', D'97', D'254', D'141', D'254'
	dt	D'184', D'254', D'226', D'254', D'12', D'255', D'54', D'255'
	dt	D'95', D'255', D'136', D'255', D'176', D'255', D'216', D'255'
	; One extra to make interp simple
	dt	D'255', D'255'

; We never reach here
;	end 
;================================================================
; end orig ENVGEN8 code
;================================================================ 

	END