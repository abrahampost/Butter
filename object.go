package main

/*ObjType provides an enum-like definition of objects */
type ObjType string

const (
	integerObj ObjType = "Integer"
	booleanOBJ ObjType = "Boolean"
	nilOBJ     ObjType = "Nil"
)

/*Object defines a common object interface which all variable types will implement */
type Object interface {
	Type() string
}

/*Integer is an object implementation containing only an int value */
type Integer struct {
	Value int
}

/*Type returns a string representation of the integer object's type */
func (i Integer) Type() string {
	return string(integerObj)
}

/*Boolean is on object implementaiton only containing a bool value */
type Boolean struct {
	Value bool
}

/*Type returns a string representation of the boolean object's type */
func (b Boolean) Type() string {
	return string(booleanOBJ)
}

/*Nil is an object representation containing no value */
type Nil struct {
}

/*Type returns a string representation of the Nil object type */
func (n Nil) Type() string {
	return string(nilOBJ)
}
