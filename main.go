package main

import (
	"fmt"
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

	fmt.Println()
}
