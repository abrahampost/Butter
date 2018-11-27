package main

import "fmt"

/*PrintTokens prints all parsed tokens for debugging purposes */
func PrintTokens(ts []Token) {
	for _, tok := range ts {
		fmt.Println(tok)
	}
}
