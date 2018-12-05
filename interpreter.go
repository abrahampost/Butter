package main

import (
	"fmt"
	"math"
	"strconv"
)

var hadRuntimeError bool = false

/*The Interpreter struct which merely holds a bunch of methods */
type Interpreter struct {
	env    Env
	isRepl bool
}

/*NewInterpreter returns a new Interpreter object with a properly initialized environment */
func NewInterpreter() Interpreter {
	i := Interpreter{}
	i.env = NewEnvironment(nil)
	return i
}

/*Interpret takes a list of parsed AST expressions and evaluates them */
func (i *Interpreter) Interpret(stmts []Stmt, repl bool) {
	i.isRepl = repl
	for _, stmt := range stmts {
		i.Execute(stmt)
		if hadRuntimeError {
			break
		}
	}
}

func (i *Interpreter) Execute(s Stmt) {
	s.Accept(i)
}

/*Evaluate calls the accept method on the Expr, making sure it is passed to the correct method
  back on the interpreter for evaluation */
func (i *Interpreter) Evaluate(e Expr) Object {
	return e.Accept(i)
}

func (i *Interpreter) visitExprStmt(e ExprStmt) {
	val := i.Evaluate(e.expr)
	if i.isRepl && val != NIL && !IsButterError(val) {
		fmt.Println(Stringify(val))
	}
}
func (i *Interpreter) visitVarDeclaration(vd VarDeclaration) {
	val := i.Evaluate(vd.initializer)
	if val.Type() != ERROROBJ && CheckVarType(vd.tokenType, val) {
		i.env.define(vd.identifier.literal, val)
	}
}
func (i *Interpreter) visitErrorStmt(e ErrorStmt) {
	fmt.Println(e.message)
}

/*visitAssign visits an assignment operation and then saves it to the environment variable */
func (i *Interpreter) visitAssign(a Assign) Object {
	val := i.Evaluate(a.initializer)
	if !IsButterError(val) {
		i.env.assign(a.identifier.literal, val)
	}
	return NIL
}

/*visitVariable looks up a variable in the environment and returns it */
func (i *Interpreter) visitVariable(v Variable) Object {
	return i.env.get(v.identifier.literal)
}

/*visitPrint evaluates the expr contained within a print object and then prints that */
func (i *Interpreter) visitPrint(p Print) {
	result := i.Evaluate(p.expr)
	if !IsButterError(result) {
		fmt.Println(Stringify(result))
	}
}

func (i *Interpreter) visitIf(ifStmt If) {
	condition := i.Evaluate(ifStmt.condition)
	if IsButterError(condition) {
		return
	}
	if res, ok := condition.(Boolean); ok {
		if res.Value {
			i.Execute(ifStmt.ifTrue)
		} else if ifStmt.ifFalse != nil {
			i.Execute(ifStmt.ifFalse)
		}
	} else {
		RuntimeError("Cannot use non boolean value in if conditional")
	}
}

func (i *Interpreter) visitWhile(w While) {
	condition := i.Evaluate(w.condition)

	condBool, ok := condition.(Boolean)
	if !ok {
		RuntimeError("Cannot use non boolean value in while condition")
		return
	}
	for condBool.Value {
		i.Execute(w.body)
		condition := i.Evaluate(w.condition)
		condBool, ok = condition.(Boolean)
		if !ok {
			RuntimeError("Cannot use non boolean value in while condition")
		}
	}
}

func (i *Interpreter) visitBlock(b Block) {
	prevEnv := i.env
	i.env = NewEnvironment(&prevEnv)
	defer func() { i.env = prevEnv }()
	for _, stmt := range b.stmts {
		i.Execute(stmt)
		if hadRuntimeError {
			break
		}
	}
}

/*visitGrouping evaluates the internal expression and then returns that */
func (i *Interpreter) visitGrouping(g Grouping) Object {
	return i.Evaluate(g.expr)
}

/*visitBinary evaluates the left and right subexpressions, and then performs the proper operation
  on the two values*/
