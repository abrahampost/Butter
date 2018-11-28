package main

/*Env is an environment object where variables can be defined */
type Env struct {
	values map[string]Object
}

/*NewEnvironment creates a new environment and initializes the array */
func NewEnvironment() Env {
	env := Env{}
	env.values = make(map[string]Object)
	return env
}

func (e *Env) define(varName string, value Object) {
	e.values[varName] = value
}

func (e *Env) assign(varName string, value Object) {
	if found, ok := e.values[varName]; ok {
		switch value.(type) {
		case Integer:
			_, ok := found.(Integer)
			if !ok {
				RuntimeError("Cannot assign value to int type")
			}
		case Float:
			_, ok := found.(Float)
			if !ok {
				RuntimeError("Cannot assign value to float type")
			}
		case Boolean:
			_, ok := found.(Boolean)
			if !ok {
				RuntimeError("Cannot assign value to bool type")
			}
		case String:
			_, ok := found.(String)
			if !ok {
				RuntimeError("Cannot assign value to string type")
			}
		}
		e.values[varName] = value
	} else {
		RuntimeError("Attempting to assign to undefined variable")
	}
}

func (e *Env) get(varName string) Object {
	result, ok := e.values[varName]
	if !ok {
		RuntimeError("Undefined variable: '" + varName + "'")
	}
	return result
}
