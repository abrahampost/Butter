package main

import (
	"fmt"
	"io/ioutil"
	"os"
)

/*Settings struct Contains the settings for the current interpreter */
type Settings struct {
	fromFile bool
	fileLoc  string
}

/*Parse the command line to initialize settings variables */
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

/*RunFile Reads file into biffer and then runs it */
func RunFile(s Settings) {
	input, err := ioutil.ReadFile(s.fileLoc)
	CheckError(err)
	tokenizer := NewTokenizer()
	tokenizer.Tokenize(string(input))
	for lineNo, token := range tokenizer.tokens {
		fmt.Printf("Token num: %d; %v\n", lineNo, token)
	}
}

/*CheckError checks to see if an error has been reported from a function */
func CheckError(err error) {
	if err != nil {
		ParseError(-1, err.Error())
	}
}

/*ParseError Reports an error during the initial tokenization of the */
func ParseError(line int, message string) {
	var lineMessage string
	if line != -1 {
		lineMessage = fmt.Sprintf(" [line %d]", line)
	}
	errorMessage := fmt.Sprintf("PARSE_ERROR%s: %s", lineMessage, message)
	ReportError(errorMessage)
}

/*ReportError stops execution of the program with a panic reporting the message argument */
func ReportError(message string) {
	panic(message)
}
