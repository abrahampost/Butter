package main

import (
	"fmt"
)

/*Env is an environment object where variables can be defined */
type Env struct {
	parent *Env
	values map[string]Object
}

/*NewEnvironment creates a new environment and initializes the array */
func NewEnvironment(parent *Env) Env {
	return Env{
		parent: parent,
		values: make(map[string]Object),
	}
}

func (e *Env) SetParent(parent *Env) {
	e.parent = parent
}

func (e *Env) define(varName string, value Object) {
	_, exists := e.values[varName]
	if exists {
		RuntimeError("Variable '" + varName + "' already initialized in this scope")
	} else {
		e.values[varName] = value
	}
}

func (e *Env) assign(varName string, value Object) {
	if found, ok := e.values[varName]; ok {
		if value.Type() != found.Type() {
			RuntimeError(fmt.Sprintf("Cannot assign %s to %s type", string(value.Type()), string(found.Type())))
		}
		e.values[varName] = value
	} else if e.parent != nil {
		e.parent.assign(varName, value)
	} else {
		RuntimeError("Attempting to assign to undefined variable")
	}
}

func (e *Env) get(varName string) Object {
	if result, ok := e.values[varName]; ok {
		return result
	} else if e.parent != nil {
		return e.parent.get(varName)
	}

	return RuntimeError("Undefined variable: '" + varName + "'")
}
