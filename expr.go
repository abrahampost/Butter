package main

/*Expr defines an object which can accept an interpreter and return an object */
type Expr interface {
	Accept(interpreter *Interpreter) Object
}

/*Print contains an expr, and will evaluate and print the expression */
type Print struct {
	expr Expr
}

/*Binary contains a left and right subexpression, and then an operation which will
  operate on the resulting values */
type Binary struct {
	left, right Expr
	operator    Token
}

/*Literal is an expr that returns the value of an object */
type Literal struct {
	obj Object
}

/*Grouping is a parethetical expression that is evaluated
  before the grouping's value is returned */
type Grouping struct {
	expr Expr
}

/*Accept finds the visitPrint method on the interpreter */
func (p Print) Accept(intepreter *Interpreter) Object {
	return interpreter.visitPrint(p)
}

/*Accept finds the visitLiteral method on the interpreter */
func (l Literal) Accept(interpreter *Interpreter) Object {
	return interpreter.visitLiteral(l)
}

/*Accept finds the visitBinary method on the inrepreter */
func (b Binary) Accept(interpreter *Interpreter) Object {
	return interpreter.visitBinary(b)
}

/*Accept visits the visitGrouping method on the interpreter */
func (g Grouping) Accept(interpreter *Interpreter) Object {
	return interpreter.visitGrouping(g)
}
