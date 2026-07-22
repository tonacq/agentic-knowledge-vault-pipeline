# Install on Ubuntu 24.04

This is the exact operating model: PowerShell runs the pipeline, Google Drive holds the operational vault, and Telegram receives completion/failure notices. The repository holds code only.

## 1. Install the runtime

```bash
sudo apt update
sudo apt install -y git curl rclone
# Install PowerShell 7 using Microsoft's Ubuntu instructions:
# https://learn.microsoft.com/powershell/scripting/install/install-ubuntu
python3 -m pip install --user -U yt-dlp
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile
```

Install Claude Code and authenticate it as the same Linux user that will run the timer. Confirm:

```bash
pwsh --version
yt-dlp --version
rclone version
claude --version
```

## 2. Configure Google Drive

Run `rclone config` and create a remote (for example `gdrive`) using your own Google OAuth client. Do not commit `~/.config/rclone/rclone.conf`.

## 3. Create a vault

```bash
git clone https://github.com/tonacq/agentic-knowledge-vault-pipeline.git ~/wiki-agent/factory
pwsh -File ~/wiki-agent/factory/linux/install-linux-vault.ps1 -VaultRoot ~/wiki-agent/working/my-channel
cp ~/wiki-agent/working/my-channel/config/vault.example.json ~/wiki-agent/working/my-channel/config/vault.json
nano ~/wiki-agent/working/my-channel/config/vault.json
```

Set `channel_url`, `creator`, and your Drive remote/path. Leave `cookie_file`, `proxy`, and `js_runtime` blank unless your own permitted setup requires them. A cookie file stays outside Git; use an absolute local path if needed.

## 4. First run

Run a no-change scan first, then the real ingest without Claude:

```bash
pwsh -File ~/wiki-agent/working/my-channel/scripts/weekly_update_channel_wiki_v8_linux.ps1 -VaultRoot ~/wiki-agent/working/my-channel -ReportOnly
pwsh -File ~/wiki-agent/working/my-channel/scripts/run_weekly_agentic_pipeline_v2_linux.ps1 -VaultRoot ~/wiki-agent/working/my-channel -SkipClaude
```

When the source notes and prompt look right, run without `-SkipClaude`. Claude Code uses `CLAUDE.md` plus the generated prompt. It must be authenticated in the timer user's shell.

## 5. Scheduled run configuration

Create the host-level configuration file. It keeps host paths, Drive locations
and optional Telegram credentials out of the repository and vault:

```bash
sudo install -d -m 700 /etc/wiki-agent
sudo cp ~/wiki-agent/factory/linux/config/wiki-agent.env.example /etc/wiki-agent/wiki-agent.env
sudo nano /etc/wiki-agent/wiki-agent.env
sudo chmod 600 /etc/wiki-agent/wiki-agent.env
```

Set the four required `WIKI_AGENT_*` values. Leave Telegram values empty unless
you want notifications. The file is read by the scheduled wrapper and never
enters the repository.

## 6. systemd weekly schedule

Copy the canonical unit files and replace `YOUR_LINUX_USER`,
`YOUR_LINUX_GROUP` and `YOUR_AGENT_ROOT` in `wiki-agent.service`:

```bash
sudo cp ~/wiki-agent/factory/linux/systemd/wiki-agent.service /etc/systemd/system/
sudo cp ~/wiki-agent/factory/linux/systemd/wiki-agent.timer /etc/systemd/system/
sudo nano /etc/systemd/system/wiki-agent.service
```

Then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now wiki-agent.timer
systemctl list-timers wiki-agent.timer
```

To run once and inspect logs:

```bash
sudo systemctl start wiki-agent.service
journalctl -u wiki-agent.service -n 100 --no-pager
```

## What is deliberately not automated

The project does not download or distribute a creator's existing vault, transcripts, browser cookies, rclone configuration, Telegram credentials or Claude credentials. They are runtime data under your control.
