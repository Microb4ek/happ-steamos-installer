#!/usr/bin/env bash
set -euo pipefail
die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

# The URL and digest are pinned together to the official upstream release.
version=4.8.3
digest=407c8ce6c35757415da153a55d7da11a669012eabbc0ac29164cf8d1b65a20c2
asset=Happ.linux.x64.pkg.tar.zst
source /etc/os-release
[[ ${ID:-} == steamos && $(uname -m) == x86_64 ]] || die 'Нужна SteamOS на устройстве x86-64.'
(( EUID != 0 )) || die 'Откройте установщик от обычного пользователя в режиме рабочего стола.'
for tool in sudo curl tar zstd sha256sum systemctl steamos-readonly flock gio; do
    command -v "$tool" >/dev/null || die "Не найдена программа $tool."
done

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
printf 'Загружаю Happ %s с GitHub…\n' "$version"
curl --fail --location --show-error --progress-bar --retry 3 --connect-timeout 20 \
    --proto '=https' --proto-redir '=https' -o "$work/$asset" \
    "https://github.com/Happ-proxy/happ-desktop/releases/download/$version/$asset"
printf '%s  %s\n' "$digest" "$work/$asset" | sha256sum -c -

printf 'Для установки службы VPN нужны права администратора.\n'
if ! sudo -n true 2>/dev/null; then
    read -r _ password_state _ < <(LC_ALL=C passwd -S "$(id -un)")
    if [[ $password_state == NP || $password_state == L ]]; then
        printf 'Задайте пароль своего пользователя SteamOS. При вводе символы не отображаются.\n'
        passwd
    fi
fi
sudo -v
sudo /bin/bash -s -- "$work/$asset" "$version" "$digest" <<'ROOT'
set -euo pipefail
umask 022
archive=$1 version=$2 digest=$3
base=/var/lib/happ-steamos-installer
target=$base/$version
service=/etc/systemd/system/happd.service
install -d -m 0755 "$base"
exec 9>"$base/install.lock"
flock -n 9 || { echo 'Уже запущена другая установка.' >&2; exit 1; }
stage=$(mktemp -d "$base/.install.XXXXXXXX")
relock=0
cleanup() {
    status=$?
    trap - EXIT
    if (( relock )); then steamos-readonly enable || status=1; fi
    rm -rf -- "$stage"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
# Verify a private root-owned copy before root extracts any files.
cp -- "$archive" "$stage/package"
printf '%s  %s\n' "$digest" "$stage/package" | sha256sum -c -
tar --zstd --no-same-owner -xf "$stage/package" -C "$stage" \
    opt/happ etc/systemd/system/happd.service usr/share/icons usr/share/applications/Happ.desktop usr/share/mime
unit=$stage/etc/systemd/system/happd.service
if [[ -e /opt/happ || -L /opt/happ ]]; then
    [[ -L /opt/happ && $(readlink /opt/happ) == "$base/current" ]] || {
        echo 'В /opt/happ уже установлена другая копия Happ.' >&2; exit 1;
    }
fi
if [[ -e $service || -L $service ]]; then
    [[ ! -L $service && -f $service && -d $target ]] && cmp -s "$unit" "$service" || {
        echo 'Служба happd уже установлена другим способом.' >&2; exit 1;
    }
fi

if [[ ! -d $target ]]; then
    mv "$stage/usr/share" "$stage/opt/happ/share"
    mv "$stage/opt/happ" "$target"
fi
ln -s "$target" "$stage/current"
mv -Tf "$stage/current" "$base/current"
if [[ ! -L /opt/happ ]]; then
    # Some SteamOS images mount /opt read-only. Restore its original state.
    if ! ln -s "$base/current" /opt/happ 2>/dev/null; then
        state=$(LC_ALL=C steamos-readonly status || true)
        [[ $state == enabled ]] || { echo 'Не удалось создать /opt/happ.' >&2; exit 1; }
        relock=1
        steamos-readonly disable
        ln -s "$base/current" /opt/happ
        steamos-readonly enable
        relock=0
    fi
fi
if [[ ! -f $service ]]; then install -m 0644 "$unit" "$service"; fi
systemctl daemon-reload
systemctl enable happd.service
systemctl restart happd.service
systemctl is-active --quiet happd.service
ROOT

data=${XDG_DATA_HOME:-$HOME/.local/share}
upstream=/opt/happ/share
install -Dm644 "$upstream/icons/hicolor/256x256/apps/happ.png" "$data/icons/hicolor/256x256/apps/happ.png"
install -Dm644 "$upstream/mime/packages/happ-mime.xml" "$data/mime/packages/happ-mime.xml"
install -Dm644 "$upstream/applications/Happ.desktop" "$data/applications/Happ.desktop"
if command -v update-mime-database >/dev/null; then update-mime-database "$data/mime"; fi
if command -v update-desktop-database >/dev/null; then update-desktop-database "$data/applications"; fi
gio launch "$data/applications/Happ.desktop"
printf 'Happ установлен. В следующий раз откройте его через меню приложений.\n'
