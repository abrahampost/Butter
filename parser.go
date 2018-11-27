package main

import (
	"strconv"
)

/*Parser struct contains helpful methods for recursive descvent parsing, as well as keeping track of the
  token list, amnd token currently being processed */
type Parser struct {
	tokens  []Token
	current int
}

/*NewParser returns a parser object with all of the fields initialized correctly to begin parsing */
func NewParser(tokens []Token) Parser {
	return Parser{tokens, 0}
}

/*Parse parses all of the Tokens into Expression objects and returns those */
func (p *Parser) Parse() []Expr {
	var expressions []Expr
	for !p.AtEnd() {
		expressions = append(expressions, p.Line())
		//Eat empty lines
		for !p.AtEnd() && p.Match(NEW_LINE) {
		}
	}
	return expressions
}

/*Line Parses an expression, then eats any trailing whitespace */
func (p *Parser) Line() Expr {
	var expr Expr
	if p.Match(PRINT) {
		expr = p.Expression()
		return Print{expr}
	}
	expr = p.Expression()
	if !p.Match(NEW_LINE, EOF) {
		ParseError(p.Current().line, "Expected end of line after expression")
	}
	return expr
}

/*Expression parses an expression object */
func (p *Parser) Expression() Expr {
	var expr Expr = p.Or()

	return expr
}

/*Or parses both sides of an or, and then connects them with an or operator (if applicable) */
func (p *Parser) Or() Expr {
	var expr Expr = p.And()

	for p.Match(OR) {
		var operator Token = p.Previous()
		var right Expr = p.And()
		expr = Binary{expr, right, operator}
	}

	return expr
}

/*And parses both subexpressions and then an And operator (if applicable) */
func (p *Parser) And() Expr {
	var expr Expr = p.Equality()

	for p.Match(AND) {
		var operator Token = p.Previous()
		var right Expr = p.Equality()
		expr = Binary{expr, right, operator}
	}

	return expr
}

/*Equality parses both sides of an expression, then connects them with an equality operator (if applicable) */
func (p *Parser) Equality() Expr {
	var expr Expr = p.Comparison()

	for p.Match(EQUAL_EQUAL, BANG_EQUAL) {
		var operator Token = p.Previous()
		var right Expr = p.Comparison()
		expr = Binary{expr, right, operator}
	}

	return expr
}

/*Comparison parses both sides of an expression, then connects them with a comparison operator (if applicable) */
func (p *Parser) Comparison() Expr {
	var expr Expr = p.Addition()

	for p.Match(GREATER, GREATER_EQUAL, LESS, LESS_EQUAL) {
		var operator Token = p.Previous()
		var right Expr = p.Addition()
		expr = Binary{expr, right, operator}
	}

	return expr
}

/*Addition parses both sides of an expression, then connects them with an addition operator (if applicable) */
func (p *Parser) Addition() Expr {
	var expr Expr = p.Multiplication()

	for p.Match(MINUS, PLUS) {
		var operator Token = p.Previous()
		var right Expr = p.Multiplication()
		expr = Binary{expr, right, operator}
	}

	return expr
}

/*Multiplication parses both sides of an expression, then connects them with a multiplication operator (if applicable) */
func (p *Parser) Multiplication() Expr {
	var expr Expr = p.Literal()

	for p.Match(MULT, DIV) {
		var operator Token = p.Previous()
		var right Expr = p.Literal()
		expr = Binary{expr, right, operator}
	}

	return expr
}

/*Literal returns an object of the type of the token passes, with a value parsed from the Token literal */
func (p *Parser) Literal() Expr {
	if p.Match(NUM) {
		prev := p.Previous()
		integer, err := strconv.Atoi(prev.literal)
		CheckError(err)
		return Literal{Integer{integer}}
	}
	if p.Match(TRUE) {
		return Literal{Boolean{true}}
	}
	if p.Match(FALSE) {
		return Literal{Boolean{false}}
	}
	if p.Match(LEFT_GROUP) {
		var expr Expr = p.Expression()
		p.Consume(RIGHT_GROUP, "Expect ')' after expression")
		return Grouping{expr}
	}
	ParseError(p.Current().line, "Expect expression")
	return nil
}

/*AtEnd checks if the current token is the last one in the file and returns true if so, otherwise false */
func (p *Parser) AtEnd() bool {
	return p.Current().Type == EOF
}

/*Advance if not at the end, evaluate the next token */
func (p *Parser) Advance() {
	if !p.AtEnd() {
		p.current++
	}
}

/*Current returns the current token under consideration */
func (p *Parser) Current() Token {
	return p.tokens[p.current]
}

/*Preious returns the previous token under consideration */
func (p *Parser) Previous() Token {
	return p.tokens[p.current-1]
}

/*Match advances if the current token matches the passed token type */
func (p *Parser) Match(ts ...TokenType) bool {
	for _, t := range ts {
		if t == p.Current().Type {
			p.Advance()
			return true
		}
	}

	return false
}

/*Consume advances if the next token matches a specific tokentype, otherwise gives a ParseError */
func (p *Parser) Consume(t TokenType, message string) {
	if p.Check(t) {
		p.Advance()
	} else {
		ParseError(p.Current().line, message)
	}

}

/*Check returns true if the current token matches a passed tokentype, otherwise false */
func (p *Parser) Check(t TokenType) bool {
	if p.AtEnd() {
		return false
	}
	return p.Current().Type == t
}
