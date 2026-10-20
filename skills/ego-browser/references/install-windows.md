# Install ego lite on Windows

Read `install.md` first; it covers upgrading an older ego lite and the onboarding step shared by every platform. This file has the Windows install steps, the commands that confirm the installation, and Windows troubleshooting.

## Run the install script

The install script lives at `scripts/install.sh` in this skill. It runs the Windows path when `uname -s` starts with `MINGW`, `MSYS`, or `CYGWIN`, so run it from Git Bash, MSYS2, or Cygwin rather than PowerShell or cmd. It will:

- Download the ego lite installer (an `.exe`) for x64.
- Run the installer, which installs per user and raises its own UAC prompt.
- Wait for the installed app and launch it.

Run the script (use the script's actual path under this skill's directory):

```bash
sh skills/ego-browser/scripts/install.sh
```

If ego lite is already installed, the script skips the download and opens the app directly. The installer is interactive: the user finishes its wizard while the script waits for the installed app.

ego lite publishes an x64 installer only. On Windows on ARM, have the user download a build from https://lite.ego.app/ instead; the script stops with an error rather than running the x64 installer.

After the app opens, the user completes the first-run onboarding in the app (see `install.md`). Onboarding registers the `ego-browser` command on the PATH. The PATH entry only reaches processes started afterwards, so open a new terminal before checking for the command.

## After installing: confirm `ego-browser` is available

Once the user has finished onboarding, open a new terminal and confirm the command is ready. The command depends on the shell.

PowerShell:

```powershell
Get-Command ego-browser
```

cmd:

```bat
where ego-browser
```

Git Bash:

```bash
command -v ego-browser
```

Once the command exists, verify the runtime. In PowerShell or cmd, where heredoc does not exist:

```powershell
ego-browser nodejs -e "console.log('ego-browser ready')"
```

In Git Bash:

```bash
ego-browser nodejs <<'EOF'
console.log('ego-browser ready')
EOF
```

Printing `ego-browser ready` means the environment is ready. Finally confirm that the installed ego lite prints its usage guide:

```powershell
ego-browser skill
```

Then return to the user's original task, as `install.md` describes.

## Troubleshooting

- **Download failed**: the script retries 3 times automatically; if it still fails, it's usually a network issue — have the user check their network and retry.
- **The script reports an x64 installer only**: the machine is Windows on ARM; use the download link above instead.
- **SmartScreen blocks the installer**: have the user choose "More info" and then "Run anyway" in the SmartScreen dialog.
- **Command still unavailable after onboarding**: open a new terminal first, because an existing one keeps the PATH it started with. Otherwise have the user reopen ego lite, finish onboarding, and retry.
