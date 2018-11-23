package main

import (
	"strconv"
)

type Parser struct {
	tokens []Token
	current int
}

func NewParser(tokens []Token) Parser {
	return Parser{tokens, 0}
}

func (p *Parser) Parse() []Expr {
	var expressions []Expr
	for !p.AtEnd() {
		expressions = append(expressions, p.Expression())
	}
	return expressions
}


func (p *Parser) Expression() Expr {
	var expr Expr = p.Addition()
	if !p.Match(NEW_LINE, EOF) {
		ParseError(p.Current().line, "Expected end of line after expression")
	}
	return expr
}

func (p *Parser) Addition() Expr {
	var expr Expr = p.Multiplication()

	for p.Match(MINUS, PLUS) {
		var operator Token = p.Previous()
		var right Expr = p.Multiplication()
		expr = Binary{expr, right, operator}
	}

	return expr
}

func (p *Parser) Multiplication() Expr {
	var expr Expr = p.Literal()

	for p.Match(MULT, DIV) {
		var operator Token = p.Previous()
		var right Expr = p.Literal()
		expr = Binary{expr, right, operator}
	}

	return expr
}

func (p *Parser) Literal() Expr {
	if p.Match(NUM) {
		prev := p.Previous()
		integer, err := strconv.Atoi(prev.literal)
		CheckError(err)
		return Literal{Integer{integer}}
	}
	ParseError(p.Current().line, "Unrecognized literal value: " + p.Current().literal)
	return nil
}

func (p *Parser) AtEnd() bool {
	return p.current > len(p.tokens) - 1
}

func (p *Parser) Advance() {
	if !p.AtEnd() {
		p.current++
	}
}

func (p *Parser) Current() Token {
	return p.tokens[p.current]
}


func (p *Parser) Previous() Token {
	return p.tokens[p.current - 1]
}

func (p *Parser) Match(ts... TokenType) bool{
	for _, t := range ts {
		if t == p.Current().Type {
			p.Advance()
			return true
		}
	} 

	return false
}

func (p *Parser) Consume(t TokenType, message string) {
	if p.Check(t) {
		p.Advance()
	} else {
		ParseError(p.Current().line, message)
	}

}

func (p *Parser) Check(t TokenType) bool {
	if p.AtEnd() {
		return false
	}
	return p.Current().Type == t
}