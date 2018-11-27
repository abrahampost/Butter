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

func (e *Env) get(varName string) Object {
	result, ok := e.values[varName]
	if !ok {
		RuntimeError("Undefined variable: '" + varName + "'")
	}
	return result
}