func (i *Interpreter) visitBinary(b Binary) Object {
	leftObj := i.Evaluate(b.left)
	rightObj := i.Evaluate(b.right)
	isNum := CheckNumberOperands(leftObj, rightObj)
	if isNum {
		//if either is a float, figure out which is a float and then cast to floats
		if leftObj.Type() == FLOATOBJ || rightObj.Type() == FLOATOBJ {
			var lFloat, rFloat Float
			if leftObj.Type() != FLOATOBJ {
				leftInt := leftObj.(Integer)
				lFloat = Float{float64(leftInt.Value)}
			} else {
				lFloat = leftObj.(Float)
			}
			if rightObj.Type() != FLOATOBJ {
				rightInt := rightObj.(Integer)
				rFloat = Float{float64(rightInt.Value)}
			} else {
				rFloat = rightObj.(Float)
			}
			return EvaluateFloat(lFloat, rFloat, b.operator)
		} else {
			//If neither are floats, they must be integers and should use integer math
			lInteger := leftObj.(Integer)
			rInteger := rightObj.(Integer)
			return EvaluateInt(lInteger, rInteger, b.operator)
		}
	}
	if leftObj.Type() == BOOLEANOBJ && rightObj.Type() == BOOLEANOBJ {
		return EvaluateBoolean(leftObj.(Boolean), rightObj.(Boolean), b.operator)
	}
	if leftString, ok := leftObj.(String); ok {
		switch b.operator.Type {
		case PLUS:
			return String{leftString.Value + Stringify(rightObj)}
		}
	}
	return RuntimeError(fmt.Sprintf("Mismatched operands -> '%s' does not support '%s' operation on '%s'", string(leftObj.Type()), b.operator.Type, string(rightObj.Type())))
}

func (i *Interpreter) visitUnary(u Unary) Object {
	result := i.Evaluate(u.right)
	if IsButterError(result) {
		return result
	}
	switch u.operator.Type {
	case BANG:
		if val, ok := result.(Boolean); ok {
			return Boolean{!val.Value}
		}
		return RuntimeError("Cannot negate non-boolean object")
	case MINUS:
		if val, ok := result.(Integer); ok {
			return Integer{-val.Value}
		}
		if val, ok := result.(Float); ok {
			return Float{-val.Value}
		}
		return RuntimeError("Cannot have negative non-number type")
	}
	return RuntimeError("Unknown unary operator")
}

/*visitLiteral return sthe underlying object value of a literal */
func (i *Interpreter) visitLiteral(l Literal) Object {
	return l.obj
}

/*EvaluateFloat evaluates mathematical operation on two floats and returns an Object*/
func EvaluateFloat(left Float, right Float, operator Token) Object {
	switch operator.Type {
	case PLUS:
		return Float{left.Value + right.Value}
	case MINUS:
		return Float{left.Value - right.Value}
	case DIV:
		if right.Value == 0 {
			return RuntimeError("Divide by zero error")
		} else if left.Value == 0 {
			return Float{0}
		}
		return Float{left.Value / right.Value}
	case MULT:
		if left.Value == 0 || right.Value == 0 {
			return Float{0}
		}
		return Float{left.Value * right.Value}
	case EXP:
		res := math.Pow(left.Value, right.Value)
		return Float{res}
	case EQUALEQUAL:
		return Boolean{left.Value == right.Value}
	case BANGEQUAL:
		return Boolean{left.Value != right.Value}
	case GREATER:
		return Boolean{left.Value > right.Value}
	case GREATEREQUAL:
		return Boolean{left.Value >= right.Value}
	case LESS:
		return Boolean{left.Value < right.Value}
	case LESSEQUAL:
		return Boolean{left.Value <= right.Value}
	default:
		return RuntimeError(fmt.Sprintf("Unsupported operation (%s) on values of type 'FLOAT'", operator.Type.String()))
	}
}

