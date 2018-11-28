package main

import (
	"fmt"
	"math"
	"strconv"
)

/*The Interpreter struct which merely holds a bunch of methods */
type Interpreter struct {
	env Env
}

/*NewInterpreter returns a new Interpreter object with a properly initialized environment */
func NewInterpreter() Interpreter {
	i := Interpreter{}
	i.env = NewEnvironment()
	return i
}

/*Interpret takes a list of parsed AST expressions and evaluates them */
func (i *Interpreter) Interpret(stmts []Stmt, repl bool) {
	for _, stmt := range stmts {
		i.Execute(stmt)
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
	i.Evaluate(e.expr)
}
func (i *Interpreter) visitVarDeclaration(vd VarDeclaration) {
	val := i.Evaluate(vd.initializer)
	CheckVarType(vd.tokenType, val)
	i.env.define(vd.identifier.literal, val)
	// switch vd.tokenType.Type {
	// case INTTYPE:
	// 	if _, ok := val.(Integer); !ok {
	// 		RuntimeError("TypeError -> cannot assign value to int type")
	// 	}
	// 	i.env.define(vd.identifier.literal, val)
	// case FLOATTYPE:
	// 	if _, ok := val.(Float); !ok {
	// 		RuntimeError("TypeError -> cannot assign value to float type")
	// 	}
	// 	i.env.define(vd.identifier.literal, val)
	// case BOOLTYPE:
	// 	if _, ok := val.(Boolean); !ok {
	// 		RuntimeError("TypeError -> cannot assign value to bool type")
	// 	}
	// 	i.env.define(vd.identifier.literal, val)
	// case STRINGTYPE:
	// 	if _, ok := val.(String); !ok {
	// 		RuntimeError("TypeError -> cannot assign value to string type")
	// 	}
	// default:
	// 	RuntimeError("TypeError -> Unknown assignment type")
	// }
}
func (i *Interpreter) visitErrorStmt(e ErrorStmt) {
	fmt.Println(e.message)
}

/*visitAssign visits an assignment operation and then saves it to the environment variable */
func (i *Interpreter) visitAssign(a Assign) Object {
	val := i.Evaluate(a.initializer)
	i.env.assign(a.identifier.literal, val)
	return NIL
}

/*visitVariable looks up a variable in the environment and returns it */
func (i *Interpreter) visitVariable(v Variable) Object {
	return i.env.get(v.identifier.literal)
}

/*visitPrint evaluates the expr contained within a print object and then prints that */
func (i *Interpreter) visitPrint(p Print) Object {
	result := i.Evaluate(p.expr)
	fmt.Println(Stringify(result))
	return NIL
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
		lFloat, lIsFloat := leftObj.(Float)
		rFloat, rIsFloat := rightObj.(Float)
		//if either is a float, figure out which is a float and then cast to floats
		if lIsFloat || rIsFloat {
			if !lIsFloat {
				leftInt := leftObj.(Integer)
				lFloat = Float{float64(leftInt.Value)}
			}
			if !rIsFloat {
				rightInt := rightObj.(Integer)
				rFloat = Float{float64(rightInt.Value)}
			}
			return EvaluateFloat(lFloat, rFloat, b.operator)
		} else {
			//If neither are floats, they must be integers and should use integer math
			lInteger := leftObj.(Integer)
			rInteger := rightObj.(Integer)
			return EvaluateInt(lInteger, rInteger, b.operator)
		}
	}
	leftBool, rightBool, isBool := CheckBoolOperands(leftObj, rightObj)
	if isBool {
		return EvaluateBoolean(leftBool, rightBool, b.operator)
	}
	if leftString, ok := leftObj.(String); ok {
		switch b.operator.Type {
		case PLUS:
			return String{leftString.Value + Stringify(rightObj)}
		default:
			RuntimeError("string does not support '" + b.operator.Type.String() + "' operator")
		}
	}
	RuntimeError("Mismatched operands: '" + leftObj.Type() + "' and '" + rightObj.Type() + "'")
	return NIL
}

func (i *Interpreter) visitUnary(u Unary) Object {
	result := i.Evaluate(u.right)

	switch u.operator.Type {
	case BANG:
		if val, ok := result.(Boolean); ok {
			return Boolean{!val.Value}
		}
		RuntimeError("Cannot negate non-boolean object")
	case MINUS:
		if val, ok := result.(Integer); ok {
			return Integer{-val.Value}
		}
		if val, ok := result.(Float); ok {
			return Float{-val.Value}
		}
		RuntimeError("Cannot have negative non-number type")
	}
	return NIL
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
			RuntimeError("Divide by zero error")
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
	case LESSEQUAL:
		return Boolean{left.Value <= right.Value}
	default:
		RuntimeError(fmt.Sprintf("Unsupported operation (%s) on values of type 'FLOAT'", operator.Type.String()))
		return NIL
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
			RuntimeError("Divide by zero error")
		} else if left.Value == 0 {
			return Integer{0}
		}
		return Integer{left.Value / right.Value}
	case MOD:
		if right.Value == 0 {
			RuntimeError("Module by zero error")
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
	case LESSEQUAL:
		return Boolean{left.Value <= right.Value}
	default:
		RuntimeError(fmt.Sprintf("Unsupported operation (%s) on values of type 'INTEGER'", operator.Type.String()))
		return NIL
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
		RuntimeError("Unsupported operation on values of type 'BOOLEAN'")
		return NIL
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
	_, lInt := left.(Integer)
	_, rInt := right.(Integer)
	_, lFloat := left.(Float)
	_, rFloat := right.(Float)
	return (lInt || lFloat) && (rInt || rFloat)
}

/*CheckBoolOperands returns a tuple with the values and a positive bool if the objects are both Booleans */
func CheckBoolOperands(left Object, right Object) (Boolean, Boolean, bool) {
	leftBool, lOK := left.(Boolean)
	rightBool, rOK := right.(Boolean)
	return leftBool, rightBool, lOK && rOK
}

func CheckVarType(varType Token, val Object) bool {
	switch varType.Type {
	case INTTYPE:
		if _, ok := val.(Integer); !ok {
			RuntimeError("TypeError -> cannot assign value to int type")
		}
		return true
	case FLOATTYPE:
		if _, ok := val.(Float); !ok {
			RuntimeError("TypeError -> cannot assign value to float type")
		}
		return true
	case BOOLTYPE:
		if _, ok := val.(Boolean); !ok {
			RuntimeError("TypeError -> cannot assign value to bool type")
		}
		return true
	case STRINGTYPE:
		if _, ok := val.(String); !ok {
			RuntimeError("TypeError -> cannot assign value to string type")
		}
		return true
	default:
		RuntimeError("TypeError -> Unknown assignment type")
	}
	return false
}
