package main

import (
	"fmt"
	"strconv"
)

type Interpreter struct {

}

func (i *Interpreter) Interpret(exprs []Expr) {
	for _, expr := range exprs {
		//TODO: Check return value to see if error object has been sent
		i.Evaluate(expr) 
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
			return leftInt.Add(rightInt)
		case MINUS:
			return leftInt.Sub(rightInt)
		case DIV:
			if rightInt.Value == 0 {
				RuntimeError("Divide by zero error")
			}
			return leftInt.Div(rightInt)
		case MULT:
			return leftInt.Mult(rightInt)
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
	default:
		return "(nil)"
	}
}