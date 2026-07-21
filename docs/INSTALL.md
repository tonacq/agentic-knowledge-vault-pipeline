# Install on an Ubuntu 24.04 Oracle VM

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
pwsh -File ~/wiki-agent/factory/install-wiki-agent.ps1 -VaultRoot ~/wiki-agent/working/my-channel
cp ~/wiki-agent/working/my-channel/config/vault.example.json ~/wiki-agent/working/my-channel/config/vault.json
nano ~/wiki-agent/working/my-channel/config/vault.json
```

Set `channel_url`, `creator`, and your Drive remote/path. Leave `cookie_file`, `proxy`, and `js_runtime` blank unless your own permitted setup requires them. A cookie file stays outside Git; use an absolute local path if needed.

## 4. First run

Run a no-change scan first, then the real ingest without Claude:

```bash
pwsh -File ~/wiki-agent/working/my-channel/scripts/Update-YoutubeVault.ps1 -VaultRoot ~/wiki-agent/working/my-channel -ReportOnly
pwsh -File ~/wiki-agent/working/my-channel/scripts/Run-WeeklyPipeline.ps1 -VaultRoot ~/wiki-agent/working/my-channel -SkipClaude
```

When the source notes and prompt look right, run without `-SkipClaude`. Claude Code uses `CLAUDE.md` plus the generated prompt. It must be authenticated in the timer user's shell.

## 5. Telegram notifications

Create `~/wiki-agent/working/my-channel/secrets/telegram.env` with mode 600:

```bash
TELEGRAM_BOT_TOKEN=replace-me
TELEGRAM_CHAT_ID=replace-me
```

```bash
chmod 600 ~/wiki-agent/working/my-channel/secrets/telegram.env
```

The scheduled wrapper reads these as environment variables; they never enter the repository.

## 6. systemd weekly schedule

Copy `deploy/wiki-agent.service.template` and `deploy/wiki-agent.timer.template` to `/etc/systemd/system/`, replace the three `YOUR_*` values, then:

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
