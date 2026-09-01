# tasksd-client.nvim

A Neovim client for [tasksd](https://github.com/kuznetsss/tasksd), a daemon that
spawns and supervises processes on your behalf.

Neovim's own `:terminal` and `jobstart()` tie a running command to the editor:
close Neovim and the command goes with it. tasksd holds the process instead. It
runs the task in its own supervision tree, captures the output into a ring
buffer, and speaks a small streaming JSON-RPC API over a unix socket. This
plugin is the Neovim side of that conversation — it starts the daemon when one
is not running, keeps a single connection to it, and gives you commands to
start tasks, watch their output, signal them, and feed their stdin.

What that buys you in practice:

- **Tasks outlive the editor.** Start a dev server, quit Neovim, come back, and
  `:Tasksd list_tasks` still shows it running with its output intact.
- **Output is streamed, not polled.** The daemon pushes `task.output`
  notifications; a window subscribes while it is open and unsubscribes when you
  close it, so nothing is sent that nobody is reading.
- **One daemon, many editors — or not.** Which daemon a Neovim instance talks
  to is a single config option, from one global daemon down to one per project
  or per instance.

> [!WARNING]
> Both tasksd and this client are under development. The API may change, and so
> may this plugin's options.

## Requirements

- **Neovim 0.12 or newer.** The plugin is tested on the latest stable Neovim release.
  It may work with an older Neovim but not guaranteed.
- **Linux or macOS.** tasksd talks over a unix socket; Windows is not
  supported.
- **A tasksd binary**, version `0.2.0` or newer. `:Tasksd install` can fetch or
  build one for you — see [Installing the daemon](#installing-the-daemon).

Optional:

- [snacks.nvim](https://github.com/folke/snacks.nvim) — used automatically for
  the task and signal pickers when present. Without it, everything falls back
  to `vim.ui.select`.
- [blink.cmp](https://github.com/Saghen/blink.cmp) — used automatically for
  completion inside the start-task form. Without it, `<C-x><C-u>` still
  completes.

## Installation

The plugin registers `:Tasksd` from `plugin/tasksd.lua` at startup and loads
everything else lazily on first use, so `setup()` is optional: leaving it out
gets you the defaults.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "kuznetsss/tasksd-client.nvim",
  cmd = "Tasksd",
  ---@module "tasksd"
  opts = {
    -- see Configuration below; {} is a fine starting point
  },
}
```

With [mini.deps](https://github.com/nvim-mini/mini.nvim):

```lua
local add = MiniDeps.add
add("kuznetsss/tasksd-client.nvim")
require("tasksd").setup({})
```

Any other manager works the same way: put the directory on the `runtimepath`
and, if you want to change anything, call `require("tasksd").setup(opts)`.

### Installing the daemon

The plugin does not ship the daemon. Run:

```vim
:Tasksd install
```

This obtains the exact tasksd release this client is pinned to (see
`lua/tasksd/install/pin.lua`) and puts it in
`stdpath("data")/tasksd/bin/tasksd` — deliberately outside the plugin
directory, so updating the plugin does not wipe it.

Three methods are available, and `:Tasksd install <method>` picks one
explicitly:

| Method   | What it does | Needs |
| -------- | ------------ | ----- |
| `auto`   | Tries `github` first, falls back to `cargo`. The default. | — |
| `github` | Downloads the prebuilt release archive and verifies it against a digest pinned in this repo. | `curl`, `tar`, and `sha256sum` or `shasum` |
| `cargo`  | Builds from source at the pinned revision, into the plugin's own `--root` so it never shadows a tasksd you manage yourself. | a Rust toolchain |

Prebuilt binaries currently exist for Linux `x86_64` and `aarch64` only, so on
macOS `auto` falls through to the source build.

`:Tasksd install` refuses to do anything when a usable tasksd is already
reachable — including one you supplied through `daemon.path`. `:Tasksd!
install` (with the bang) installs over it anyway.

Already have a tasksd? Point at it and skip the install entirely:

```lua
require("tasksd").setup({ daemon = { path = "~/.cargo/bin/tasksd" } })
```

### Checking the setup

```vim
:checkhealth tasksd
```

reports which binary would be launched and where it came from (`daemon.path`,
installed by this plugin, or found on `$PATH`), whether its version satisfies
the client's minimum, and which socket path this Neovim resolves to.

## Usage

Everything is one command with subcommands, and every subcommand completes:

```vim
:Tasksd <Tab>
```

| Command | Purpose |
| ------- | ------- |
| `:Tasksd start_task` | Open a form and start a task |
| `:Tasksd output [task_id=<id>] [position=<where>]` | Show or hide a task's output |
| `:Tasksd list_tasks [all\|running\|finished]` | Browse tasks, open the chosen one's output |
| `:Tasksd send_signal [task_id=<id>] [signal=<name\|number>]` | Signal a task |
| `:Tasksd send_input [task_id=<id>] [input=<text>]` | Write a line to a task's stdin |
| `:Tasksd install [auto\|github\|cargo]` | Obtain a tasksd binary |
| `:Tasksd shutdown` | Stop the daemon |

You never have to start the daemon yourself. The first subcommand that needs it
probes the socket, launches tasksd if nothing answers, waits for it to bind,
completes the handshake, and then does what you asked.

### Starting a task

```vim
:Tasksd start_task
```

opens a small floating form:

```
┌───────────────────────── Start task ─────────────────────────┐
│ Command:                    cargo test                       │
│ Working directory:          ~/src/myproject                  │
│ Show output:                [x]                              │
│ Shell (autoshell enabled):  [ ]                              │
└──────────────────────────────────────────────────────────────┘
```

- **Command** — an executable and its arguments, split on whitespace. Unless a
  shell is involved (below) quoting is not honoured, so globs and pipes are not
  interpreted and an argument containing a space cannot be expressed.
- **Working directory** — prefilled with Neovim's current directory. A relative
  path is resolved against Neovim's cwd before being sent, because the daemon
  would otherwise resolve it against *its* cwd, which is wherever it happened
  to be launched from.
- **Show output** — whether to open the output window immediately. Ticking it
  subscribes as part of the start request, which is what guarantees you see the
  task's very first lines; subscribing after the fact starts from wherever the
  output has already got to.
- **Shell** — run the command as `sh -c '<command>'` instead of spawning it
  directly. Ticking the box forces that; with **autoshell** on, a command
  containing anything in `shell.syntax` — `&&` by default — gets a shell of its
  own accord, which is why the label says whether autoshell is armed. `sh`
  rather than `$SHELL`: the daemon is what spawns it, and an interactive
  shell's rc files can change what the command means.

Keys inside the form (all configurable):

| Key | Action |
| --- | ------ |
| `<Tab>` / `<S-Tab>` | Next / previous field, wrapping around |
| `<Space>` | Tick or untick a toggle field; ordinary space on a text field |
| `<CR>` | Submit |
| `<Esc>` | Cancel (normal mode — in insert mode `<Esc>` stays `<Esc>`) |
| `<C-x><C-u>` | Complete the field under the cursor |

Completion is field-aware: the first word of **Command** completes as an
executable on `$PATH`, the rest as file paths, and **Working directory**
completes as a directory. With blink.cmp installed the same candidates appear
in blink's menu as you type, through a source registered for the form's
filetype only (`form.blink = false` turns that off).

The form is an ordinary editable buffer, so normal-mode editing works. Deleting
or adding lines is repaired automatically — the shape is restored, though text
that moved between fields is not.

When the task exits you get a notification saying how it ended, whichever
window you are in.

### Watching output

```vim
:Tasksd output              " toggle: reopen the last task, or hide the window
:Tasksd output task_id=3    " show task 3
:Tasksd output position=float
:Tasksd! output             " put the window back where the config says
```

With no arguments this toggles the window, reopening whichever task it last
showed. If it has never shown one, it asks with the task picker.

The window is a single, reusable panel:

- **It remembers where you put it.** Move or resize it and the next open
  reproduces that placement. `:Tasksd! output` discards it and falls back to
  `output.position` / `output.size`.
- **A `position=` moves rather than closes.** Saying where the window goes is
  not the same as saying whether it is open, so `:Tasksd output position=right`
  on an open window relocates it.
- **Closing it ends the subscription.** The window's lifetime *is* the
  subscription's: closing sends `task.unsubscribe` and drops the buffer, so the
  daemon stops sending output nobody is looking at.
- **It follows the tail unless you scroll.** New lines move the cursor to the
  bottom only if it was already there. `output.autoscroll = false` turns the
  following off entirely.
- **It is bounded.** `output.max_lines` rows are kept; older ones fall off the
  top.

The buffer is a scratch buffer named `tasksd://task/<id>` with filetype
`tasksd-output`, which is what to key your own highlights or autocommands on.

Two placeholder lines can appear in it. Output is addressed by the line number
the daemon assigned, not by where the text happens to sit, so a gap can be
reserved and filled in later:

- `<loading output>` — the daemon reported dropped lines (its own buffer
  overflowed while it could not send fast enough); the real text is being
  fetched.
- `<output lost>` — the daemon could no longer supply those lines. Its buffer
  is bounded too, so a gap reported late may already be past recall.

A final `[task 3 finished]` / `[task 3 exited with code 1]` /
`[task 3 was killed by signal 15]` line records how the task ended.

Asking for a task that has already exited still opens the window; it says so
rather than showing output, since a finished task has nothing to subscribe to.

### Listing tasks

```vim
:Tasksd list_tasks
:Tasksd list_tasks running
:Tasksd list_tasks finished
```

opens a picker of the daemon's tasks — id, state, command line, working
directory — with running tasks first and the most recently started at the top
of each group. Choosing one opens its output.

The listing is **daemon-wide**: it includes tasks started by other Neovim
instances that share the same socket, and tasks started before this Neovim
existed. That is the point of a daemon. If you would rather each editor see
only its own, use `daemon.socket = "nvim_instance"` — at the cost of the tasks
disappearing with it.

An empty result is reported as a message rather than an empty picker, so
"nothing matched" never looks like "nothing answered".

### Signalling a task

```vim
:Tasksd send_signal                          " pick a task, then a signal
:Tasksd send_signal task_id=3                " defaults to TERM
:Tasksd send_signal task_id=3 signal=KILL
:Tasksd send_signal task_id=3 signal=9
:Tasksd send_signal signal=INT               " pick which task, send SIGINT
```

Arguments are `key=value` so order never matters and either question can be
answered in advance. Whichever you leave out becomes a picker.

Signal names are accepted with or without the `SIG` prefix, in any case, or as
a raw number. The names and numbers come from this machine's own
`vim.uv.constants`, which is also how the daemon numbers them — the two always
share a kernel, since they talk over a unix socket. (The numbers are *not*
portable: `SIGUSR1` is 30 on macOS and 10 on Linux.)

Only running tasks are offered, and `TERM` is listed first so `<CR>` on an
untouched picker does the common thing.

### Sending input

```vim
:Tasksd send_input                                " pick a task, then type
:Tasksd send_input task_id=3                      " type the input
:Tasksd send_input task_id=3 input=yes
```

A newline is appended unless the text already ends in one — a task blocked on
`read_line` stays blocked until a line ends. A deliberate `input=` with nothing
after it therefore sends a bare newline.

`input=` takes everything to the end of the command line, so it can contain
spaces; runs of whitespace collapse to one, because the command line arrives
already split. When exact text matters, leave `input=` off and type it at the
`vim.ui.input` prompt instead.

Only running tasks are offered — the daemon rejects input to a finished one.

### Shutting the daemon down

```vim
:Tasksd shutdown
```

asks tasksd to terminate every task and disconnect every client. This is **not
scoped to your Neovim**: if the socket is shared, it takes down everyone's
tasks, whoever started them.

## Configuration

Call `setup()` with anything you want to change; it is deep-merged over the
defaults, so partial tables are fine. A list — `shell.syntax` — replaces the
default rather than merging into it. Here is the whole default table:

```lua
require("tasksd").setup({
  daemon = {
    -- Path to a tasksd binary of your own. Empty means: use the one this
    -- plugin installed, else whatever `tasksd` is on $PATH.
    path = "",
    thread_number = 2,
    task_buffer_size = 10000, -- lines the daemon keeps per task
    graceful_period = 5,      -- seconds a task gets to exit before it is killed
    log_file = nil,           -- absolute path; a detached daemon has no console
    socket = "project",       -- which daemon to talk to; see below
    detached = true,          -- survive this Neovim exiting
  },
  form = {
    blink = true,             -- register a blink.cmp source for the form
    keys = {
      next_field = "<Tab>",
      prev_field = "<S-Tab>",
      toggle = "<Space>",
      submit = "<CR>",
      cancel = "<Esc>",
    },
  },
  shell = {
    auto = true,              -- run a command containing `syntax` through a shell
    syntax = { "&&" },        -- substrings that mean a command needs one
  },
  output = {
    position = "bottom",      -- 'left'|'right'|'top'|'bottom'|'float'
    size = "30%",             -- count of lines/columns, or a percentage
    max_lines = 10000,        -- rows kept in the output buffer
    autoscroll = true,        -- follow new output when the cursor is on the last line
    show_on_start = true,     -- whether the form's "Show output" starts ticked
  },
  picker = "auto",            -- 'auto'|'snacks'|'select'|function(spec)
  install = {
    method = "auto",          -- 'auto'|'github'|'cargo'
  },
})
```

### `daemon.socket` — which daemon you talk to

A unix socket is just a file, so "one daemon per X" is entirely a question of
how X maps to a path: two Neovims that compute the same path share a daemon,
two that compute different paths each get their own. Sockets live under
`stdpath("state")/tasksd/`.

| Value | Meaning |
| ----- | ------- |
| `"global"` | One daemon for every Neovim instance, and the one that makes tasks visible everywhere. |
| `"nvim_instance"` | One daemon per Neovim process. Gives up the main reason tasksd detaches tasks: the next Neovim addresses a different daemon and never sees them again. |
| `"pwd"` | One daemon per working directory, literally — `nvim` started in `~/p/src` addresses a different daemon than one started in `~/p`. |
| `"project"` | One daemon per version control root (`.git`, `.jj`, `.hg`, `.svn`) above the working directory, falling back to `pwd` when there is no root. The default. |
| `function(): string` | Any scheme you like — per git worktree, per tmux session. It owns the path completely, including creating the directory. |

Both directory-based schemes use Neovim's *global* cwd, not the window's, so
`:lcd` does not silently move you to another daemon. Changing daemons mid-session
(a `:cd` under `project`, say) drops the live connection along with its
subscriptions, which is why the answer is deliberately insensitive to `:lcd`.

Socket paths are length-checked at 104 bytes — the kernel copies the path into
a fixed buffer and would otherwise bind to a silently truncated name.

```lua
-- a daemon per git worktree
require("tasksd").setup({
  daemon = {
    socket = function()
      local dir = vim.fs.joinpath(vim.fn.stdpath("state"), "tasksd")
      vim.fn.mkdir(dir, "p")
      local root = vim.fs.root(vim.fn.getcwd(-1), ".git") or vim.fn.getcwd(-1)
      return vim.fs.joinpath(dir, vim.fn.sha256(root):sub(1, 12) .. ".sock")
    end,
  },
})
```

### `daemon.detached`

`true` (the default) launches tasksd detached, so it — and every task it holds
— survives Neovim exiting. Setting it to `false` ties the daemon's lifetime to
this Neovim, which is occasionally what you want in a test or a throwaway
session.

### `output.position` and `output.size`

`size` is a count of lines or columns (`20`), or a percentage of the editor
(`"30%"`). A split uses only the dimension its position implies — a `bottom`
panel takes a height and the editor's full width. A float uses both, and can be
given them separately:

```lua
output = { position = "float", size = { width = "80%", height = 20 } }
```

These are the *defaults* for the window. Once you have moved or resized it, the
remembered placement wins until `:Tasksd! output` resets it.

### `picker`

| Value | Meaning |
| ----- | ------- |
| `"auto"` | snacks.nvim if it is installed and its picker is enabled, otherwise `vim.ui.select`. The default. |
| `"snacks"` | Require snacks.nvim; error if it is missing. |
| `"select"` | Always `vim.ui.select`, so `dressing.nvim`, `mini.pick`'s `ui_select`, fzf-lua's, or the built-in prompt handle it. |
| `function(spec)` | Open your own. |

A custom picker receives `{ title, items, on_choice }`, where each item is
`{ value, text, chunks }` — `text` is the whole laid-out, column-aligned line
(also what a fuzzy matcher should see), and `chunks` is the same line as
`{ text, hl }` pieces for backends that can colour. Call `on_choice(item.value)`
with the chosen item's value, and nothing at all if the user cancels.

### `form.keys`

Each entry is an `{lhs}`; an empty string leaves that action unmapped. The
mappings are buffer-local to the form.

```lua
form = { keys = { next_field = "<C-n>", prev_field = "<C-p>", cancel = "" } }
```

## Highlights

Everything the plugin draws goes through a `Tasksd*` highlight group, each
linked by default to a group your colorscheme already defines:

| Group | Default | Where |
| ----- | ------- | ----- |
| `TasksdNormal` | `Normal` | Output panel, when it is a split |
| `TasksdNormalFloat` | `NormalFloat` | Output panel and start-task form, when floating |
| `TasksdBorder` | `FloatBorder` | Border of either float |
| `TasksdTitle` | `FloatTitle` | Title in that border |
| `TasksdFormLabel` | `Title` | Field labels in the form |
| `TasksdFormToggleOn` | `DiagnosticOk` | A ticked `[x]` box |
| `TasksdFormToggleOff` | `Comment` | An empty `[ ]` box |
| `TasksdTaskId` | `Number` | Task id in a picker |
| `TasksdTaskRunning` | `DiagnosticOk` | State of a running task |
| `TasksdTaskFinished` | `Comment` | State of a finished task |
| `TasksdTaskCommand` | *(none)* | The command line in a picker |
| `TasksdTaskDir` | `Directory` | The working directory in a picker |
| `TasksdOutputNote` | `Comment` | A `[...]` line the plugin wrote into the output |
| `TasksdOutputExit` | `DiagnosticOk` | `[task 7 finished]` |
| `TasksdOutputExitFailed` | `DiagnosticError` | A non-zero exit or a signal |
| `TasksdOutputLoading` | `Comment` | `<loading output>`, a gap being fetched |
| `TasksdOutputLost` | `DiagnosticWarn` | `<output lost>`, a gap past recall |

A task's own output is never highlighted — it is the task's text, and this
plugin has no business colouring it.

Define any of these yourself and the plugin leaves it alone; the links above are
set with `default`, so yours wins, whether it comes from your config or from a
colorscheme:

```lua
vim.api.nvim_set_hl(0, "TasksdOutputExitFailed", { fg = "#ff5f5f", bold = true })
vim.api.nvim_set_hl(0, "TasksdTaskDir", { link = "Comment" })
```

## How it works

Worth knowing when something goes wrong:

- **Layers.** `socket.lua` answers *which* daemon; `daemon.lua` makes sure
  something is listening there, launching one if not; `client.lua` owns the
  JSON-RPC connection and the handshake. Nothing below the command layer
  notifies you directly — failures come back as strings and the command decides
  what to say.
- **One connection per Neovim.** Every command shares it, and so do all the
  subscriptions on it. It is dropped and remade only if `daemon.socket` starts
  resolving somewhere else.
- **Version checks happen twice.** Before launch, so a too-old binary is
  reported with the reason it was chosen (`daemon.path`, installed, `$PATH`)
  instead of silently taking the socket; and at the handshake, which is the
  only check that covers a daemon somebody else started.
- **Stale sockets are cleaned up.** tasksd binds without unlinking, so a file
  left by a hard-killed daemon is probed, found dead, and removed before the
  next launch.

## Development

The devshell is Nix (`flake.nix` + direnv); the task runner is `just`:

```
just fix     # stylua, then selene + lua-language-server
just test    # the mini.test suite
just nvim    # Neovim with only this plugin on the runtimepath
```

Integration tests need a real tasksd binary and skip themselves without one;
`TASKSD_BIN` points at it.

## Roadmap

`0.1.0`:
- [x] binary download install method
- [x] add cargo to nix
- [x] connect path and install method
- [x] verify that client starts tasksd when it is not running
- [x] commands:
    - [x] start task
    - [x] send signal
    - [x] send input
    - [x] list of tasks
- [x] picker integration
- [x] output buffer
- [x] Readme file
- [x] Highlights
- [x] Remove references to the local build
- [x] Auto shell (use `sh -c` if `&&` or any other shell syntax is detected)
- [ ] Repeatable named tasks
- [ ] Check available lua api
- [ ] Documentation
- [ ] CI

Other features:
- [ ] Output buffer slots

Requires tasksd 0.3.0:
- [ ] Preview of a task in picker
- [ ] Task info in the output window
