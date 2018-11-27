package main

import (
	"fmt"
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
func (i *Interpreter) Interpret(exprs []Expr, repl bool) {
	for _, expr := range exprs {
		//TODO: Check return value to see if error object has been sent
		val := i.Evaluate(expr)
		if repl {
			switch val.(type) {
			case Nil:
				continue
			default:
				fmt.Println(Stringify(val))
			}
		}
	}
}

/*Evaluate calls the accept method on the Expr, making sure it is passed to the correct method
  back on the interpreter for evaluation */
func (i *Interpreter) Evaluate(e Expr) Object {
	return e.Accept(i)
}

/*visitAssign visits an assignment operation and then saves it to the environment variable */
func (i *Interpreter) visitAssign(a Assign) Object {
	result := i.Evaluate(a.initializer)
	i.env.define(a.identifier.literal, result)
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
	leftInt, rightInt, isNum := CheckNumberOperands(leftObj, rightObj)
	if isNum {
		return EvaluateNum(leftInt, rightInt, b.operator)
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

/*visitLiteral return sthe underlying object value of a literal */
func (i *Interpreter) visitLiteral(l Literal) Object {
	return l.obj
}

/*EvaluateNum returns an object based on the operation between two integers*/
func EvaluateNum(left Integer, right Integer, operator Token) Object {
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
	case MULT:
		if left.Value == 0 || right.Value == 0 {
			return Integer{0}
		}
		return Integer{left.Value * right.Value}
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
		RuntimeError("Unsupported operation on values of type 'INTEGER'")
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
func CheckNumberOperands(left Object, right Object) (Integer, Integer, bool) {
	leftInt, lOK := left.(Integer)
	rightInt, rOK := right.(Integer)
	return leftInt, rightInt, lOK && rOK
}

/*CheckBoolOperands returns a tuple with the values and a positive bool if the objects are both Booleans */
func CheckBoolOperands(left Object, right Object) (Boolean, Boolean, bool) {
	leftBool, lOK := left.(Boolean)
	rightBool, rOK := right.(Boolean)
	return leftBool, rightBool, lOK && rOK
}
