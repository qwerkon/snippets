#!/usr/bin/env bash
// put into dir /usr/local/bin/wsl-clean.sh
// sudo chmod +x /usr/local/bin/wsl-clean.sh
// sudo ./usr/local/bin/wsl-clean.sh
set -euo pipefail

exists(){ command -v "$1" >/dev/null 2>&1; }

echo ">>> APT clean"
sudo apt-get clean -y || true
sudo apt-get autoclean -y || true
sudo apt-get autoremove --purge -y || true

echo ">>> Journal/logs (zostawiamy strukturę katalogów)"
if exists journalctl; then
  sudo journalctl --vacuum-time=2d || true
fi
# Truncate typowych logów bez kasowania katalogów
sudo find /var/log -type f -name "*.log" -size +1M -exec sh -c ':> "$1"' _ {} \; 2>/dev/null || true
sudo find /var/log -type f -name "*.gz" -delete 2>/dev/null || true
sudo find /var/log -type f -name "*.1" -delete 2>/dev/null || true

echo ">>> APT cache (tylko archiwa)"
sudo rm -rf /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/* 2>/dev/null || true

echo ">>> Cache użytkownika (~/.cache)"
rm -rf "$HOME/.cache/"* 2>/dev/null || true

echo ">>> NPM / PNPM / Yarn"
if exists npm;  then npm cache clean --force || true; fi
if exists pnpm; then pnpm store prune || true; fi
if exists yarn; then yarn cache clean || true; fi
# nvm tarballs
[ -d "$HOME/.cache/nvm" ] && rm -rf "$HOME/.cache/nvm" || true

echo ">>> Composer / Packagist"
if exists composer; then composer clear-cache || true; fi
rm -rf "$HOME/.composer/cache" 2>/dev/null || true

echo ">>> Python (pip/pipx)"
if exists pip;  then pip cache purge || true; fi
if exists pipx; then pipx runpip --verbose 2>/dev/null || true; fi
rm -rf "$HOME/.cache/pip" "$HOME/.cache/pipx" 2>/dev/null || true

echo ">>> Ruby / Cargo / Go (jeśli używasz)"
if exists gem;   then gem cleanup || true; fi
if exists cargo; then cargo cache -a -q 2>/dev/null || true; fi
if exists go;    then go clean -modcache || true; fi
rm -rf "$HOME/.cache/go-build" 2>/dev/null || true

echo ">>> Docker (OSTRZEŻENIE: usuwa NIEUŻYWANE obrazy/kontenery/wolumeny)"
if exists docker; then
  docker system prune -a --volumes -f || true
fi

echo ">>> Snap (opcjonalne) – duże, ale tylko jeśli naprawdę nie używasz"
# Przykład:
# if exists snap; then
#   sudo snap remove --purge firefox || true
#   sudo rm -rf /var/lib/snapd /snap || true
# fi

echo ">>> Mini-raport przestrzeni"
df -h /
echo "Done."
