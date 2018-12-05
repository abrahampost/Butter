package main

import (
	"fmt"
	"strconv"
)

var hadParseError bool = false

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
func (p *Parser) Parse() []Stmt {
	//Eat the newlines at the very beginning of the file
	p.IgnoreNewlines()
	var statements []Stmt
	for !p.AtEnd() {
		//Eat newlines before statements
		decl := p.Declaration()
		if hadParseError {
			p.Synchronize()
			hadParseError = false
		} else {
			statements = append(statements, decl)
			//Eat new lines after statements
			p.IgnoreNewlines()
		}
	}
	return statements
}

func (p *Parser) Declaration() Stmt {
	if p.Match(INTTYPE, FLOATTYPE, STRINGTYPE, BOOLTYPE) {
		return p.VarDeclaration()
	}
	if p.Match(LEFTBRACE) {
		return Block{p.Block()}
	}
	if p.Match(IF) {
		return p.IfStmt()
	}
	if p.Match(WHILE) {
		return p.WhileStmt()
	}
	return p.Statement()
}

func (p *Parser) VarDeclaration() Stmt {
	varType := p.Previous()
	if p.Match(IDENTIFIER) {
		identifier := p.Previous()
		if p.Match(ASSIGN) {
			initializer := p.Expression()
			p.CheckEndline()
			return VarDeclaration{varType, identifier, initializer}
		} else {
			p.CheckEndline()
			//if there isn't an initializing statement, initialize the value to the zero value for that data type
			switch varType.Type {
			case INTTYPE:
				return VarDeclaration{varType, identifier, Literal{Integer{0}}}
			case FLOATTYPE:
				return VarDeclaration{varType, identifier, Literal{Float{0}}}
			case BOOLTYPE:
				return VarDeclaration{varType, identifier, Literal{Boolean{false}}}
			case STRINGTYPE:
				return VarDeclaration{varType, identifier, Literal{String{""}}}
			}
		}
	} else {
		ParseError(p.Previous().line, "expect variable declaration")
	}
	//as of now ErrorStmt will never be used, but will eventually catch error
	return ErrorStmt{"Expect variable declaration"}
}

func (p *Parser) Block() []Stmt {
	p.Consume(NEWLINE, "Expect newline after block")
	var stmts []Stmt
	for !p.Check(RIGHTBRACE) && !p.AtEnd() {
		stmts = append(stmts, p.Declaration())
	}
	p.Consume(RIGHTBRACE, "Expect '}' after block.")
	return stmts
}

func (p *Parser) IfStmt() Stmt {
	condition := p.Expression()
	ifTrue := p.Declaration()
	p.IgnoreNewlines()
	var ifFalse Stmt
	if p.Match(ELSE) {
		ifFalse = p.Declaration()
	}
	return If{condition, ifTrue, ifFalse}
}

func (p *Parser) WhileStmt() Stmt {
	condition := p.Expression()
	body := p.Declaration()
	return While{condition, body}
}

/*Line Parses an expression, then eats any trailing whitespace */
func (p *Parser) Statement() Stmt {
	if p.Match(PRINT) {
		expr := p.Expression()
		p.CheckEndline()
		return Print{expr}
	}
	return p.ExpressionStatement()
}

func (p *Parser) ExpressionStatement() Stmt {
	exprStmt := ExprStmt{p.Expression()}
	p.CheckEndline()
	return exprStmt
}

/*Expression parses an expression object */
func (p *Parser) Expression() Expr {
	expr := p.Assignment()

	return expr
}

func (p *Parser) Assignment() Expr {
	expr := p.Or()

	if p.Match(ASSIGN) {
		value := p.Assignment()
		if e, ok := expr.(Variable); ok {
			return Assign{e.identifier, value}
		} else {
			ParseError(p.Previous().line, "Invalid assignment target")
		}
	}

	return expr
}

/*Or parses both sides of an or, and then connects them with an or operator (if applicable) */
func (p *Parser) Or() Expr {
	expr := p.And()

	for p.Match(OR) {
		operator := p.Previous()
		right := p.And()
		expr = Binary{expr, right, operator}
	}

	return expr
}

