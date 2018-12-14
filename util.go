package main

import "fmt"

/*PrintTokens prints all parsed tokens for debugging purposes */
func PrintTokens(ts []Token) {
	for _, tok := range ts {
		PrintToken(tok)
	}
}

func PrintToken(tok Token) {
	fmt.Printf("Token: %s; literal -> %s; line -> %d\n", tok.Type, tok.literal, tok.line)
}
