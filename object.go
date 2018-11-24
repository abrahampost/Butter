package main

type ObjType string

const (
	INTEGER_OBJ ObjType = "Integer"
	BOOLEAN_OBJ ObjType = "Boolean"
	NIL_OBJ ObjType = "Nil"
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

type Boolean struct {
	Value bool
}

func (b Boolean) Type() string {
	return string(BOOLEAN_OBJ)
}

type Nil struct {
}

func (n Nil) Type() string {
	return string(NIL_OBJ)
}