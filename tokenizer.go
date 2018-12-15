package main

import (
	"fmt"
)

/*TokenType is an alias to create a const based enum to determine the type of token */
type TokenType int

/*Enum for the potential token values */
const (
	DEFAULT TokenType = iota
	PLUS
	MINUS
	MULT
	EXP
	DIV
	MOD
	EQUAL
	LEFTGROUP
	RIGHTGROUP
	LEFTBRACE
	RIGHTBRACE
	INT
	FLOAT
	PRINT
	IF
	ELSE
	WHILE
	BANG
	BANGEQUAL
	EQUALEQUAL
	LESS
	LESSEQUAL
	GREATER
	GREATEREQUAL
	OR
	AND
	TRUE
	FALSE
	ASSIGN
	STRING
	INTTYPE
	FLOATTYPE
	BOOLTYPE
	STRINGTYPE
	IDENTIFIER
	FUNC
	COMMA
	ARROW
	NEWLINE
	EOF
	VOID
	COLON
	RETURN
	LAMBDA
)

func (t TokenType) String() string {
	switch t {
	case PLUS:
		return "PLUS"
	case MINUS:
		return "MINUS"
	case MULT:
		return "MULT"
	case EXP:
		return "EXP"
	case DIV:
		return "DIV"
	case MOD:
		return "MOD"
	case EQUAL:
		return "EQUAL"
	case LEFTGROUP:
		return "LEFTGROUP"
	case RIGHTGROUP:
		return "RIGHTGROUP"
	case LEFTBRACE:
		return "LEFTBRACE"
	case RIGHTBRACE:
		return "RIGHTBRACE"
	case INT:
		return "INT"
	case FLOAT:
		return "FLOAT"
	case PRINT:
		return "PRINT"
	case IF:
		return "IF"
	case WHILE:
		return "WHILE"
	case ELSE:
		return "ELSE"
	case BANG:
		return "BANG"
	case BANGEQUAL:
		return "BANGEQUAL"
	case EQUALEQUAL:
		return "EQUALEQUAL"
	case LESS:
		return "LESS"
	case LESSEQUAL:
		return "LESSEQUAL"
	case GREATER:
		return "GREATER"
	case GREATEREQUAL:
		return "GREATEREQUAL"
	case OR:
		return "OR"
	case AND:
		return "AND"
	case TRUE:
		return "TRUE"
	case FALSE:
		return "FALSE"
	case ASSIGN:
		return "ASSIGN"
	case STRING:
		return "STRING"
	case INTTYPE:
		return "int"
	case FLOATTYPE:
		return "float"
	case BOOLTYPE:
		return "bool"
	case STRINGTYPE:
		return "string"
	case IDENTIFIER:
		return "IDENTIFIER"
	case FUNC:
		return "FUNCTION"
	case COMMA:
		return "COMMA"
	case ARROW:
		return "ARROW"
	case NEWLINE:
		return "NEWLINE"
	case EOF:
		return "EOF"
	case VOID:
		return "VOID"
	case COLON:
		return "COLON"
	case RETURN:
		return "RETURN"
	case LAMBDA:
		return "LAMBDA"
	default:
		return "(nil)"
	}
}

/*Token contains the Type of the token object and the value stored there */
type Token struct {
	Type    TokenType
	literal string
	line    int
}

/*Tokenizer contains a list of tokens and information about the line currently being parsed */
type Tokenizer struct {
	inputString string
	tokens      []Token
	begTok      int
	cursorLoc   int
	cursor      byte
	lineNo      int
}

var reserved map[string]TokenType

/*NewTokenizer creates a tokenizer struct and initializes all of its fields to their default values*/
func NewTokenizer(inputString string) Tokenizer {
	reserved = make(map[string]TokenType)
	reserved["print"] = PRINT
	reserved["if"] = IF
	reserved["else"] = ELSE
	reserved["while"] = WHILE
	reserved["or"] = OR
	reserved["and"] = AND
	reserved["true"] = TRUE
	reserved["false"] = FALSE
	reserved["int"] = INTTYPE
	reserved["float"] = FLOATTYPE
	reserved["bool"] = BOOLTYPE
	reserved["string"] = STRINGTYPE
	reserved["fn"] = FUNC
	reserved["return"] = RETURN
	reserved["void"] = VOID
	reserved["lambda"] = LAMBDA
	return Tokenizer{inputString, []Token{}, 0, 0, '0', 1}
}

/*Tokenize takes in an entire program as a string argument and parses it into tokens
  which it stores in the Tokens field of the tokenizer object it is called on */
