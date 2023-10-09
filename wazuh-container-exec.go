package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path"
	"sync"
)

var listenPath = getEnvOrDef("WAZUH_AGENT_CONTAINER_EXEC_LISTEN_PATH", path.Join(os.Getenv("WAZUH_AGENT_HOST_DIR"), "/var/ossec/container-exec.sock"))
var connectPath = getEnvOrDef("WAZUH_AGENT_CONTAINER_EXEC_CONNECT_PATH", "/var/ossec/container-exec.sock")
var logFile = getEnvOrDef("WAZUH_AGENT_CONTAINER_EXEC_LOG_FILE", "/var/ossec/logs/active-responses.log")

func getEnvOrDef(name, def string) string {
	v, ok := os.LookupEnv(name)
	if !ok {
		return def
	}
	return v
}

func client() {
	conn, err := net.Dial("unix", connectPath)
	if err != nil {
		panic(err)
	}
	defer conn.Close()

	stdout := os.Stdout
	if logFile != "" {
		stdout, err = os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
		if err != nil {
			panic(err)
		}
		defer stdout.Close()
	}

	var wg sync.WaitGroup
	wg.Add(2)
	defer wg.Wait()
	go func() {
		defer wg.Done()
		if _, err := io.Copy(conn, os.Stdin); err != nil {
			panic(err)
		}
		conn.Write([]byte{0, '\n'})
	}()
	go func() {
		defer wg.Done()
		if _, err := io.Copy(stdout, conn); err != nil {
			panic(err)
		}
	}()
}

type activeResponseArgs struct {
	Parameters struct {
		ExtraArgs []string `json:"extra_args"`
	} `json:"parameters"`
}

func server() {
	listener, err := net.Listen("unix", listenPath)
	if err != nil {
		panic(err)
	}
	defer listener.Close()

	for {
		conn, err := listener.Accept()
		if err != nil {
			fmt.Printf("Error accepting connection: %v\n", err)
			continue
		}

		go func(conn net.Conn) {
			defer conn.Close()

			r := bufio.NewReader(conn)
			line, err := r.ReadBytes('\n')
			if err != nil {
				conn.Write([]byte(err.Error()))
				return
			}

			var args []string
			ar := &activeResponseArgs{}
			if err := json.Unmarshal(line, ar); err == nil {
				args = ar.Parameters.ExtraArgs
			} else {
				args = []string{"bash"}
			}

			if len(args) == 0 {
				conn.Write([]byte("no arguments specified"))
				return
			}

			cmd := exec.Command(args[0], args[1:]...)
			stdin, err := cmd.StdinPipe()
			if err != nil {
				conn.Write([]byte(err.Error()))
				return
			}
			stdout, err := cmd.StdoutPipe()
			if err != nil {
				conn.Write([]byte(err.Error()))
				return
			}
			stderr, err := cmd.StderrPipe()
			if err != nil {
				conn.Write([]byte(err.Error()))
				return
			}

			var wg sync.WaitGroup
			wg.Add(3)
			defer wg.Wait()
			go func() {
				defer wg.Done()
				defer stdin.Close()
				for len(line) > 1 && !(len(line) == 2 || line[0] == 0) {
					_, err := io.WriteString(stdin, string(line))
					if err != nil {
						conn.Write([]byte(err.Error()))
						return
					}
					line, err = r.ReadBytes('\n')
					if err != nil {
						conn.Write([]byte(err.Error()))
						return
					}
				}
			}()
			go func() {
				defer wg.Done()
				defer stdout.Close()
				if _, err := io.Copy(conn, stdout); err != nil {
					fmt.Println("error reading stdout", err)
				}
			}()
			go func() {
				defer wg.Done()
				defer stderr.Close()
				if _, err := io.Copy(conn, stderr); err != nil {
					fmt.Println("error reading stderr", err)
				}
			}()

			if err := cmd.Run(); err != nil {
				fmt.Println("command error", err)
				conn.Write([]byte(err.Error()))
			}
		}(conn)
	}
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "server" {
		server()
		return
	}

	client()
}