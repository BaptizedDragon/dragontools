// Local stdlib template harness. Only the two used Alertmanager v0.34.1
// functions are mirrored, verbatim in behavior. No notifier or network access.
// The same snapshots also run against pinned amtool with --amtool.
package main

import (
	"bytes"
	"encoding/json"
	"html/template"
	"os"
	"regexp"
	"strings"
	"time"
)

type Alert struct {
	Status              string
	Labels, Annotations map[string]string
	StartsAt, EndsAt    time.Time
}
type Alerts []Alert

func (alerts Alerts) Firing() (result Alerts) {
	for _, a := range alerts {
		if a.Status == "firing" {
			result = append(result, a)
		}
	}
	return
}
func (alerts Alerts) Resolved() (result Alerts) {
	for _, a := range alerts {
		if a.Status == "resolved" {
			result = append(result, a)
		}
	}
	return
}

type Data struct {
	Status string
	Alerts Alerts
}

func main() {
	functions := template.FuncMap{
		"toUpper": strings.ToUpper,
		"reReplaceAll": func(pattern, repl, text string) string {
			return regexp.MustCompile(pattern).ReplaceAllString(text, repl)
		},
	}
	t := template.Must(template.New("telegram").Option("missingkey=zero").Funcs(functions).ParseFiles(os.Args[1]))
	var input []Data
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}
	output := []string{}
	for _, data := range input {
		var buffer bytes.Buffer
		if err := t.ExecuteTemplate(&buffer, "dragontools.telegram.message", data); err != nil {
			panic(err)
		}
		output = append(output, buffer.String())
	}
	if err := json.NewEncoder(os.Stdout).Encode(output); err != nil {
		panic(err)
	}
}