func (t *Tokenizer) Tokenize() []Token {
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
			t.AddToken(NEWLINE, "")
		case ',':
			t.AddToken(COMMA, "")
		case '+':
			t.AddToken(PLUS, "")
		case '-':
			t.AddToken(MINUS, "")
		case '*':
			if t.Match('*') {
				t.AddToken(EXP, "")
			} else {
				t.AddToken(MULT, "")
			}
		case '/':
			if t.Match('/') {
				for t.PeekNext() != '\n' && !t.AtEnd() {
					t.Advance()
				}
			} else if t.Match('*') {
				for (t.PeekNext() != '*' || t.PeekNextNext() != '/') && !t.AtEnd() {
					if t.PeekNext() == '\n' {
						//make sure to update the line count in a comment so that line reporting is accurate
						t.lineNo++
					}
					t.Advance()
				}
				t.Advance()
				t.Advance()
				if t.AtEnd() {
					TokenError(t.lineNo, "Unclosed multiline comment")
					break
				}
			} else {
				t.AddToken(DIV, "")
			}
		case '%':
			t.AddToken(MOD, "")
		case '(':
			t.AddToken(LEFTGROUP, "")
		case ')':
			t.AddToken(RIGHTGROUP, "")
		case '{':
			t.AddToken(LEFTBRACE, "")
		case '}':
			t.AddToken(RIGHTBRACE, "")
		case '!':
			if t.Match('=') {
				t.AddToken(BANGEQUAL, "")
			} else {
				t.AddToken(BANG, "")
			}
		case '=':
			if t.Match('=') {
				t.AddToken(EQUALEQUAL, "")
			} else if t.Match('>') {
				t.AddToken(ARROW, "")
			} else {
				TokenError(t.lineNo, "Unknown symbol '='. Did you mean '==' or '=>'?")
			}
		case '>':
			if t.Match('=') {
				t.AddToken(GREATEREQUAL, "")
			} else {
				t.AddToken(GREATER, "")
			}
		case '<':
			if t.Match('=') {
				t.AddToken(LESSEQUAL, "")
			} else {
				t.AddToken(LESS, "")
			}
		case ':':
			if t.Match('=') {
				t.AddToken(ASSIGN, "")
			} else {
				t.AddToken(COLON, "")
			}
		case '"':
			for !t.Match('"') {
				t.Advance()
				if t.AtEnd() {
					TokenError(t.lineNo, "Unclosed string literal")
					break
				}
			}
			t.AddToken(STRING, t.inputString[t.begTok+1:t.cursorLoc-1])
		default:
			if IsNum(cursor) {
				t.Number()
			} else if IsAlpha(cursor) {
				t.IdentifierOrReserved()
			} else {
				TokenError(t.lineNo, fmt.Sprintf("near -> '%c'", t.inputString[t.cursorLoc-1]))
			}
		}
	}
	t.AddToken(EOF, "")
	return t.tokens
}

/*IsNum returns true if the byte passes is a char corresponding to the numbers 0 through 9*/
func IsNum(b byte) bool {
	val := b - '0'
	isNum := val >= 0 && val <= 9
	return isNum
}

/*IsAlpha returns true if the byte passed is a char corresponding to an alphabetic character */
func IsAlpha(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

/*IsAlphaNum returns true if the passed cursor is alpha or numeric */
func IsAlphaNum(c byte) bool {
	return IsAlpha(c) || IsNum(c)
}

/*Number eats characters until it reaches a non-numeric character, then creates a new token*/
func (t *Tokenizer) Number() {
	for !t.AtEnd() && IsNum(t.cursor) && IsNum(t.PeekNext()) {
		t.Advance()
	}
	potFloatingPoint := t.cursorLoc
	if t.Match('.') {
		for !t.AtEnd() && IsNum(t.PeekNext()) {
			t.Advance()
		}
		t.AddToken(FLOAT, t.inputString[t.begTok:potFloatingPoint]+"."+t.inputString[potFloatingPoint+1:t.cursorLoc])
	} else {
		t.AddToken(INT, t.inputString[t.begTok:t.cursorLoc])
	}

}

/*IdentifierOrReserved advances characters until it finds a non alphanumeric character and then checks to see
  if it is a reserved word. If not, it is saved as an identifier */
func (t *Tokenizer) IdentifierOrReserved() {
	for IsAlphaNum(t.PeekNext()) {
		t.Advance()
	}
	tokenType, isReserved := reserved[t.inputString[t.begTok:t.cursorLoc]]
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
	t.cursor = t.inputString[t.cursorLoc-1]
	return t.cursor
}

/*Match Advances one character if the next character to check matches the passed character. Returns true if matches,
  false, if not */
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

func (t *Tokenizer) PeekNextNext() byte {
	if t.cursorLoc+1 < len(t.inputString) {
		return t.inputString[t.cursorLoc+1]
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

func TokenError(line int, message string) {
	ReportError(fmt.Sprintf("TOKEN_ERROR [line %d]: %s", line, message))
}
