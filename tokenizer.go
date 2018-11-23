package main

import (
	"fmt"
)

/*TokenType is an alias to create a const based enum to determine the type of token */
type TokenType int

/*Enum for the potential token values */
const (
	PLUS TokenType = iota
	MINUS
	MULT
	DIV
	EQUAL
	NUM
	NEW_LINE
	EOF
)

/*Token contains the Type of the token object and the value stored there */
type Token struct {
	Type    TokenType
	literal string
	line 	int
}

/*Tokenizer contains a list of tokens and information about the line currently being parsed */
type Tokenizer struct {
	inputString string
	tokens    []Token
	begTok	int
	cursorLoc int
	cursor    byte
	lineNo	  int
}

/*NewTokenizer creates a tokenizer struct and initializes all of its fields to their default values*/
func NewTokenizer(inputString string) Tokenizer {
	return Tokenizer{inputString, []Token{}, 0, 0, '0', 0}
}

/*Tokenize takes in an entire program as a string argument and parses it into tokens
  which it stores in the Tokens field of the tokenizer object it is called on */
func (t *Tokenizer) Tokenize() {
	for cursor := t.inputString[0]; !t.AtEnd(); cursor = t.Advance() {
		switch cursor {
		case 0:
			t.AddToken(EOF, "")
			break
		case ' ', '\t', '\r':
			//Eat whitespace
			continue
		case '\n':
			t.lineNo++
			t.AddToken(NEW_LINE, "")
		case '+':
			t.AddToken(PLUS, "")
		case '-':
			t.AddToken(MINUS, "")
		case '*':
			t.AddToken(MULT, "")
		case '/':
			t.AddToken(DIV, "")
		default:
			if IsNum(t.cursor) {
				t.Number()
			} else {
				ParseError(t.lineNo + 1, fmt.Sprintf("near -> '%c'", t.inputString[t.cursorLoc-1]))
			}
		}
	}
	t.AddToken(EOF, "")
}

/*IsNum returns true if the byte passes is a char corresponding to the numbers 0 through 9*/
func IsNum(b byte) bool {
	val := b - '0'
	isNum := val >= 0 && val <= 9
	return isNum
}

/*Number eats characters until it reaches a non-numeric character, then creates a new token*/
func (t *Tokenizer) Number() {
	for !t.AtEnd() && IsNum(t.cursor) && IsNum(t.PeekNext()) {
		t.Advance()
	}
	t.AddToken(NUM, t.inputString[t.begTok:t.cursorLoc])
}

/*Advance advances the cursor by 1 non-whitespace value within the tokenizer object */
func (t *Tokenizer) Advance() byte {
	if !t.AtEnd() {
		t.cursorLoc++
	}
	t.cursor = t.inputString[t.cursorLoc - 1]
	return t.cursor
}

/*PeekNext looks at the next character after the current cursor location */
func (t *Tokenizer) PeekNext() byte {
	if t.cursorLoc < len(t.inputString) {
		return t.inputString[t.cursorLoc]
	}
	return 0
}

/*AtEnd returns true if we have reached the end of the line to be read in, otherwise false */
func (t *Tokenizer) AtEnd() bool {
	return t.cursorLoc > len(t.inputString)-1
}

/*AddToken adds a token to the token list contained within the Tokenizer object */
func (t *Tokenizer) AddToken(tokenType TokenType, literal string) {
	token := Token{tokenType, literal, t.lineNo}
	t.begTok = t.cursorLoc
	t.tokens = append(t.tokens, token)
}
