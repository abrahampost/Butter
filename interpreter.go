package main

import (
	"fmt"
	"strconv"
)

type Interpreter struct {

}

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

func (i *Interpreter) Evaluate(e Expr) Object {
	return e.Accept(i)
}

func (i *Interpreter) visitPrint(p Print) Object {
	result := i.Evaluate(p.expr)
	fmt.Println(Stringify(result))
	return Nil{}
}

func (i *Interpreter) visitGrouping(g Grouping) Object {
	return i.Evaluate(g.expr)
}

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
	RuntimeError("Mismatched operands: '" + leftObj.Type() + "' and '" + rightObj.Type() + "'")
	return Nil{}
}

func (i *Interpreter) visitLiteral(l Literal) Object {
	return l.obj
}



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
	case EQUAL_EQUAL:
		return Boolean{left.Value == right.Value}
	case BANG_EQUAL:
		return Boolean{left.Value != right.Value}
	case GREATER:
		return Boolean{left.Value > right.Value}
	case GREATER_EQUAL:
		return Boolean{left.Value >= right.Value}
	case LESS_EQUAL:
		return Boolean{left.Value <= right.Value}
	default:
		RuntimeError("Unsupported operation on values of type 'INTEGER'")
		return Nil{}
	}
}

func EvaluateBoolean(left Boolean, right Boolean, operator Token) Object {
	switch operator.Type {
	case AND:
		return Boolean{left.Value && right.Value}
	case OR:
		return Boolean{left.Value || right.Value}
	default:
		RuntimeError("Unsupported operation on values of type 'BOOLEAN'")
		return Nil{}
	}
}

func Stringify(o Object) string {
	switch t := o.(type) {
	case Integer:
		return strconv.Itoa(t.Value)
	case Boolean:
		if t.Value {
			return "TRUE"
		}
		return "FALSE"
	default:
		return "(nil)"
	}
}

func CheckNumberOperands(left Object, right Object) (Integer, Integer, bool) {
	leftInt, lOK := left.(Integer)
	rightInt, rOK := right.(Integer)
	return leftInt, rightInt, lOK && rOK
}

func CheckBoolOperands(left Object, right Object) (Boolean, Boolean, bool) {
	leftBool, lOK := left.(Boolean)
	rightBool, rOK := right.(Boolean)
	return leftBool, rightBool, lOK && rOK
}