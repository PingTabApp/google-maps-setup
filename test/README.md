# setup.sh test suite

Runs `setup.sh` end to end with no Google account and no PingTab backend, by putting a
fake `gcloud` first on `PATH` and pointing `--api` at a local stand-in for the two public
endpoints. Every case asserts an exit status plus one or two things about what the script
printed or, more usefully, what it actually called.

```bash
./test/run.sh              # every case, about 35 seconds
./test/run.sh billing      # only cases whose name contains "billing"
```

One line per case, a summary at the end, non-zero exit if anything failed.

## Files

| File | Purpose |
| --- | --- |
| `run.sh` | The runner: starts the servers it needs, runs the cases, asserts, reports |
| `bin/gcloud` | The fake gcloud. Its `SHIM_*` knobs are documented in its header |
| `fakeapi.py` | The fake PingTab API. Its response modes are documented in its docstring |

Nothing is written into the repository. State lives in a `mktemp -d` directory under
`$TMPDIR` (the runner refuses a `TMPDIR` that resolves inside the repo) and is removed by
an exit trap, which also kills and reaps the API servers. Each server binds port 0 and
writes its port to a file the runner waits on, so there is no port race; a server that
does not come up aborts the whole run with its log. The runner works from any working
directory.

## What it covers

- **Code mode**: happy path, idempotent re-run, a lowercased and space-padded code, an
  organization with no egress IPs (browser key only), and a server key Google refuses.
- **Fallbacks**: the GET returning 404, an unreachable API, and six shapes of POST failure
  including three that return 200 with a body we cannot trust. Each asserts the keys are
  printed for manual pasting, because the keys exist in the customer's project by then and
  losing them is the one unacceptable outcome.
- **Manual mode**: both keys, and referrers only.
- **Project resolution**: config, environment fallback, `--project`, one project, several,
  a failed `projects list` (which must not be read as zero projects), and zero projects
  with no terminal to ask.
- **Prompts**: create a project (yes, no, create fails, cannot select afterwards, and the
  generated id is a legal Google project id), and link a billing account (one account yes
  and no, several with a pick then a confirm, a pick then a decline, `02` meaning 2, an out
  of range pick, and a link that fails).
- **Enable**: the single retry after a brand new project, and the rule that a link is only
  offered when Google's own error names billing.
- **Dry run**: code mode, manual mode, and with prompts. These assert zero mutating gcloud
  calls and zero POSTs, which is the whole point of the flag.
- **Guards**: a missing value for each flag, no arguments, an unknown flag, code and manual
  flags together, three placeholders, a non-https `--api`, and three malformed codes.

## Adding a case

```bash
if wanted "billing account is closed"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=False SHIM_ACCOUNTS=)
  CASE_ANSWERS='y\n'                     # only if the case reaches a prompt
  run_case "billing account is closed" "${CODE[@]}"
  expect_status 1
  expect_out "No script can create a billing account for you"
  expect_calls 0 "billing projects link"
  check "billing account is closed"
fi
```

`CASE_ENV` and `CASE_ANSWERS` are consumed and cleared by `run_case`, so set them
immediately before it. The assertions available are `expect_status`, `expect_out`,
`expect_not_out`, `expect_calls <count> <pattern>`, `expect_posts <count> <api mode>`,
`expect_post_body <api mode> <fragment>`, `expect_no_bad_posts <api mode>`, `expect_keys`
and `expect_no_keys`. The fake API enforces the POST contract (path, JSON, key shape)
and answers 422 with a `BAD POST` log line when it is broken, and the fake gcloud
refuses a mutating call missing the flags the real one requires, so a lenient double
cannot pass a script the real services would reject. Wrap the case in `if wanted "<name>"`
so the filter argument works, and end it with `check "<name>"`.

Two things worth knowing before you extend this:

- **`expect_out` is `grep -F` on one line.** Messages in `setup.sh` are wrapped heredocs, so
  a phrase that reads as one sentence may be split across two lines. Assert on a fragment
  that fits on a single line.
- **Prefer `expect_calls` over `expect_out`.** What the script printed is a courtesy; what
  it called is the behaviour. Almost every real bug found here showed up as a call that
  happened, or failed to happen, rather than as wrong wording.

If a case needs a gcloud subcommand the shim does not know, the shim exits 64 with
`unhandled gcloud invocation`, which fails the case loudly rather than passing by accident.
Add the subcommand to `bin/gcloud` with a knob for its failure mode.

## Prompt cases need a terminal

`setup.sh` only asks a question when `[[ -t 0 ]]`, and there is deliberately no environment
override for that: nothing should be able to talk the script into believing a pipe is a
person. So prompt cases run under `script -qfec ... /dev/null`, which gives the child a
real pseudo-terminal. Where `script` is not installed those cases report `SKIP` with the
reason and the rest of the suite still runs.
