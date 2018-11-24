package main

type ObjType string

const (
	INTEGER_OBJ ObjType = "Integer"
	NIL
)

type Object interface {
	Type() string
}

type Integer struct {
	Value int
}

func (i Integer) Type() string {
	return string(INTEGER_OBJ)
}

func (i Integer) Add(j Integer) Object {
	return Integer{i.Value + j.Value}
}

func (i Integer) Sub(j Integer) Object {
	return Integer{i.Value - j.Value}
}

func (i Integer) Mult(j Integer) Object {
	return Integer{i.Value * j.Value}
}

func (i Integer) Div(j Integer) Object {
	return Integer{i.Value / j.Value}
}

type Nil struct {
}

func (n Nil) Type() string {
	return "(nil)"
}