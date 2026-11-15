#!/usr/bin/env bash
# Drives the UTM test VM through the QEMU guest agent (installed with the UTM Guest Tools).
#
#   scripts/vm.sh deploy              push dist/win-arm64/Mukker.exe to C:\Mukker\ (stops a running copy first)
#   scripts/vm.sh run [MUKKER_OPEN]   start Mukker in the signed-in user's desktop session
#   scripts/vm.sh stop                stop Mukker
#   scripts/vm.sh shot <out.png>      screenshot the user's desktop and pull it to the Mac
#   scripts/vm.sh ps <command>        run a PowerShell command in the user's session (output pulled back)
#   scripts/vm.sh log                 print %LOCALAPPDATA%\Mukker\mukker.log
#
# utmctl exec runs as SYSTEM in session 0, which has no desktop, so GUI work goes through a scheduled
# task that runs interactively (/IT) as VM_USER.
set -euo pipefail
cd "$(dirname "$0")/.."
VM="${VM:-Windows}"
VM_USER="${VM_USER:-m}"
RID="${RID:-win-arm64}"

guest() { utmctl exec "$VM" --cmd "$@"; }
# Runs PowerShell as SYSTEM and waits (up to 60 s) for it to finish: utmctl exec returns immediately,
# so the command drops a marker file that is polled for.
psys() {
  local marker="C:\\Windows\\Temp\\mk-$$-$RANDOM.done"
  guest powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { $1 } finally { 'ok' | Out-File -Encoding ascii '$marker' }"
  for _ in $(seq 1 120); do
    # utmctl file pull exits 0 even when the file is missing, so check the content.
    if utmctl file pull "$VM" "$marker" 2>/dev/null | grep -q ok; then
      guest cmd.exe /c "del $marker" >/dev/null 2>&1 || true
      return 0
    fi
    sleep 0.5
  done
  echo "timed out waiting for: $1" >&2
  return 1
}

# Runs a program in the user's interactive session (no password needed for an Interactive principal),
# then waits $3 seconds. utmctl exec returns before the guest command finishes, hence the waits.
as_user() {
  local exe="$1" args="$2" wait="${3:-2}"
  psys "\$a = New-ScheduledTaskAction -Execute '$exe' -Argument '$args'; \$p = New-ScheduledTaskPrincipal -UserId '$VM_USER' -LogonType Interactive; Register-ScheduledTask -TaskName MukkerTest -Action \$a -Principal \$p -Force | Out-Null; Start-ScheduledTask -TaskName MukkerTest"
  sleep "$wait"
}

# Pulls a guest file once it exists and is complete (polls up to 30 s).
pull_when_ready() {
  local remote="$1" out="$2" tmp
  tmp="$(mktemp)"
  for _ in $(seq 1 60); do
    if utmctl file pull "$VM" "$remote" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      cat "$tmp" > "$out"; rm -f "$tmp"; return 0
    fi
    sleep 0.5
  done
  rm -f "$tmp"; echo "timed out waiting for $remote" >&2; return 1
}

case "${1:-}" in
  deploy)
    psys "Stop-Process -Name Mukker -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force C:\\Mukker | Out-Null; icacls C:\\Mukker /grant Users:M | Out-Null"
    sleep 4
    utmctl file push "$VM" 'C:\Mukker\Mukker.exe' < "dist/$RID/Mukker.exe"
    echo "pushed dist/$RID/Mukker.exe"
    ;;
  run)
    open="${2:-}"
    as_user cmd.exe "/c set MUKKER_OPEN=$open&& start \"\" C:\\Mukker\\Mukker.exe" 3
    ;;
  stop)
    psys "Stop-Process -Name Mukker -Force -ErrorAction SilentlyContinue"
    sleep 2
    ;;
  shot)
    out="${2:-shot.png}"
    local_ps="$(mktemp)"
    cat > "$local_ps" <<'PS'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type 'using System.Runtime.InteropServices; public static class D { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
[D]::SetProcessDPIAware() | Out-Null
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
$bmp.Save('C:\Mukker\shot.tmp', [System.Drawing.Imaging.ImageFormat]::Png)
Move-Item -Force 'C:\Mukker\shot.tmp' 'C:\Mukker\shot.png'
PS
    utmctl file push "$VM" 'C:\Mukker\shot.ps1' < "$local_ps"
    rm -f "$local_ps"
    psys "Remove-Item C:\\Mukker\\shot.png -ErrorAction SilentlyContinue"
    sleep 2
    as_user powershell.exe "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\\Mukker\\shot.ps1" 1
    pull_when_ready 'C:\Mukker\shot.png' "$out"
    echo "saved $out"
    ;;
  ps)
    shift
    local_ps="$(mktemp)"
    printf '%s\n' "\$ErrorActionPreference='Continue'; & { $* } *>&1 | Out-File -Encoding utf8 C:\\Mukker\\ps-out.tmp; Move-Item -Force C:\\Mukker\\ps-out.tmp C:\\Mukker\\ps-out.txt" > "$local_ps"
    psys "Remove-Item C:\\Mukker\\ps-out.txt -ErrorAction SilentlyContinue"
    utmctl file push "$VM" 'C:\Mukker\ps.ps1' < "$local_ps"
    rm -f "$local_ps"
    as_user powershell.exe "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\\Mukker\\ps.ps1" 1
    pull_when_ready 'C:\Mukker\ps-out.txt' /dev/stdout
    ;;
  log)
    psys "Get-Content \"C:\\Users\\$VM_USER\\AppData\\Local\\Mukker\\mukker.log\" -Tail 50"
    ;;
  *)
    sed -n '2,13p' "$0"; exit 1 ;;
esac
