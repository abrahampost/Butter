package main

import (
	"fmt"
)

//this actually implements the object interface

type TypedArg struct {
	Type Token
	name Token
}

type Callable interface {
	Call(i Interpreter, args []Object) Object
	Arity() int
}

type ButterFunction struct {
	function FuncStmt
	env      *Env
}

func (b ButterFunction) Type() ObjType {
	return FUNCTIONOBJ
}

func (b ButterFunction) Arity() int {
	return len(b.function.params)
}

func (b ButterFunction) Call(i Interpreter, args []Object) Object {
	env := NewEnvironment(b.env)
	for index, arg := range args {
		name := b.function.params[index].name.literal
		paramType := b.function.params[index].Type.Type.String()
		if paramType != string(arg.Type()) && !(paramType == "LAMBDA" && arg.Type() == FUNCTIONOBJ) {
			//if the types aren't equal, and the mismatch isn't caused by lambda and function being different
			return RuntimeError(fmt.Sprintf("parameter '%s' type '%s', expected '%s' in  function '%s'", name, string(arg.Type()), paramType, b.function.name.literal))
		}
		env.define(name, arg)
	}
	interpreter.executeBlock(b.function.body, env)
	temp := returnedValue
	returnedValue = nil //reset this value for the next function to use
	if b.function.returnType.Type == VOID {
		if temp != nil {
			return RuntimeError("Void function '" + b.function.name.literal + "'returns non-nil value")
		}
		return NIL
	} else if temp.Type() == FUNCTIONOBJ && b.function.returnType.Type == LAMBDA {
		//special case since lambda's are still just functions
		return temp
	} else if string(temp.Type()) != b.function.returnType.Type.String() {
		return RuntimeError(fmt.Sprintf("function returned type '%s', expected '%s'", string(temp.Type()), b.function.returnType.Type))
	}
	return temp
}
