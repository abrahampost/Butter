# Butter

Goal is to implement a toy programming language in Go

## Current features
* Can evaluate arbitrary arithmetic expressions
* String literals, integers, floats, booleans
* Boolean logic implemented
* Print statements
* Assignment
  * \<type> \<name> := \<value>
 * functions
  * ```  
        fn <name>(<arg>(, <arg>)*): <ret type> => { 
            stmt* 
        }
    ```


Lots of features and improvements coming in the next few weeks.

## Things coming soon
* Flow control
* More complex data types (currently only has bool and integer
* Unit tests

# To use
* Make sure you have go installed
* `make`
* `./Butter [file_name]`
  * If no file name provided will start REPL

### Make targets and variables

The following variables are override-able at the command line, like
`BINARY=myprog make`

- `BINARY`: controls the name of the output binary
  - default: `Butter`
- `GO`: the `go` executable to use
  - default: `go`
- `PKGS`: the packages to act on
  - default: `./...`

The following targets are provided:

- `all`: the default target; builds the binary
  - accepts `GOBUILDFLAGS` to control build
- `install`: installs the binary via `go install` (may not respect `BINARY`
  variable)
  - accepts `GOBUILDFLAGS` to control build
- `clean`: cleans build artifacts
  - accepts `GOCLEANFLAGS` to control clean
- `clean_uninstall`: cleans build artifacts and uninstalls the binary
  - accepts `GOCLEANFLAGS` to control clean
- `fmt`: format the code via `go fmt`
  - accepts `GOFMTFLAGS` to control `fmt`
- `vet`: vet the code via `go vet`
  - accepts `GOVETFLAGS` to control `vet`
- `check`: run tests via `go test`
  - accepts `GOTESTFLAGS` to control `test`
  - provides the following "defaults":
```
test-bench:   GOTESTFLAGS=-run=__absolutelynothing__ -bench=.
test-short:   GOTESTFLAGS=-short
test-verbose: GOTESTFLAGS=-v
test-race:    GOTESTFLAGS=-race
```
