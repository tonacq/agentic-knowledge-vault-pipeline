<#
PowerShell port of tests/fake-ytdlp for native Windows execution.

Windows cannot execute an extension-less file that only carries a
#!/usr/bin/env bash shebang via PowerShell's call operator (`&`) --
CreateProcess falls back to the shell's file-association lookup, which
opens the "Open With" dialog instead of running it. PowerShell natively
executes a .ps1 file via `&` on every OS this pipeline already requires
pwsh on, so the fixture is ported to PowerShell instead of adding a new
Git-Bash/WSL dependency just to run the offline smoke test.

Behaviour is a functional match of tests/fake-ytdlp:
  - "--dump-json" anywhere in the arguments: print one fixture JSON line.
  - "--paths" anywhere in the arguments: write a fixture VTT + info.json
    into the directory given by the following argument.
  - otherwise: do nothing, exit 0.

Argument flattening: production calls $YtDlpPath two different ways --
the scan step splats a bare variable (@Arguments, real splatting), the
download step passes @($downloadArgs.ToArray()) (the array-subexpression
operator, NOT splatting). Against a native executable (the real yt-dlp),
PowerShell auto-flattens array-valued arguments into separate argv
entries at process-launch time, so both call sites work fine there. A
.ps1 target invoked via `&` does not get that native-process flattening
-- it follows PowerShell's own positional-binding rules instead -- so
the array-subexpression call site lands a single nested array in $args
here. Flatten defensively so this fixture behaves like a real executable
regardless of which calling convention a given call site uses.
#>

$ErrorActionPreference = 'Stop'

$flatArgs = New-Object System.Collections.Generic.List[string]
function Add-FlatArgs($items) {
    foreach ($item in $items) {
        if ($item -is [array]) { Add-FlatArgs $item }
        else { $flatArgs.Add([string]$item) }
    }
}
Add-FlatArgs $args

if ($flatArgs -contains '--dump-json') {
    '{"id":"abc123DEF45","title":"Fixture knowledge video","upload_date":"20260721","channel":"Fixture creator"}'
    exit 0
}

for ($i = 0; $i -lt $flatArgs.Count; $i++) {
    if ($flatArgs[$i] -eq '--paths') {
        $rawDir = $flatArgs[$i + 1]
        New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

        $vtt = @"
WEBVTT

00:00:00.000 --> 00:00:02.000
Hello <b>world</b>.

00:00:02.000 --> 00:00:04.000
Hello <b>world</b>.

00:00:04.000 --> 00:00:06.000
Useful engineering insight.
"@
        Set-Content -LiteralPath (Join-Path $rawDir '20260721_youtube_fixture-creator_fixture-knowledge-video_abc123DEF45.en-orig.vtt') -Value $vtt -Encoding UTF8

        $infoJson = '{"id":"abc123DEF45","title":"Fixture knowledge video","upload_date":"20260721","channel":"Fixture creator","webpage_url":"https://www.youtube.com/watch?v=abc123DEF45"}'
        Set-Content -LiteralPath (Join-Path $rawDir '20260721_youtube_fixture-creator_fixture-knowledge-video_abc123DEF45.info.json') -Value $infoJson -Encoding UTF8

        exit 0
    }
}

exit 0
