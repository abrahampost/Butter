package main

/*ObjType provides an enum-like definition of objects */
type ObjType string

const (
	INTEGEROBJ ObjType = "int"
	FLOATOBJ   ObjType = "float"
	BOOLEANOBJ ObjType = "bool"
	STRINGOBJ  ObjType = "string"
	NILOBJ     ObjType = "(nil)"
)

/*Object defines a common object interface which all variable types will implement */
type Object interface {
	Type() ObjType
}

/*Integer is an object implementation containing only an int value */
type Integer struct {
	Value int
}

/*Type returns a string representation of the integer object's type */
func (i Integer) Type() ObjType {
	return INTEGEROBJ
}

/*Float is an object implementation containting a float value */
type Float struct {
	Value float64
}

/*Type returns a string representation of the float object's type */
func (f Float) Type() ObjType {
	return FLOATOBJ
}

/*Boolean is on object implementaiton only containing a bool value */
type Boolean struct {
	Value bool
}

/*Type returns a string representation of the boolean object's type */
func (b Boolean) Type() ObjType {
	return BOOLEANOBJ
}

/*String is an object implementation of a string */
type String struct {
	Value string
}

/*Type returns a string representation of the string object's type*/
func (s String) Type() ObjType {
	return STRINGOBJ
}

/*Nil is an object representation containing no value */
type Nil struct {
}

/*Type returns a string representation of the Nil object type */
func (n Nil) Type() ObjType {
	return NILOBJ
}

/*NIL is a singleton which all nil objects will reference */
var NIL Nil
