package main

/*Expr defines an object which can accept an interpreter and return an object */
type Expr interface {
	Accept(interpreter *Interpreter) Object
}

/*Print contains an expr, and will evaluate and print the expression */
type Print struct {
	expr Expr
}

/*Assign is an expr which will evaluate the righthand expression and assign it to the identifier
  on the left within the env */
type Assign struct {
	identifier  Token
	initializer Expr
}

/*Variable is an expression which will retrieve the contents of a variable from Env memory */
type Variable struct {
	identifier Token
}

/*Binary contains a left and right subexpression, and then an operation which will
  operate on the resulting values */
type Binary struct {
	left, right Expr
	operator    Token
}

/*Unary contains an operator and an expression and performs the operation on the expression */
type Unary struct {
	right    Expr
	operator Token
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

/*Accept passes assign to the visitAssign method on the interpreter */
func (a Assign) Accept(interpreter *Interpreter) Object {
	return interpreter.visitAssign(a)
}

/*Accept passes assign to the visitVariable method on the interpreter */
func (v Variable) Accept(interpreter *Interpreter) Object {
	return interpreter.visitVariable(v)
}

/*Accept finds the visitPrint method on the interpreter */
func (p Print) Accept(intepreter *Interpreter) Object {
	return interpreter.visitPrint(p)
}

/*Accept finds the visitLiteral method on the interpreter */
func (l Literal) Accept(interpreter *Interpreter) Object {
	return interpreter.visitLiteral(l)
}

/*Accept finds the visitBinary method on the interpreter */
func (b Binary) Accept(interpreter *Interpreter) Object {
	return interpreter.visitBinary(b)
}

/*Accept finds the visitUnary method on the interpreter*/
func (u Unary) Accept(interpreter *Interpreter) Object {
	return interpreter.visitUnary(u)
}

/*Accept visits the visitGrouping method on the interpreter */
func (g Grouping) Accept(interpreter *Interpreter) Object {
	return interpreter.visitGrouping(g)
}
