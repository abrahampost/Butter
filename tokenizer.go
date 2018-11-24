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
	LEFT_GROUP
	RIGHT_GROUP
	NUM
	PRINT
	BANG
	BANG_EQUAL
	EQUAL_EQUAL
	LESS
	LESS_EQUAL
	GREATER
	GREATER_EQUAL
	ASSIGN
	IDENTIFIER
	NEW_LINE
	EOF
)

/*Token contains the Type of the token object and the value stored there */
type Token struct {
	Type    TokenType
	literal string
	line 	int
}

func (t Token) String() string {
	switch t.Type {
	case PLUS:
		return "Token: PLUS; literal ->" + t.literal
	case MINUS:
		return "Token: MINUS; literal ->" + t.literal
	case MULT:
		return "Token: MULT; literal ->" + t.literal
	case DIV:
		return "Token: DIV; literal ->" + t.literal
	case EQUAL:
		return "Token: EQUAL; literal ->" + t.literal
	case LEFT_GROUP:
		return "Token: LEFT_GROUP; literal ->" + t.literal
	case RIGHT_GROUP:
		return "Token: RIGHT_GROUP; literal ->" + t.literal
	case NUM:
		return "Token: NUM; literal ->" + t.literal
	case PRINT:
		return "Token: PRINT; literal ->" + t.literal
	case BANG:
		return "Token: BANG; literal ->" + t.literal
	case BANG_EQUAL:
		return "Token: BANG_EQUAL; literal ->" + t.literal
	case EQUAL_EQUAL:
		return "Token: EQUAL_EQUAL; literal ->" + t.literal
	case LESS:
		return "Token: LESS; literal ->" + t.literal
	case LESS_EQUAL:
		return "Token: LESS_EQUAL; literal ->" + t.literal
	case GREATER:
		return "Token: GREATER; literal ->" + t.literal
	case GREATER_EQUAL:
		return "Token: GREATER_EQUAL; literal ->" + t.literal
	case ASSIGN:
		return "Token: ASSIGN; literal ->" + t.literal
	case IDENTIFIER:
		return "Token: IDENTIFIER; literal ->" + t.literal
	case NEW_LINE:
		return "Token: NEW_LINE; literal ->" + t.literal
	case EOF:
		return "Token: EOF; literal ->" + t.literal
	default:
		return "Unknown token"
	}
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

var reserved map[string]TokenType

/*NewTokenizer creates a tokenizer struct and initializes all of its fields to their default values*/
func NewTokenizer(inputString string) Tokenizer {
	reserved = make(map[string]TokenType)
	reserved["print"] = PRINT
	return Tokenizer{inputString, []Token{}, 0, 0, '0', 0}
}

/*Tokenize takes in an entire program as a string argument and parses it into tokens
  which it stores in the Tokens field of the tokenizer object it is called on */
func (t *Tokenizer) Tokenize() {
	for cursor := t.Advance(); !t.AtEnd(); cursor = t.Advance() {
		switch cursor {
		case 0:
			t.AddToken(EOF, "")
			break
		case ' ', '\t', '\r':
			//Eat whitespace
			t.begTok++
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
		case '(':
			t.AddToken(LEFT_GROUP, "")
		case ')':
			t.AddToken(RIGHT_GROUP, "")
		case '!':
			if t.Match('=') {
				t.AddToken(BANG_EQUAL, "")
			} else {
				t.AddToken(BANG, "")
			}
		case '=':
			if t.Match('=') {
				t.AddToken(EQUAL_EQUAL, "")
			} else {	
				ParseError(t.lineNo, "Expect '=' after '='")
			}
		case '>':
			if t.Match('=') {
				t.AddToken(GREATER_EQUAL, "")
			} else {
				t.AddToken(GREATER, "")
			}
		case '<':
			if t.Match('=') {
				t.AddToken(LESS_EQUAL, "")
			} else {
				t.AddToken(LESS, "")
			}
		case ':':
			if t.Match('=') {
				t.AddToken(ASSIGN, "")
			} else {
				ParseError(t.lineNo, "Expect '=' after ':'")
			}
		default:
			if IsNum(cursor) {
				t.Number()
			} else if IsAlpha(cursor) {
				t.IdentifierOrReserved()
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

/*IsAlphaNum returns true if the passed cursor is alphanumeric */
func IsAlpha(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

func IsAlphaNum(c byte) bool {
	return IsAlpha(c) || IsNum(c)
}

/*Number eats characters until it reaches a non-numeric character, then creates a new token*/
func (t *Tokenizer) Number() {
	for !t.AtEnd() && IsNum(t.cursor) && IsNum(t.PeekNext()) {
		t.Advance()
	}
	t.AddToken(NUM, t.inputString[t.begTok:t.cursorLoc])
}

func (t *Tokenizer) IdentifierOrReserved() {
	for !t.AtEnd() && IsAlphaNum(t.cursor) {
		t.Advance()
	}
	tokenType, isReserved := reserved[t.inputString[t.begTok:t.cursorLoc-1]]
	if isReserved {
		t.AddToken(tokenType, "")
	} else {
		t.AddToken(IDENTIFIER, t.inputString[t.begTok:t.cursorLoc])
	}
}

/*Advance advances the cursor by 1 non-whitespace value within the tokenizer object */
func (t *Tokenizer) Advance() byte {
	if !t.AtEnd() {
		t.cursorLoc++
	}
	t.cursor = t.inputString[t.cursorLoc - 1]
	return t.cursor
}

func (t *Tokenizer) Match(c byte) bool {
	if t.PeekNext() == c {
		t.Advance()
		return true
	}
	return false
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
