package main

import (
	"fmt"
	"strings"
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
	LEFT_GROUP
	RIGHT_GROUP
	NUM
	END_LINE
)

/*Token contains the Type of the token object and the value stored there */
type Token struct {
	Type    TokenType
	literal string
}

/*Tokenizer contains a list of tokens and information about the line currently being parsed */
type Tokenizer struct {
	tokens    []Token
	line      string
	notEmpty  bool
	begTok    int
	cursorLoc int
	cursor    byte
}

/*NewTokenizer creates a tokenizer struct and initializes all of its fields to their default values*/
func NewTokenizer() Tokenizer {
	return Tokenizer{[]Token{}, "", false, 0, 0, '0'}
}

/*Tokenize takes in an entire program as a string argument and parses it into tokens
  which it stores in the Tokens field of the tokenizer object it is called on */
func (t *Tokenizer) Tokenize(input string) {
	lines := strings.Split(input, "\n")
	for lineNo, line := range lines {
		if line == "" {
			continue
		}
		t.NewLine(line)
		for ; !t.AtEnd(); t.Advance() {
			t.begTok = t.cursorLoc
			switch t.cursor {
			case ' ', '\t', '\r':
				//Eat whitespace
				continue
			case '+':
				t.AddToken(PLUS, "")
			case '-':
				t.AddToken(MINUS, "")
			case '*':
				t.AddToken(MULT, "")
			case '/':
				t.AddToken(DIV, "")
			case '(':
				t.AddToken(LEFT_GROUP, "")
			case ')':
				t.AddToken(RIGHT_GROUP, "")
			default:
				if IsNum(t.cursor) {
					t.Number()
				} else {
					ParseError(lineNo + 1, fmt.Sprintf("near -> '%s'", t.line[t.cursorLoc:]))
				}
			}
			t.notEmpty = true
		}
		if t.notEmpty {
			t.AddToken(END_LINE, "")
		}
	}
}

/*IsNum returns true if the byte passes is a char corresponding to the numbers 0 through 9*/
func IsNum(b byte) bool {
	val := b - '0'
	return val >= 0 && val <= 9
}

/*Number eats characters until it reaches a non-numeric character, then creates a new token*/
func (t *Tokenizer) Number() {
	for !t.AtEnd() && IsNum(t.cursor) && IsNum(t.PeekNext()) {
		t.Advance()
	}
	t.AddToken(NUM, t.line[t.begTok:t.cursorLoc+1])
}

/*Advance advances the cursor by 1 non-whitespace value within the tokenizer object */
func (t *Tokenizer) Advance() {
	if !t.AtEnd() {
		t.cursorLoc++
		t.cursor = t.line[t.cursorLoc]
	}
}

/*PeekNext looks at the next character after the current cursor location */
func (t *Tokenizer) PeekNext() byte {
	if t.cursorLoc+1 < len(t.line) {
		return t.line[t.cursorLoc+1]
	}
	return 0
}

/*AtEnd returns true if we have reached the end of the line to be read in, otherwise false */
func (t *Tokenizer) AtEnd() bool {
	return t.cursorLoc >= len(t.line)-1
}

/*NewLine resets the tokenizer object to read in a new line */
func (t *Tokenizer) NewLine(line string) {
	t.line = line
	t.notEmpty = false
	t.begTok = 0
	t.cursorLoc = 0
	t.cursor = t.line[0]
}

/*AddToken adds a token to the token list contained within the Tokenizer object */
func (t *Tokenizer) AddToken(tokenType TokenType, literal string) {
	token := Token{tokenType, literal}
	t.tokens = append(t.tokens, token)
}
