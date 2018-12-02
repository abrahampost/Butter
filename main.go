package main

import (
	"bufio"
	"fmt"
	"io/ioutil"
	"os"
)

var VERSION string = "0.1"

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

	interpreter = NewInterpreter()

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
	Run(inputString, false)
}

/*RunPrompt runs the REPL and feeds input to the run method as it comes in  */
func RunPrompt() {
	fmt.Printf("Butterv%s (repl)\n", VERSION)
	reader := bufio.NewReader(os.Stdin)
	input := ""
	for true {
		if len(input) == 0 {
			//if the input has been cleared since the last run
			fmt.Print("> ")
		} else {
			//if we are in a block, match the indentation of above
			fmt.Print("  ")
		}
		in, _ := reader.ReadString('\n')
		input += in //concatenate the new input onto the previous input
		if len(in)-2 == 0 || MatchingBraces(input) {
			//if the newline is empty, or all the braces have been matched up run the input
			Run(input, true)
			input = "" //reset the input for the next run
		}
	}
}

/*Run sends the input to the tokenizer and interpreter, evaluating the input string as it comes in*/
func Run(source string, repl bool) {
	tokenizer := NewTokenizer(source)
	tokens := tokenizer.Tokenize()
	parser := NewParser(tokens)
	stmts := parser.Parse()
	interpreter.Interpret(stmts, repl)
}

func MatchingBraces(input string) bool {
	left_brace := 0
	right_brace := 0
	inQuotes := false
	for _, b := range input {
		if b == '"' {
			inQuotes = !inQuotes
		}
		if !inQuotes {
			//if the brackets are in quotes, ignore them
			if b == '{' {
				left_brace++
			}
			if b == '}' {
				right_brace++
				if right_brace > left_brace {
					//if a right brace has been seen without a left brace coming before it
					ParseError(-1, "'}' found without matching '{'")
				}
			}
		}
	}
	return left_brace == right_brace
}

/*CheckError checks to see if an error has been reported from a function */
func CheckError(err error) {
	if err != nil {
		ParseError(-1, err.Error())
	}
}

/*ParseError Reports an error during the initial tokenization and parsing of the input */
func ParseError(line int, message string) {
	var lineMessage string
	if line != -1 {
		lineMessage = fmt.Sprintf(" [line %d]", line)
	}
	errorMessage := fmt.Sprintf("PARSE_ERROR%s: %s", lineMessage, message)
	ReportError(errorMessage)
}

/*RuntimeError stops the execution of the program when it encounters invalid operations duringn the running of the program */
func RuntimeError(message string) {
	ReportError("RUNTIME_ERROR: " + message)
}

/*ReportError stops execution of the program with a panic-like error message */
func ReportError(message string) {
	fmt.Fprintf(os.Stderr, message+"\n")
	os.Exit(1)
}
