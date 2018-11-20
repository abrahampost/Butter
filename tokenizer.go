package main

import (
	"fmt"
	"strings"
)

type TokenType int

const (
	PLUS TokenType = iota
	MINUS
	MULT
	DIV
	EQUAL
)

type Token struct {
	Type    TokenType
	literal string
}

type Tokenizer struct {
	tokens []Token
	line   string
	begTok int
	cursor int
}

func NewTokenizer() Tokenizer {
	return Tokenizer{[]Token{}, "", 0, 0}
}

func (t *Tokenizer) Tokenize(input string) {
	lines := strings.Split(input, "\n")
	for lineNo, line := range lines {
		fmt.Printf("Line %d: %s\n", lineNo, line)
	}
}

func (t *Tokenizer) AddToken(token Token) {
	t.tokens = append(t.tokens, token)
}