/*And parses both subexpressions and then an And operator (if applicable) */
func (p *Parser) And() Expr {
	expr := p.Equality()

	for p.Match(AND) {
		operator := p.Previous()
		right := p.Equality()
		expr = Binary{expr, right, operator}
	}

	return expr
}

/*Equality parses both sides of an expression, then connects them with an equality operator (if applicable) */
func (p *Parser) Equality() Expr {
	expr := p.Comparison()

	for p.Match(EQUALEQUAL, BANGEQUAL) {
		operator := p.Previous()
		right := p.Comparison()
		expr = Binary{expr, right, operator}
	}

	return expr
}

/*Comparison parses both sides of an expression, then connects them with a comparison operator (if applicable) */
func (p *Parser) Comparison() Expr {
	expr := p.Exponent()

	for p.Match(GREATER, GREATEREQUAL, LESS, LESSEQUAL) {
		operator := p.Previous()
		right := p.Exponent()
		expr = Binary{expr, right, operator}
	}

	return expr
}

func (p *Parser) Exponent() Expr {
	expr := p.Addition()

	for p.Match(EXP) {
		operator := p.Previous()
		right := p.Addition()
		expr = Binary{expr, right, operator}
	}

	return expr
}

/*Addition parses both sides of an expression, then connects them with an addition operator (if applicable) */
func (p *Parser) Addition() Expr {
	expr := p.Multiplication()

	for p.Match(MINUS, PLUS) {
		operator := p.Previous()
		right := p.Multiplication()
		expr = Binary{expr, right, operator}
	}

	return expr
}

/*Multiplication parses both sides of an expression, then connects them with a multiplication operator (if applicable) */
func (p *Parser) Multiplication() Expr {
	expr := p.Unary()

	for p.Match(MULT, DIV, MOD) {
		operator := p.Previous()
		right := p.Unary()
		expr = Binary{expr, right, operator}
	}

	return expr
}

func (p *Parser) Unary() Expr {
	for p.Match(BANG, MINUS) {
		operator := p.Previous()
		right := p.Literal()
		return Unary{right, operator}
	}

	return p.Literal()
}

/*Literal returns an object of the type of the token passes, with a value parsed from the Token literal */
func (p *Parser) Literal() Expr {
	if p.Match(INT) {
		prev := p.Previous()
		integer, err := strconv.Atoi(prev.literal)
		if err != nil {
			ParseError(p.Previous().line, "Unable to parse int")
		}
		return Literal{Integer{integer}}
	}
	if p.Match(FLOAT) {
		prev := p.Previous()
		float, err := strconv.ParseFloat(prev.literal, 64)
		if err != nil {
			ParseError(prev.line, "Unable to parse float")
		}
		return Literal{Float{float}}
	}
	if p.Match(STRING) {
		prev := p.Previous()
		return Literal{String{prev.literal}}
	}
	if p.Match(TRUE) {
		return Literal{Boolean{true}}
	}
	if p.Match(FALSE) {
		return Literal{Boolean{false}}
	}
	if p.Match(LEFTGROUP) {
		expr := p.Expression()
		p.Consume(RIGHTGROUP, "Expect ')' after expression")
		return Grouping{expr}
	}
	if p.Match(IDENTIFIER) {
		prev := p.Previous()
		return Variable{prev}
	}
	ParseError(p.Current().line, "Expect expression, received->"+p.Current().Type.String()+" "+p.Current().literal)
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

/*Previous returns the previous token under consideration */
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

func (p *Parser) IgnoreNewlines() {
	for !p.AtEnd() && p.Match(NEWLINE) {
	}
}

func (p *Parser) CheckEndline() bool {
	if p.Match(NEWLINE, EOF) {
		return true
	}
	ParseError(p.Current().line, "Expected new line after statement")
	return false
}

/*Synchronize returns the parser to the beginning of a statement, where it can hopefully continue parsing input */
func (p *Parser) Synchronize() {
	for !p.Match(NEWLINE) && !p.AtEnd() {

	}
}

/*ParseError Reports an error during the initial tokenization and parsing of the input */
func ParseError(line int, message string) {
	var lineMessage string
	if line != -1 {
		lineMessage = fmt.Sprintf(" [line %d]", line)
	}
	errorMessage := fmt.Sprintf("PARSE_ERROR%s: %s", lineMessage, message)
	ReportError(errorMessage)
	hadParseError = true
}
