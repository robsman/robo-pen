# Claude Container: A Complete Beginner's Guide

## Table of Contents

- [What Is This and Why Should I Care?](#what-is-this-and-why-should-i-care)
- [Key Concepts (Plain English)](#key-concepts-plain-english)
- [What You Need Before Starting](#what-you-need-before-starting)
- [Installation: Step by Step](#installation-step-by-step)
- [Your First Project](#your-first-project)
- [Working With Claude Inside the Container](#working-with-claude-inside-the-container)
- [Managing Your Containers](#managing-your-containers)
- [Moving Files In and Out](#moving-files-in-and-out)
- [Use Cases for Academic Research](#use-cases-for-academic-research)
- [Recipes Reference](#recipes-reference)
- [Troubleshooting](#troubleshooting)
- [Glossary](#glossary)

---

## What Is This and Why Should I Care?

Claude Code is an AI assistant that can read, write, and run code directly on your computer. It is incredibly powerful — it can install software, create files, run scripts, and modify your system. That power is also what makes it risky. If you ask Claude to "clean up my project" and it misunderstands, it could delete files you care about. If a script goes wrong, it could affect other things on your machine.

**Claude Container solves this problem.** It gives Claude its own isolated computer (a "container") to work in. Claude gets full, unrestricted access inside that container — it can install anything, run anything, break anything — and none of it touches your real computer. Your project files are shared between the container and your computer through a single folder, so you always have access to the work Claude produces.

Think of it like giving Claude its own office with a desk, tools, and a copy machine. Claude can make a mess in that office all day long, and your office stays clean. The copy machine (the shared folder) lets you exchange documents back and forth.

---

## Key Concepts (Plain English)

### The Terminal

The terminal (also called "command line" or "shell") is a text-based way to talk to your computer. Instead of clicking icons, you type commands. On a Mac, you can open it by pressing `Cmd + Space`, typing "Terminal", and pressing Enter.

When you see instructions like this:

```bash
just build
```

That means: open your terminal, type `just build`, and press Enter.

### Apple Container and Containers

A **container** is like a lightweight virtual computer running inside your real computer. It has its own operating system (Linux), its own installed programs, and its own files. But unlike a full **virtual machine** (a complete simulated computer, which is heavy and slow to start), a container starts in seconds and uses very little memory.

**Apple Container** is Apple's native containerization tool for macOS. It creates and runs Linux containers directly, using Apple's virtualization framework. It is OCI-compatible (it works with the same standard image format used by Docker and other container tools) and it reads regular `Dockerfile`s — so the same blueprint that builds an image for Docker also builds an image for Apple Container.

The key difference from Docker on a Mac: Docker traditionally runs **one shared Linux VM** that hosts all your containers. Apple Container instead runs **one lightweight Linux VM per container**. Each container gets its own tiny VM, which boots in a fraction of a second. This means stronger isolation between containers and no single heavyweight VM hogging resources in the background.

You don't need to learn the `container` CLI directly — this project wraps everything in simple `just` commands for you.

### Justfile and `just`

A **Justfile** is like a recipe book for your terminal. Instead of remembering long, complicated commands, you type short ones like `just build` or `just claude`. The Justfile translates these into the real commands behind the scenes.

**`just`** is the program that reads the Justfile and runs the recipes. It's similar to `make` if you've heard of that, but simpler.

In day-to-day use you'll invoke recipes through the **`rp`** wrapper rather than calling `just` directly — `rp` lets you run recipes from any folder and treats your current directory as the project root.

### Bind Mounts (The Shared Folder)

This tool uses a **cwd-anchored** model: the folder you are currently `cd`'d into when you run `rp` becomes the container's `/workspace`. Any file you put in either location instantly appears in the other.

For example, if you `cd ~/my-research-project` and run `rp claude`, the folder `~/my-research-project` on your Mac is mounted as `/workspace` inside the container. There is no separate "projects" directory you have to copy your work into — you just `cd` to any existing folder on your Mac and start working.

This is how your work survives even if the container is destroyed. The container is disposable; your project folder on your Mac is permanent.

**Collision safety.** Each container records the host folder it was created from in a label (`rp.host_path=...`). When you run `rp claude` or `rp shell`, the tool checks that the container's recorded path matches your current working directory. If they don't match, it aborts with a clear error and suggests using an explicit name (see below) — this prevents you from accidentally opening a container that was built around a different folder.

**Explicit names.** By default the container is named after the current folder (e.g., `cd ~/my-project && rp claude` creates `claude-my-project`). You can override this by passing a name explicitly: `rp claude my-custom-name`. Use explicit names when you want multiple containers per folder, or when two different folders happen to share a basename.

### YOLO Mode

Claude Code normally asks your permission before doing anything significant — "Can I create this file? Can I run this command?" This is safe but slow, especially for complex tasks.

**YOLO mode** (`--dangerously-skip-permissions`) tells Claude to just do it without asking. Inside a container, this is safe because Claude can't affect your real computer. It makes Claude dramatically faster and more autonomous for complex tasks.

### Authentication: Subscription vs API Key

There are two ways to use Claude Code:

1. **Claude subscription** (Pro or Max plan at [claude.ai](https://claude.ai)) — You log in once per container with `rp login` (run from the project folder). Claude Code usage is included in your subscription. This is the simplest option.

2. **API key** — You get a key from [console.anthropic.com](https://console.anthropic.com/) and put it in a `.env` file. Usage is billed per conversation. The key looks something like `sk-ant-abc123...`.

**You only need one of these.** If you have a Claude Pro or Max subscription, you don't need an API key at all.

---

## What You Need Before Starting

1. **A Mac with Apple Silicon** (M1 or newer) running **macOS 26 or later**. Apple Container requires Apple Silicon and a recent macOS release; Intel Macs are not supported.
2. **Homebrew** — a package manager for Mac. If you don't have it, open Terminal and paste:
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```
   Follow the prompts. This may take a few minutes.
3. **just** — install it with Homebrew:
   ```bash
   brew install just
   ```
4. **jq** — a small JSON parser used by the Justfile to detect container state. `just setup` installs it for you, but if you skip `just setup` you'll need it manually:
   ```bash
   brew install jq
   ```
5. **A Claude subscription or API key** — either a [Claude Pro/Max subscription](https://claude.ai) or an [Anthropic API key](https://console.anthropic.com/) (Settings > API Keys). You only need one.

---

## Installation: Step by Step

### Step 1: Download this project

Open Terminal and run:

```bash
git clone https://github.com/YOUR_USERNAME/robo-pen.git
cd robo-pen
```

Replace `YOUR_USERNAME` with the actual GitHub username or organization where this repository (repo) is hosted.

> **Note:** If this is your first time using `git` on a Mac, you may see a pop-up asking to install "Xcode Command Line Tools." Click "Install" and wait for it to finish (this can take 5-10 minutes), then run the commands above again.
>
> **Alternative if you don't want to use git:** Download the project as a ZIP file from the GitHub page (look for a green "Code" button, then "Download ZIP"), unzip it, and open Terminal in that folder.

You are now "inside" the project folder. The setup and build commands below are run from here, but day-to-day work uses `rp` from any folder on your Mac (see the next tip).

### Install `rp` (recommended)

The repo includes a small script called `rp` (Claude Container Runner) that lets you run any recipe from any folder. This is the recommended way to use the tool — the cwd-anchored workflow described later in this guide depends on it.

```bash
# Copy the script to a folder on your PATH
cp rp ~/bin/rp       # or /usr/local/bin/rp
chmod +x ~/bin/rp
```

If you cloned this repo somewhere other than `~/repos/robo-pen`, tell `rp` where to find it by adding this line to your `~/.zshrc`:

```bash
export ROBO_PEN_DIR="$HOME/path/to/robo-pen"
```

Then, from any folder on your system:

```bash
rp claude              # Use the current folder as /workspace
rp shell               # Open a shell, mounting the current folder
rp list                # Show all claude containers
rp --recipes           # Show all available recipes
```

Under the hood, `rp` just calls `just` with your current directory preserved, so `rp claude` is equivalent to `just claude` run from the same folder. Examples in the rest of this guide use `rp`; you can substitute `just` (from inside the `robo-pen` directory) if you prefer.

### Step 2: Set up authentication

You have two options depending on how you pay for Claude. **Pick one:**

#### Option A: Claude subscription (Pro/Max) — recommended

No setup needed at this step. You'll log in from your first project folder later (see [Your First Project](#your-first-project)). Skip ahead to Step 3.

#### Option B: API key

```bash
cp .env.example .env
```

The `cp` command means "copy." This creates a new file called `.env` by copying the example template.

> **Note about dotfiles:** Files whose names start with a `.` (like `.env`) are "hidden files" on macOS. You won't see them in Finder by default. In Terminal, use `ls -a` (list all) to see them. In Finder, press `Cmd+Shift+.` to toggle hidden file visibility.

Now open `.env` in a text editor. You can use any editor you like, or use `nano` in the terminal:

```bash
nano .env
```

This opens a simple text editor in your terminal. Use the arrow keys to navigate. Change the `ANTHROPIC_API_KEY=` line to include your key:

```
ANTHROPIC_API_KEY=sk-ant-your-actual-key-here
```

Then press `Ctrl+O` (the letter O) to save, press Enter to confirm, and `Ctrl+X` to exit.

This file is private — it's listed in `.gitignore` (a special file that tells git "never upload these files"), so it will never be accidentally shared even if you publish your project.

### Step 3: Install Apple Container and the container image

```bash
rp setup
```

**What this does:**
1. Installs Apple Container via Homebrew (the `container` formula) — a single command-line tool, no daemon to manage
2. Installs `jq` (used by the Justfile to parse container state)
3. Starts the Apple Container service in the background, ready to launch per-container Linux VMs on demand
4. Pulls the pre-built container images (~one-time download) — no separate build step needed

The container image is a snapshot of a Linux system with the basics pre-installed. It's deliberately minimal and language-agnostic:

- git, curl, and build tools (build-essential)
- Claude Code CLI (installed by the agent profile, not the base image)

No language runtime (Python, Node, R, ...) is preinstalled — add what your project needs via `.rp/config.yaml`. If you want the old Node + Python/uv + R + DuckDB + just combo back, see `.rp.example/Dockerfile.full-toolchain`.

This step typically takes 1-2 minutes the first time on a fast internet connection. When your terminal prompt returns, Apple Container is ready.

**If you see a message that the service is already running**, that's fine — it means you've done this before.

**Building from source instead:** if you cloned the repo rather than installing via Homebrew, or want to change `Dockerfile`/`Dockerfile.base` yourself, run `RP_BUILD_FROM_SOURCE=1 rp setup` instead — this builds both images locally (~15 min) rather than pulling them.

---

## Your First Project

The typical flow is: `cd` to a folder you want to work in, then run `rp claude`. The container is created automatically on first use, and the folder you're in becomes the container's `/workspace`.

### Go to (or create) a project folder

Pick any folder on your Mac that you want Claude to work in. It can be an existing repo, a fresh empty folder, or anything in between:

```bash
# Option A: use an existing project you already have
cd ~/research/my-existing-project

# Option B: make a new empty folder anywhere on your Mac
mkdir -p ~/research/my-first-project
cd ~/research/my-first-project
```

### Log in (subscription users only)

If you use a Claude Pro or Max subscription, log in once per container:

```bash
rp login
```

**What this does:** Auto-creates a container for the current folder (if one doesn't already exist), then runs `claude login` inside it. It will display a URL — open that URL in your browser, sign in with your Claude account, and the container will be authenticated. You only need to do this once per container (it survives stop/start, but not destroy/create).

The container is named after the current folder. For example, if you ran the command from `~/research/my-first-project`, the container is called `claude-my-first-project`.

API key users can skip this step — your key was already configured via `.env`.

### Start Claude

```bash
rp claude
```

**What this does:**
1. Auto-creates the container if it doesn't exist yet (mounting the current folder as `/workspace`)
2. Starts the container (if it isn't already running)
3. Opens Claude Code inside the container in YOLO mode
4. You now have an interactive conversation with Claude, and Claude has full access to the container

You'll see Claude's interface appear. You can type requests like:

- "Create a Python script that analyzes a CSV file"
- "Set up a new R project with tidyverse"
- "Build me a simple web dashboard"

When you're done, press `Ctrl+C` or type `/exit` to leave Claude. The container stays running.

### Verify your files are shared

Any files Claude creates in `/workspace` appear in your current folder on your Mac, and vice versa. From the same folder, try:

```bash
ls
```

The `ls` command means "list" — it shows the files in the current folder. You'll see whatever Claude created.

### Open a plain shell (no Claude)

From the same project folder:

```bash
rp shell
```

This gives you a regular Linux command line inside the container, with your folder mounted at `/workspace`. You can explore, run scripts, install packages, or do anything you'd do on a Linux machine. Type `exit` to leave.

### Using an explicit name

If you want a second container for the same folder (say, one for experiments and one for "real" work), or two different folders happen to share the same basename, pass an explicit name:

```bash
rp claude experiments
rp claude real-work
```

The folder you're in is still what gets mounted — only the container's name changes.

---

## Working With Claude Inside the Container

All examples below assume you are `cd`'d into the project folder you want Claude to work in.

### YOLO Mode vs Safe Mode

You have two ways to run Claude:

| Command | Mode | When to Use |
|---------|------|-------------|
| `rp claude` | YOLO | Day-to-day work. Claude acts autonomously. |
| `rp claude-safe` | Safe | When you want to approve each action Claude takes. |

YOLO mode is the default and recommended mode inside containers. Since the container is isolated, there's no risk to your real computer.

### Giving Claude a specific task

You can pass a prompt directly:

```bash
cd ~/research/my-project
rp claude "Read the CSV files in this directory and create summary statistics"
```

Or start an interactive session (no prompt) and type your request:

```bash
rp claude
```

### What Claude can do inside the container

Claude has access to everything a regular Linux user would, scoped to whatever your project's image provides:

- **Read and write files** in `/workspace` (your shared project folder)
- **Run shell scripts**, plus whatever language runtimes your image includes (Python, R, Node.js, ...)
- **Install packages** with whatever package manager the runtime provides (`uv pip install pandas`, `npm install express`, ...) — once that runtime is present
- **Use git** to manage version control
- **Access the internet** to download data or packages

**No `sudo`.** The container user has no privilege-escalation path by design (that's the security boundary — see ADR-0005). System-level packages (a new apt package, a language runtime) have to be baked in at image-build time via `.rp/config.yaml`'s `image:`/`build:`, not installed ad hoc mid-session. If a project genuinely needs that ergonomic (e.g. adopting a devcontainer image's conventions), `allow_sudo: true` opts back in and accepts the weaker boundary — see ADR-0018.

---

## Managing Your Containers

Most of these recipes default to "the container for the current folder" — so `cd` to the project folder first, then run them. You can also pass an explicit container name if you prefer (e.g., `rp stop my-project`).

### Day-to-day workflow

```bash
# Go to your project folder
cd ~/research/my-project

# Start your work session (auto-creates and auto-starts the container)
rp claude

# ... work with Claude ...

# When done for the day, stop the container to free resources
rp stop

# Next day, just run claude again from the same folder — it auto-starts
cd ~/research/my-project
rp claude
```

### See all your containers

```bash
rp list
```

This shows every claude container, whether it's running or stopped, along with the host folder each one is bound to.

### Stop a container (pause it)

```bash
rp stop                # the container for the current folder
rp stop my-project     # or by explicit name
```

Everything on disk is preserved — installed packages, configuration files, and any files Claude created. It just stops using CPU and memory. Note: any scripts or processes that were actively running will be terminated and would need to be restarted.

### Start it again

```bash
rp start
```

Or just run `rp claude` or `rp shell` from the project folder — they auto-start.

### Restart (if something is stuck)

```bash
rp restart
```

### Destroy a container (delete the virtual machine, keep your files)

```bash
rp destroy
```

This removes the container entirely. Any packages Claude installed, any configuration changes inside the container — gone. **But your project files on your Mac are safe.** They live on your Mac, not inside the container.

You can recreate the container anytime — just `cd` back into the folder and run `rp claude`. The container is auto-created on first use:

```bash
cd ~/research/my-project
rp claude
```

Claude will need to reinstall any packages it needs, but your files are all still there.

### Check resource usage

```bash
rp stats
```

Shows CPU and memory usage for all running containers. Useful if your Mac feels sluggish.

### View container logs

```bash
rp logs
```

Shows the internal log output from the container. Mostly useful for debugging.

---

## Moving Files In and Out

### The easy way: the shared folder

The folder you were `cd`'d into when the container was created is automatically `/workspace` inside the container, and vice versa. For most workflows, this is all you need:

- Drop a CSV into `data/` in your project folder on your Mac, and Claude can read it at `/workspace/data/`
- Claude creates a report at `/workspace/output/report.pdf`, and you'll find it at `output/report.pdf` in your project folder

### Copying files to/from other locations in the container

Sometimes you need to move files to/from places other than `/workspace` (for example, a config file in `/home/coder/`). From the project folder:

```bash
# Copy a file from your Mac into the container
rp cp-to ./local-file.txt /home/coder/file.txt

# Copy a file from the container to your Mac
rp cp-from /home/coder/.bashrc ./container-bashrc.txt
```

### Advanced: Extra mounts at creation time

> This section uses raw `container` CLI flags and is optional. Skip it if you're just getting started.

If you have a large dataset somewhere else on your Mac that you don't want to copy in, you can mount it as a second shared folder when the container is first created. The `--` tells `just` that everything after it is extra options to pass to the `container` CLI. Run this from the project folder you want as `/workspace`:

```bash
rp create -- -v /Users/you/datasets:/data:ro
```

Breaking down `-v /Users/you/datasets:/data:ro`:
- `/Users/you/datasets` — the folder on your Mac
- `/data` — where it appears inside the container
- `:ro` — "read-only," so Claude can read but not modify your original data

The `container` CLI supports the familiar `-v host:container[:ro]` shorthand, which is what we use here for simplicity. If you ever need more options (custom mount type, propagation, etc.), the longer `--mount type=bind,source=...,target=...,readonly` form also works.

---

## Use Cases for Academic Research

> **Before each example:** Every use case below assumes you have `cd`'d into the project folder you want Claude to work in. The container is auto-created on first use of `rp claude`, named after the current folder. See [Your First Project](#your-first-project) above.

### 1. Data Analysis and Exploration

**Scenario:** You have a collection of CSV files, survey responses, or experimental data and need to understand it.

```bash
# Go to (or create) the project folder
mkdir -p ~/research/data-analysis
cd ~/research/data-analysis

# Put your data in the folder.
# "cp -r" means "copy recursively" (the folder and everything in it).
# "~" is shorthand for your home folder (e.g., /Users/yourname).
cp -r ~/Downloads/experiment_data/ .

# Ask Claude to explore it (container auto-created on first run)
rp claude "Explore the CSV files in this directory. \
  Summarize the structure, look for missing values, create basic \
  descriptive statistics, and generate visualizations."
```

Claude will write Python or R scripts, run them, and produce charts and summaries — all saved in your project folder.

### 2. Statistical Analysis and Modeling

**Scenario:** You need to run regressions, mixed-effects models, Bayesian analysis, or other statistical methods.

```bash
cd ~/research/stats-project
rp claude "I have a dataset in data.csv with columns: \
  participant_id, condition (A/B/C), reaction_time, accuracy, age, gender. \
  Run a mixed-effects model predicting reaction_time from condition, \
  controlling for age and gender, with random intercepts for participant. \
  Use R with lme4. Create publication-ready tables and plots."
```

Claude installs the necessary R packages, writes the analysis script, runs it, and produces output you can put directly in a paper.

### 3. Literature Review and Text Analysis

**Scenario:** You have a collection of PDFs or text files and want to analyze themes, extract information, or build a structured database.

```bash
cd ~/research/lit-review
rp claude "I have a folder of plain-text abstracts from a \
  systematic review. Categorize each abstract by methodology \
  (qualitative/quantitative/mixed), extract the sample size and \
  key findings, and create a summary spreadsheet."
```

### 4. Writing and Editing Assistance

**Scenario:** You're drafting a paper, grant proposal, or dissertation chapter.

```bash
cd ~/research/writing
rp claude "Read draft.md in this directory. This is a methods \
  section for a psychology paper. Suggest improvements for clarity, \
  check that the statistical reporting follows APA format, and flag \
  any claims that aren't well-supported by the described methodology."
```

### 5. Web Scraping and Data Collection

**Scenario:** You need to collect data from public websites, government databases, or APIs.

```bash
cd ~/research/scraping
rp claude "Write a Python script that downloads all publicly \
  available CSV datasets from data.gov matching the search term \
  'air quality'. Save them in a data/ subdirectory with a manifest \
  file listing each dataset's URL, title, and download date."
```

Claude can install `requests`, `beautifulsoup4`, `selenium`, or whatever is needed — without affecting your Mac.

### 6. Reproducible Research Environments

**Scenario:** You want to ensure your analysis can be reproduced exactly.

```bash
cd ~/research/repro-project
rp claude "Set up a reproducible Python project. \
  Create a pyproject.toml with pinned dependencies, a Makefile that \
  runs the full analysis pipeline from raw data to final figures, \
  and a README explaining how to reproduce the results."
```

Because the container starts from a known image, your collaborators can recreate the exact same environment.

### 7. Teaching and Course Development

**Scenario:** You're preparing coding assignments, tutorials, or lecture materials.

```bash
cd ~/teaching/course-materials
rp claude "Create a set of 5 progressive Python \
  exercises teaching pandas for data analysis. Each exercise should \
  have a starter file with instructions, a solution file, a sample \
  dataset, and auto-grading tests. Target audience: social science \
  graduate students with no prior Python experience."
```

### 8. Database Work

**Scenario:** You have large datasets that would benefit from SQL queries.

DuckDB isn't preinstalled by default — add it via `.rp.example/Dockerfile.full-toolchain` (or your own `.rp/Dockerfile`). Once present, it can directly query CSV and Parquet files without importing them:

```bash
cd ~/research/db-project
rp claude "I have several large CSV files (>1GB each) in \
  this directory. Use DuckDB to: (1) explore their schemas, \
  (2) join them on participant_id, (3) run aggregate queries \
  to compute summary statistics by group, (4) export the results \
  as a clean CSV."
```

### 9. Simulation and Computational Experiments

**Scenario:** You need to run Monte Carlo simulations, agent-based models, or other computational experiments.

```bash
cd ~/research/simulation
rp claude "Write a Python simulation of a Schelling \
  segregation model. Run it across a grid of parameters \
  (tolerance = 0.3, 0.5, 0.7; grid sizes = 50, 100, 200). \
  Save results as CSV and generate heatmap visualizations \
  of the final states."
```

If the simulation is CPU-intensive, it runs inside the container without slowing down your other Mac applications (much).

### 10. Multi-Language Projects

**Scenario:** Your workflow spans multiple languages — R for statistics, Python for data cleaning, JavaScript for a visualization dashboard.

The container has all three runtimes pre-installed. Claude can seamlessly switch between them:

```bash
cd ~/research/multi-lang
rp claude "Clean the raw data using Python pandas, \
  run the statistical models in R, and build an interactive \
  HTML dashboard using Observable Plot in JavaScript. \
  Wire them together with a just recipe that runs the full pipeline."
```

### 11. Working on Multiple Projects Simultaneously

Each container is independent — one per project folder. You can have as many as you need:

```bash
# Each cd + rp claude pair auto-creates a container named after the folder.
cd ~/research/dissertation-ch3 && rp claude
# (later, in a new terminal)
cd ~/grants/grant-nsf-2026 && rp claude
# (later, in another terminal)
cd ~/collabs/collab-with-jones-lab && rp claude
cd ~/teaching/teaching-stats101 && rp claude
```

Each project has its own folder, its own container, and its own installed packages. They don't interfere with each other. Use `rp list` to see them all.

### 12. Safe Experimentation

**Scenario:** You want to try a new tool, library, or approach without risking your current setup.

```bash
mkdir -p ~/sandbox/experiment
cd ~/sandbox/experiment
rp shell                       # auto-creates the container

# Inside the container, install and try anything that doesn't need
# a system package (no sudo by default — see the ADR-0005 security
# boundary note above)
uv pip install some-experimental-library

# If it all goes wrong
exit
rp destroy                     # Gone. No trace.
rp claude                      # Fresh start — auto-creates a new container.
```

Need an actual system package (`apt-get install`) for the experiment? Add it to a `.rp/Dockerfile` and `rp destroy && rp run` to rebuild — or set `allow_sudo: true` in `.rp/config.yaml` for the devcontainer-style "just sudo it" ergonomic (weakens the shadow boundary; see ADR-0018).

---

## Recipes Reference

Run `rp <recipe>` from any folder. By default, recipes that take a `<name>` argument default to the basename of the current folder — so `cd ~/foo && rp claude` is the same as `rp claude foo`. Passing a name explicitly overrides this.

`setup`, `build`, and `rebuild` don't depend on the current folder. Everything else does (it determines which container is acted on, and what gets mounted as `/workspace` on auto-create).

| Command | What It Does |
|---------|-------------|
| `rp setup` | One-time setup: installs Apple Container and starts its service |
| `rp build` | Builds the container image from the Dockerfile |
| `rp rebuild` | Rebuilds from scratch (ignoring cache). Use if the image seems broken |
| `rp create [name]` | Creates a container bound to the current folder (auto-runs on first `claude`/`shell`/`login`, so you rarely call this directly) |
| `rp create [name] -- <args>` | Creates a container with extra `container` CLI options (ports, mounts, etc.) |
| `rp login [name]` | Log in with Claude subscription (auto-creates container if needed) |
| `rp start [name]` | Starts a stopped container |
| `rp stop [name]` | Stops a running container (preserves state) |
| `rp restart [name]` | Restarts a container |
| `rp shell [name]` | Opens a terminal inside the container (auto-creates and auto-starts) |
| `rp claude [name]` | Opens Claude in YOLO mode (auto-creates and auto-starts) |
| `rp claude [name] "prompt"` | Runs Claude with a specific task |
| `rp claude-safe [name]` | Opens Claude with permission prompts |
| `rp claude-safe [name] "prompt"` | Runs safe-mode Claude with a specific task |
| `rp cp-to [name] <src> <dest>` | Copies a file from your Mac into the container |
| `rp cp-from [name] <src> <dest>` | Copies a file from the container to your Mac |
| `rp destroy [name]` | Deletes the container (your folder on the Mac is kept) |
| `rp list` | Shows all claude containers, their status, and the host folder each is bound to |
| `rp logs [name]` | Shows the container's log output |
| `rp stats` | Shows CPU/memory usage for all running containers |
| `rp service-start` | Starts the Apple Container service (if you stopped it) |
| `rp service-stop` | Stops the Apple Container service (frees all resources) |
| `rp service-status` | Shows whether the Apple Container service is running |

> `rp` is just a thin wrapper around `just` that preserves your current directory. If you prefer, you can `cd` into the `robo-pen` repo and run the recipes as `just <recipe>` — the cwd-anchored behavior still applies because the recipes read your *invocation* directory.

---

## Troubleshooting

### "command not found: rp"

Either `rp` isn't on your PATH or it isn't executable. Re-check the install step:

```bash
cp /path/to/robo-pen/rp ~/bin/rp
chmod +x ~/bin/rp
```

If you cloned the repo somewhere other than `~/repos/robo-pen`, also set `ROBO_PEN_DIR` in your `~/.zshrc` (see the install tip above).

### `just` commands don't work / "No justfile found"

If you're invoking `just` directly (not through `rp`), make sure you are in the `robo-pen` directory:

```bash
cd /path/to/robo-pen
```

`rp` handles this for you automatically — it's the recommended invocation.

### "command not found: just"

Install just: `brew install just`

### "Cannot connect to the container service" / commands hang

The Apple Container service isn't running. Start it:

```bash
rp service-start
```

### "rp build" is failing or taking forever

Make sure the Apple Container service is running (`rp service-status`). If the build fails on a specific step, try `rp rebuild` for a clean build. Check your internet connection — the build downloads packages from the internet.

### "Container `claude-foo` is bound to `/Users/.../other-path` but you're in `/Users/.../foo`"

This is the **collision-safety check** firing. Each container records the host folder it was created from in a label. When the recorded path doesn't match your current working directory, the tool refuses to run rather than silently mounting the wrong folder or operating on the wrong container.

Two common causes and what to do:

1. **Two different folders share the same basename.** For example, you have both `~/work/foo` and `~/personal/foo`. The default container name (`claude-foo`) is the same for both. Fix this by passing an explicit name in at least one of them:
   ```bash
   cd ~/personal/foo
   rp claude foo-personal
   ```

2. **You moved or renamed the project folder.** The container was created when the folder lived elsewhere. Either move the folder back, or destroy the container and let it be recreated from the new location:
   ```bash
   rp destroy claude-foo
   cd /new/location/foo
   rp claude
   ```

### "Container already exists"

A container with that name already exists. If it's the one you want, just use it (`rp claude` from the right folder, or `rp claude <name>`). Otherwise destroy it first:

```bash
rp destroy <name>
```

Then `cd` into the folder you want and run `rp claude` again to recreate.

### Claude says it's not authenticated / "ANTHROPIC_API_KEY not set"

**Subscription users:** Run `rp login` from the project folder to authenticate. You need to do this once per container (and again after `rp destroy` + recreate).

**API key users:** Make sure you have a `.env` file (not `.env.example`) in the `robo-pen` repo with your actual API key:

```bash
cat /path/to/robo-pen/.env
# Should show: ANTHROPIC_API_KEY=sk-ant-...
```

If you created the container before adding the key, destroy and recreate it:

```bash
cd /path/to/project
rp destroy
rp claude
```

### My Mac is slow with containers running

Stop containers you aren't using:

```bash
rp stats        # See what's using resources
rp stop <name>  # Stop idle containers
```

Or stop the Apple Container service entirely when you're done for the day:

```bash
rp service-stop
```

### I want to start completely fresh

```bash
cd /path/to/project
rp destroy     # Remove the container
rp claude      # Auto-recreate it from the base image
```

Your project folder on your Mac is untouched. Only the container (installed packages, config changes) is reset.

---

## Advanced: Customizing Claude's Behavior

The project includes two configuration files that control how Claude behaves inside containers. You can edit these and then run `rp rebuild` to apply changes to all future containers.

- **`config/CLAUDE.md`** — Instructions that Claude reads when it starts. You can add project-wide conventions, preferred libraries, coding style, or any other guidance. Think of it as a standing set of instructions for your research assistant.

- **`config/claude-settings.json`** — Controls Claude's permission settings. The default grants full access (YOLO mode). You generally don't need to change this.

After editing either file, rebuild the image:

```bash
rp rebuild
```

Existing containers are **not** affected — only new containers created after the rebuild will pick up the changes.

---

## Glossary

| Term | Meaning |
|------|---------|
| **API key** | A secret string that authenticates you with Anthropic's servers |
| **Apple Container** | Apple's native macOS tool for building and running OCI-compatible Linux containers. Runs one lightweight VM per container using Apple's virtualization framework |
| **Bind mount** | A shared folder between your Mac and a container. In this tool, the bind mount source is whichever folder you were `cd`'d into when the container was created |
| **`rp`** | The "Claude Container Runner" wrapper script. Lets you invoke recipes from any folder while keeping your current directory as the anchor for `/workspace` |
| **Claude Code** | Anthropic's command-line AI coding assistant |
| **Container** | An isolated Linux environment running on your Mac |
| **cwd-anchored** | The model this tool uses: the folder you are `cd`'d into (your current working directory) is what gets mounted as `/workspace`, and the container is named after that folder by default |
| **Dockerfile** | A blueprint that describes how to build a container image (also read by Apple Container) |
| **Host path label** | A label (`rp.host_path=...`) recorded on each container that points back to the Mac folder it was created from. Used to detect collisions when names would otherwise overlap |
| **Image** | A snapshot/template used to create containers (like a class vs an instance) |
| **Justfile** | A file containing shortcut recipes for terminal commands |
| **Repository (repo)** | A project folder tracked by git, often hosted on GitHub |
| **`sudo`** | "Superuser do" — runs a command as the administrator. Not available inside the container by default (the security boundary requires no privilege-escalation path); `allow_sudo: true` opts back in at the cost of that boundary |
| **Virtual machine (VM)** | A complete simulated computer running inside your real computer |
| **YOLO mode** | Running Claude without permission prompts (safe inside containers) |
| **`~`** | Shorthand for your home folder in the terminal (e.g., `/Users/yourname` on a Mac) |
| **`/workspace`** | The directory inside the container that maps to whichever folder on your Mac the container was created from |
