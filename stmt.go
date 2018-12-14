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

type If struct {
	condition Expr
	ifTrue    Stmt
	ifFalse   Stmt
}

type While struct {
	condition Expr
	body      Stmt
}

type Block struct {
	stmts []Stmt
}
type FuncStmt struct {
	name       Token
	params     []TypedArg
	body       []Stmt
	returnType Token
}

type ReturnStmt struct {
	expr Expr
}

type ErrorStmt struct {
	message string
}

func (f FuncStmt) Accept(interpeter *Interpreter) {
	interpreter.visitFuncStmt(f)
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

func (i If) Accept(interpreter *Interpreter) {
	interpreter.visitIf(i)
}

func (w While) Accept(interpreter *Interpreter) {
	interpreter.visitWhile(w)
}

func (b Block) Accept(interpreter *Interpreter) {
	interpreter.visitBlock(b)
}

func (r ReturnStmt) Accept(interpreter *Interpreter) {
	interpreter.visitReturn(r)
}

func (e ErrorStmt) Accept(interpreter *Interpreter) {
	interpreter.visitErrorStmt(e)
}
