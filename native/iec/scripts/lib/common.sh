# shellcheck shell=bash
# iec/scripts/lib/common.sh — helpers shared by the IEC build scripts.
#
# 来源固定策略（见 docs/SOURCES.md）：
#   * 能确认官方 SHA-256 的 tarball 一律走 iec_fetch_verified（curl -fL + 校验，
#     不匹配立即退出）；
#   * git 依赖走 iec_clone_if_missing 的 commit 参数，按 commit 取源码而不是 tag；
#   * 暂时无法从官方 checksum 文件确认的条目显式传 UNPINNED：普通构建打印警告，
#     AUDIT_STRICT=1 或 CI 环境直接失败。
# 所有校验值都允许用环境变量覆盖（例如 IEC_ZLIB_SHA256=...），但默认必须校验。

iec_log() { echo "=== $* ===" >&2; }
iec_err() { echo "ERROR: $*" >&2; exit 1; }

# CI 或 AUDIT_STRICT=1 时，未固定来源视为错误。
iec_strict_mode() {
	case "${AUDIT_STRICT:-0}" in
		1 | true | yes) return 0 ;;
	esac
	[ -n "${CI:-}" ] && return 0
	[ -n "${GITHUB_ACTIONS:-}" ] && return 0
	return 1
}

# 取环境变量 $1 的值，未设置时用 $2（默认 UNPINNED）。避免 eval。
iec_sha_or() {
	local var="$1" def="${2:-UNPINNED}"
	printf '%s' "${!var:-$def}"
}

iec_sha256() {
	local file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file" | awk '{print $1}'
	else
		iec_err "找不到 sha256sum/shasum，无法校验 $file"
	fi
}

# iec_verify_sha256 <file> <sha256> [label]
iec_verify_sha256() {
	local file="$1" want="$2" label="${3:-$file}"
	[ -s "$file" ] || iec_err "$label: 文件为空或不存在: $file"
	local got
	got="$(iec_sha256 "$file")"
	if [ "$got" != "$want" ]; then
		iec_err "$label: SHA-256 不匹配（期望 $want，实际 $got）"
	fi
}

# 未固定来源的处理：普通构建警告，严格模式失败。
iec_unpinned() {
	local label="$1" hint="${2:-docs/SOURCES.md}"
	if iec_strict_mode; then
		iec_err "$label: 来源校验值未固定（AUDIT_STRICT/CI）；请在 $hint 补上官方 SHA-256 或 commit 后重试"
	fi
	iec_log "warning: $label 的 SHA-256 未固定，普通构建继续（CI/AUDIT_STRICT=1 会失败）"
}

# 下载并按 SHA-256 校验。
#
#   iec_fetch_verified <url> <dest> <sha256|UNPINNED> [label]
#
# - dest 已存在且校验通过时不重复下载；
# - 校验失败/下载失败均终止构建，不会把 .part 留在缓存；
# - sha256 为 UNPINNED 时，严格模式失败、普通构建警告后继续。
iec_fetch_verified() {
	local url="$1" dest="$2" sha="${3:-UNPINNED}" label="${4:-$dest}"

	if [ -s "$dest" ]; then
		if [ "$sha" = "UNPINNED" ]; then
			iec_unpinned "$label"
			iec_log "$label 使用已缓存文件（未固定校验值）: $dest"
			return 0
		fi
		if [ "$(iec_sha256 "$dest")" = "$sha" ]; then
			iec_log "$label 已存在且校验通过: $dest"
			return 0
		fi
		iec_log "$label 现有文件校验失败，重新下载: $dest"
	fi

	if [ "$sha" = "UNPINNED" ]; then
		iec_unpinned "$label"
	fi

	mkdir -p "$(dirname "$dest")"
	iec_log "download $label <- $url"
	curl -fL --retry 3 --connect-timeout 20 -m 900 -o "$dest.part" "$url" \
		|| { rm -f "$dest.part"; iec_err "$label 下载失败: $url"; }
	if [ "$sha" = "UNPINNED" ]; then
		iec_log "warning: $label 下载完成但未做 SHA-256 校验"
	else
		iec_verify_sha256 "$dest.part" "$sha" "$label"
	fi
	mv "$dest.part" "$dest"
}

# Clone a source tree the first time a build needs it.
#
#   iec_clone_if_missing <dir> <url> [ref] [commit]
#
# A directory that already exists but is not a git checkout is left alone and
# reported: silently deleting it could destroy a user's work.
# 给了 commit 时：已有 checkout 会核对 HEAD；新 checkout 直接按 commit 取，
# 不跟随可移动的 tag/分支。没有 commit 的 git 依赖在严格模式下失败。
iec_clone_if_missing() {
	local dir="$1"
	local url="$2"
	local ref="${3:-}"
	local commit="${4:-}"

	if [ -e "$dir/.git" ]; then
		if [ -n "$commit" ]; then
			local head
			head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
			[ "$head" = "$commit" ] \
				|| iec_err "$dir 当前 checkout 是 ${head:-未知}，期望 commit $commit（确认后删除该目录重取）"
		fi
		return 0
	fi
	if [ -e "$dir" ]; then
		iec_err "$dir exists but is not a git checkout"
	fi
	[ -n "$url" ] || iec_err "no repository URL configured for $dir"
	command -v git >/dev/null 2>&1 || iec_err "git is not installed"

	mkdir -p "$(dirname "$dir")"
	if [ -n "$commit" ]; then
		iec_log "clone $url @ $commit -> $dir"
		git init -q "$dir" || iec_err "git init failed: $dir"
		git -C "$dir" remote add origin "$url" || iec_err "git remote add failed: $url"
		if ! git -C "$dir" fetch --depth 1 origin "$commit" >/dev/null 2>&1; then
			# 有些托管不支持按 SHA fetch：退回按 tag/分支取，再核对 commit。
			[ -n "$ref" ] || iec_err "git fetch failed: $url ($commit)"
			git -C "$dir" fetch --depth 1 origin "$ref" \
				|| iec_err "git fetch failed: $url ($ref)"
		fi
		git -C "$dir" checkout -q --detach FETCH_HEAD \
			|| iec_err "git checkout failed: $url ($commit)"
		local head
		head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
		[ "$head" = "$commit" ] \
			|| iec_err "$url 取到的 commit 是 ${head:-未知}，期望 $commit"
	elif [ -n "$ref" ]; then
		iec_log "clone $url ($ref) -> $dir"
		git clone --depth 1 --branch "$ref" "$url" "$dir" \
			|| iec_err "git clone failed: $url ($ref)"
	else
		iec_unpinned "git clone $url（未固定 commit）"
		iec_log "clone $url -> $dir"
		git clone --depth 1 "$url" "$dir" \
			|| iec_err "git clone failed: $url"
	fi
}
