package main

type Expr interface {
	Accept(interpreter *Interpreter) Object
}

type Binary struct {
	left, right Expr
	operator Token
}

type Literal struct {
	obj Object
}

type Grouping struct {
	expr Expr
}

func (l Literal) Accept(interpreter *Interpreter) Object {
	return interpreter.visitLiteral(l)
}

func (b Binary) Accept(interpreter *Interpreter) Object {
	return interpreter.visitBinary(b)
}

func (g Grouping) Accept(interpreter *Interpreter) Object {
	return interpreter.visitGrouping(g)
}