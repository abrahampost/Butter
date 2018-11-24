package main

import (
	"fmt"
	"io/ioutil"
	"os"
	"bufio"
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

var interpreter Interpreter

func main() {
	settings := Settings{false, ""}
	settings.Parse()

	if settings.fromFile {
		RunFile(settings)
	} else {
		RunPrompt()
	}
}

/*RunFile Reads file into biffer and then runs it */
func RunFile(s Settings) {
	inputBytes, err := ioutil.ReadFile(s.fileLoc)
	CheckError(err)
	inputString := string(inputBytes) + "\r\n"
	Run(inputString)
}

func RunPrompt() {
	reader := bufio.NewReader(os.Stdin)
	for true {
		fmt.Print("> ")
		input, _ := reader.ReadString('\n')
		Run(input)
	}
}

func Run(source string) {
	tokenizer := NewTokenizer(source)
	tokenizer.Tokenize()
	parser := NewParser(tokenizer.tokens)
	exprs := parser.Parse()
	interpreter.Interpret(exprs)
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

func RuntimeError(message string) {
	ReportError("RUNTIME_ERROR: " + message)
}

/*ReportError stops execution of the program with a panic reporting the message argument */
func ReportError(message string) {
	fmt.Fprintf(os.Stderr, message + "\n")
	os.Exit(1)
}