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
	NEWLINE
	EOF
)

func (t TokenType) String() string {
	switch t {
	case PLUS:
		return "+"
	case MINUS:
		return "-"
	case MULT:
		return "*"
	case EXP:
		return "**"
	case DIV:
		return "/"
	case MOD:
		return "%%"
	case EQUAL:
		return "="
	case LEFTGROUP:
		return "("
	case RIGHTGROUP:
		return ")"
	case LEFTBRACE:
		return "{"
	case RIGHTBRACE:
		return "}"
	case INT:
		return "INT"
	case FLOAT:
		return "FLOAT"
	case PRINT:
		return "PRINT"
	case IF:
		return "IF"
	case ELSE:
		return "ELSE"
	case BANG:
		return "!"
	case BANGEQUAL:
		return "!="
	case EQUALEQUAL:
		return "=="
	case LESS:
		return "<"
	case LESSEQUAL:
		return "<="
	case GREATER:
		return ">"
	case GREATEREQUAL:
		return ">="
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
		return "INTTYPE"
	case FLOATTYPE:
		return "FLOATTYPE"
	case BOOLTYPE:
		return "BOOLTYPE"
	case STRINGTYPE:
		return "STRINGTYPE"
	case IDENTIFIER:
		return "IDENTIFIER"
	case NEWLINE:
		return "\\n"
	case EOF:
		return "EOF"
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

func (t Token) String() string {
	switch t.Type {
	case PLUS:
		return "Token: PLUS; literal ->" + t.literal
	case MINUS:
		return "Token: MINUS; literal ->" + t.literal
	case MULT:
		return "Token: MULT; literal ->" + t.literal
	case EXP:
		return "Token: EXP; literal ->" + t.literal
	case DIV:
		return "Token: DIV; literal ->" + t.literal
	case MOD:
		return "Token: MOD; literal ->" + t.literal
	case EQUAL:
		return "Token: EQUAL; literal ->" + t.literal
	case LEFTGROUP:
		return "Token: LEFTGROUP; literal ->" + t.literal
	case RIGHTGROUP:
		return "Token: RIGHTGROUP; literal ->" + t.literal
	case LEFTBRACE:
		return "Token: LEFTBRACE; literal ->" + t.literal
	case RIGHTBRACE:
		return "Token: RIGHTBRACE; literal ->" + t.literal
	case INT:
		return "Token: INT; literal ->" + t.literal
	case FLOAT:
		return "Token: FLOAT; literal ->" + t.literal
	case PRINT:
		return "Token: PRINT; literal ->" + t.literal
	case IF:
		return "Token: IF; literal ->" + t.literal
	case ELSE:
		return "Token: ELSE; literal ->" + t.literal
	case BANG:
		return "Token: BANG; literal ->" + t.literal
	case BANGEQUAL:
		return "Token: BANGEQUAL; literal ->" + t.literal
	case EQUALEQUAL:
		return "Token: EQUALEQUAL; literal ->" + t.literal
	case LESS:
		return "Token: LESS; literal ->" + t.literal
	case LESSEQUAL:
		return "Token: LESSEQUAL; literal ->" + t.literal
	case GREATER:
		return "Token: GREATER; literal ->" + t.literal
	case GREATEREQUAL:
		return "Token: GREATEREQUAL; literal ->" + t.literal
	case OR:
		return "Token: OR; literal ->" + t.literal
	case AND:
		return "Token: AND; literal ->" + t.literal
	case TRUE:
		return "Token: TRUE; literal ->" + t.literal
	case FALSE:
		return "Token: FALSE; literal ->" + t.literal
	case ASSIGN:
		return "Token: ASSIGN; literal ->" + t.literal
	case STRING:
		return "Token: STRING; literal ->" + t.literal
	case INTTYPE:
		return "Token: INTTYPE; literal ->" + t.literal
	case FLOATTYPE:
		return "Token: FLOATTYPE; literal ->" + t.literal
	case BOOLTYPE:
		return "Token: BOOLTYPE; literal ->" + t.literal
	case STRINGTYPE:
		return "Token: STRINGTYPE; literal ->" + t.literal
	case IDENTIFIER:
		return "Token: IDENTIFIER; literal ->" + t.literal
	case NEWLINE:
		return "Token: NEWLINE; literal ->" + t.literal
	case EOF:
		return "Token: EOF; literal ->" + t.literal
	default:
		return "Unknown token"
	}
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
	reserved["or"] = OR
	reserved["and"] = AND
	reserved["true"] = TRUE
	reserved["false"] = FALSE
	reserved["int"] = INTTYPE
	reserved["float"] = FLOATTYPE
	reserved["bool"] = BOOLTYPE
	reserved["string"] = STRINGTYPE
	return Tokenizer{inputString, []Token{}, 0, 0, '0', 0}
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
			t.AddToken(DIV, "")
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
			} else {
				ParseError(t.lineNo, "Expect '=' after '='")
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
				ParseError(t.lineNo, "Expect '=' after ':'")
			}
		case '"':
			for !t.Match('"') {
				t.Advance()
				if t.AtEnd() {
					ParseError(t.lineNo, "Unclosed string literal")
				}
			}
			t.AddToken(STRING, t.inputString[t.begTok+1:t.cursorLoc-1])
		default:
			if IsNum(cursor) {
				t.Number()
			} else if IsAlpha(cursor) {
				t.IdentifierOrReserved()
			} else {
				ParseError(t.lineNo+1, fmt.Sprintf("near -> '%c'", t.inputString[t.cursorLoc-1]))
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