/*EvaluateInt returns an object based on the operation between two integers*/
func EvaluateInt(left Integer, right Integer, operator Token) Object {
	switch operator.Type {
	case PLUS:
		return Integer{left.Value + right.Value}
	case MINUS:
		return Integer{left.Value - right.Value}
	case DIV:
		if right.Value == 0 {
			return RuntimeError("Divide by zero error")
		} else if left.Value == 0 {
			return Integer{0}
		}
		return Integer{left.Value / right.Value}
	case MOD:
		if right.Value == 0 {
			return RuntimeError("Module by zero error")
		}
		return Integer{left.Value % right.Value}
	case MULT:
		if left.Value == 0 || right.Value == 0 {
			return Integer{0}
		}
		return Integer{left.Value * right.Value}
	case EXP:
		res := math.Pow(float64(left.Value), float64(right.Value))
		return Integer{int(res)}
	case EQUALEQUAL:
		return Boolean{left.Value == right.Value}
	case BANGEQUAL:
		return Boolean{left.Value != right.Value}
	case GREATER:
		return Boolean{left.Value > right.Value}
	case GREATEREQUAL:
		return Boolean{left.Value >= right.Value}
	case LESS:
		return Boolean{left.Value < right.Value}
	case LESSEQUAL:
		return Boolean{left.Value <= right.Value}
	default:
		return RuntimeError(fmt.Sprintf("Unsupported operation (%s) on values of type 'INTEGER'", operator.Type.String()))
	}
}

/*EvaluateBoolean returns an object based on the operations of two Boolean objects */
func EvaluateBoolean(left Boolean, right Boolean, operator Token) Object {
	switch operator.Type {
	case AND:
		return Boolean{left.Value && right.Value}
	case OR:
		return Boolean{left.Value || right.Value}
	case EQUAL:
		return Boolean{left.Value == right.Value}
	case BANGEQUAL:
		return Boolean{left.Value != right.Value}
	default:
		return RuntimeError("Unsupported operation on values of type 'BOOLEAN'")
	}
}

/*Stringify returns a string representation of an object */
func Stringify(o Object) string {
	switch t := o.(type) {
	case Integer:
		return strconv.Itoa(t.Value)
	case Float:
		//if the value is almost equal to a whole number, then only print .0 at the end and nothing crazy
		if t.Value-float64(int(t.Value)) < .0000000001 {
			return fmt.Sprintf("%.0f.0", t.Value)
		}
		return fmt.Sprint(t.Value)
	case Boolean:
		if t.Value {
			return "TRUE"
		}
		return "FALSE"
	case String:
		return t.Value
	default:
		return "(nil)"
	}
}

/*CheckNumberOperands returns a tuple with the values and a positive bool if the objects are both Integers */
func CheckNumberOperands(left Object, right Object) bool {
	leftNum := left.Type() == INTEGEROBJ || left.Type() == FLOATOBJ
	rightNum := right.Type() == INTEGEROBJ || right.Type() == FLOATOBJ
	return leftNum && rightNum
}

func CheckVarType(varType Token, val Object) bool {
	switch varType.Type {
	case INTTYPE:
		if val.Type() != INTEGEROBJ {
			RuntimeError("TypeError -> cannot assign " + string(val.Type()) + " to int type")
			return false
		}
		return true
	case FLOATTYPE:
		if val.Type() != FLOATOBJ {
			RuntimeError("TypeError -> cannot assign " + string(val.Type()) + " to float type")
			return false
		}
		return true
	case BOOLTYPE:
		if val.Type() != BOOLEANOBJ {
			RuntimeError("TypeError -> cannot assign " + string(val.Type()) + " to bool type")
			return false
		}
		return true
	case STRINGTYPE:
		if val.Type() != STRINGOBJ {
			RuntimeError("TypeError -> cannot assign " + string(val.Type()) + " to string type")
			return false
		}
		return true
	default:
		RuntimeError("TypeError -> Unknown assignment type")
	}
	return false
}

func IsButterError(o Object) bool {
	return o.Type() == ERROROBJ
}

/*RuntimeError stops the execution of the program when it encounters invalid operations duringn the running of the program */
func RuntimeError(message string) ButterError {
	ReportError("RUNTIME_ERROR: " + message)
	hadRuntimeError = true
	return ButterError{}
}
