package main

import (
	"io/ioutil"
	"os"
)

//Contains the settings for the current interpreter
type Settings struct {
	fromFile bool
	fileLoc  string
}

//Parses the command line to initialize settings variables
func (s *Settings) Parse() {
	if len(os.Args) > 1 {
		s.fromFile = true
		s.fileLoc = os.Args[1]
	}
}

func main() {
	settings := Settings{false, ""}
	settings.Parse()

	if settings.fromFile {
		RunFile(settings)
	}
}

func RunFile(s Settings) {
	input, err := ioutil.ReadFile(s.fileLoc)
	CheckError(err)
	tokenizer := NewTokenizer()
	tokenizer.Tokenize(string(input))
}

func CheckError(err error) {
	if err != nil {
		CompileError(err.Error())
	}
}

func CompileError(message string) {
	panic("ERROR: " + message)
}
