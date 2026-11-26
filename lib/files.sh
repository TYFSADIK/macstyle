# shellcheck shell=bash
# Putting files in place so that ./uninstall.sh can take them out again: every path the install
# writes is listed in $INSTALLED, and whatever was there before is kept in $ORIGINAL/files.
# Sourced by install.sh and kde/install.sh (after lib/common.sh).

mark_installed() {   # remember a path the install put in place
    mkdir -p "$STATE"
    grep -qxF -- "$1" "$INSTALLED" 2>/dev/null || printf '%s\n' "$1" >> "$INSTALLED"
}

keep_original() {    # save PATH as it was before the first install, once
    local path="$1" rel
    [[ -e "$path" || -L "$path" ]] || return 0
    grep -qxF -- "$path" "$INSTALLED" 2>/dev/null && return 0   # ours from an earlier run
    rel="${path#"$HOME"/}"
    [[ -e "$ORIGINAL/files/$rel" || -L "$ORIGINAL/files/$rel" ]] && return 0
    mkdir -p "$(dirname -- "$ORIGINAL/files/$rel")"
    cp -a -- "$path" "$ORIGINAL/files/$rel"
}

put() {              # put SRC at DEST (file or folder), keeping the original
    local src="$1" dest="$2"
    keep_original "$dest"
    rm -rf -- "$dest"
    mkdir -p -- "$(dirname -- "$dest")"
    cp -a -- "$src" "$dest"
    mark_installed "$dest"
}

write_file() {       # write stdin to DEST, keeping the original
    local dest="$1" tmp
    keep_original "$dest"
    mkdir -p -- "$(dirname -- "$dest")"
    tmp="$(mktemp "$dest.XXXXXX")"
    cat > "$tmp"
    chmod 644 "$tmp"
    rm -rf -- "$dest"
    mv -- "$tmp" "$dest"
    mark_installed "$dest"
}
