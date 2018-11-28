package main

/*Expr defines an object which can accept an interpreter and return an object */
type Stmt interface {
	Accept(interpreter *Interpreter)
}

/*Print contains an expr, and will evaluate and print the expression */
type Print struct {
	expr Expr
}

/*ExprStmt contains an expr which will be evaluated */
type ExprStmt struct {
	expr Expr
}

type VarDeclaration struct {
	tokenType   Token
	identifier  Token
	initializer Expr
}

type ErrorStmt struct {
	message string
}

/*Accept finds the visitPrint method on the interpreter */
func (p Print) Accept(intepreter *Interpreter) {
	interpreter.visitPrint(p)
}

func (e ExprStmt) Accept(interpreter *Interpreter) {
	interpreter.visitExprStmt(e)
}

func (vd VarDeclaration) Accept(interpreter *Interpreter) {
	interpreter.visitVarDeclaration(vd)
}

func (e ErrorStmt) Accept(interpreter *Interpreter) {
	interpreter.visitErrorStmt(e)
}
