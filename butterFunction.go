package main

import (
	"fmt"
)

//this actually implements the object interface

type TypedArg struct {
	Type Token
	name Token
}

type ButterFunction struct {
	function FuncStmt
	env      Env
}

func (b ButterFunction) Type() ObjType {
	return FUNCTIONOBJ
}

func (b ButterFunction) Call(i Interpreter, args []Object) Object {
	if len(args) != len(b.function.params) {
		return RuntimeError(fmt.Sprintf("incorrect number of arguments to function '%s'. received %d, expected %d", b.function.name.literal, len(args), len(b.function.params)))
	}
	env := NewEnvironment(&b.env)
	for index, arg := range args {
		name := b.function.params[index].name.literal
		paramType := b.function.params[index].Type.Type.String()
		if paramType != string(arg.Type()) {
			return RuntimeError(fmt.Sprintf("parameter '%s' type '%s', expected '%s' in  function '%s'", name, string(arg.Type()), paramType, b.function.name.literal))
		}
		env.define(name, arg)
	}
	interpreter.executeBlock(b.function.body, env)
	temp := returnedValue
	returnedValue = nil //reset this value for the next function to use
	return temp
}
