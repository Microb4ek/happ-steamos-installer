#!/usr/bin/env bash
# A browser may rename or move the launcher. Embed the script directly in Exec.
set -euo pipefail
cd -- "$(dirname -- "$0")"
out=Install-Happ.desktop
cat > "$out" <<'ENTRY'
[Desktop Entry]
Type=Application
Name=Install Happ for SteamOS
Name[ru]=Установить Happ для SteamOS
Icon=system-software-install
Terminal=false
ENTRY
payload=$(gzip -n -9 -c install.sh | base64 -w0)
printf 'Exec=konsole --hold -e bash -c "source <(echo %s | base64 -d | gzip -dc)"\n' "$payload" >> "$out"
chmod +x "$out"
