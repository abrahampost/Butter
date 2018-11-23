package main

type Expr interface {
	Accept(interpreter Interpreter) Object
}

type Binary struct {
	left, right Expr
	operator Token
}

type Literal struct {
	obj Object
}

func (l Literal) Accept(interpreter Interpreter) Object {
	return interpreter.acceptLiteral(l)
}

func (b Binary) Accept(interpreter Interpreter) Object {
	return interpreter.visitBinary(b)
}