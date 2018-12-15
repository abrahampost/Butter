package main

import (
	"time"
)

type Clock struct{}

func (c Clock) Call(i Interpreter, args []Object) Object {
	return Integer{int(time.Now().UnixNano())}
}

func (c Clock) Arity() int {
	return 0
}

func (c Clock) Type() ObjType {
	return NATIVEFNOBJ
}

var NilFunction ButterFunction
