package main

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
	env := NewEnvironment(&b.env)
	for index, arg := range args {
		env.define(b.function.params[index].name.literal, arg)
	}
	interpreter.executeBlock(b.function.body, env)
	temp := returnedValue
	returnedValue = nil //reset this value for the next function to use
	return temp
}
