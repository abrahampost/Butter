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
	leftInt, lOK := leftObj.(Integer)
	rightInt, rOK := rightObj.(Integer)
	if lOK && rOK {
		switch b.operator.Type {
		case PLUS:
			return Integer{leftInt.Value + rightInt.Value}
		case MINUS:
			return Integer{leftInt.Value - rightInt.Value}
		case DIV:
			if rightInt.Value == 0 {
				RuntimeError("Divide by zero error")
			} else if leftInt.Value == 0 {
				return Integer{0}
			}
			return Integer{leftInt.Value / rightInt.Value}
		case MULT:
			if leftInt.Value == 0 || rightInt.Value == 0 {
				return Integer{0}
			}
			return Integer{leftInt.Value * rightInt.Value}
		case EQUAL_EQUAL:
			return Boolean{leftInt.Value == rightInt.Value}
		case BANG_EQUAL:
			return Boolean{leftInt.Value != rightInt.Value}
		case GREATER:
			return Boolean{leftInt.Value > rightInt.Value}
		case GREATER_EQUAL:
			return Boolean{leftInt.Value >= rightInt.Value}
		case LESS_EQUAL:
			return Boolean{leftInt.Value <= rightInt.Value}
		}
	}
	return Nil{}
}

func (i *Interpreter) visitLiteral(l Literal) Object {
	return l.obj
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