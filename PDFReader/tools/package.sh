#!/bin/bash
#
# ═══════════════════════════════════════════════════════════════════════════════
#  PDF Free —— 一条命令打出「已公证」的分发版 DMG
# ═══════════════════════════════════════════════════════════════════════════════
#
# ── 常用命令 ─────────────────────────────────────────────────────────────────
#   ./tools/package.sh --version 1.4.0                      # 出两个架构的 dmg
#   ./tools/package.sh --version 1.4.0 --arch universal     # 只出通用包
#   ./tools/package.sh --version 1.4.0 --only x86_64        # 只出 Intel 包
#   ./tools/package.sh --version 1.4.0 --no-notarize        # 本地试跑，不公证
#   ./tools/package.sh setup-notary                         # 存公证凭据
#
#
#  产出（默认同时出两个，分别给 Intel 和 Apple Silicon）：
#      dist/PDF-Free-1.0-x86_64.dmg      Intel
#      dist/PDF-Free-1.0-arm64.dmg       Apple Silicon
#      dist/PDF-Free-1.0-universal.dmg   （--arch universal 时只出这一个）
#
#  全程走的路径：
#      swift build → 手工组装 .app → 签名(Hardened Runtime) → 公证 → staple
#                                                              ↓
#                                            打 DMG → 签名 DMG → 公证 → staple
#
# ── 为什么不用 xcodebuild ──────────────────────────────────────────────────────
#  这台机器上 xcodebuild 跑不通（`swift-plugin-server produced malformed response`，
#  环境级问题，跟代码无关）。所以直接用 `swift build` 出二进制，再手工把 .app 的
#  骨架拼出来 —— Info.plist / 图标 / 可执行文件，和 Xcode 打出来的完全一致。
#
#  ⚠️ `--disable-sandbox` 必须加，SwiftPM 自带沙盒在这台机器上会挡插件。
#
# ── 为什么 app 和 dmg 要各公证一次 ────────────────────────────────────────────
#  Apple 官方推荐的两步：先公证并 staple .app，再把「已 staple 的 app」打进 dmg，
#  然后公证并 staple dmg。这样：
#      · 用户打开 dmg —— dmg 自带票据，离线也能过 Gatekeeper；
#      · 用户把 app 拖到 /Applications 后 —— app 自己也有票据，删掉 dmg 照样能离线验证。
#  只公证 dmg 的话，app 身上没有票据，用户离线双击可能被拦。
#  （所以默认会提交 4 次公证，慢是正常的；--notary-mode dmg-only 可以砍一半时间。）
#
# ── 前置条件 ─────────────────────────────────────────────────────────────────
#   1) 钥匙串里要有 **Developer ID Application** 证书
#      （注意：公司账号里的 "Apple Distribution" 证书**不能**用于这条路，
#        必须另外申请 Developer ID Application，见 --help）
#   2) 公证凭据，二选一：
#      · 推荐：先跑一次  ./tools/package.sh setup-notary   把凭据存进钥匙串
#      · 或给环境变量 NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_PASSWORD
#      · 或用 App Store Connect API Key：NOTARY_API_KEY_PATH / _KEY_ID / _ISSUER
#
# ── 为什么「要证书」这一步没法全自动（试过了，两条路都堵）─────────────────────
#   ① 打开 Xcode 工程的「自动签名」这条路：`xcodebuild -allowProvisioningUpdates`
#      会先读 Xcode 账号在钥匙串里的凭据（Xcode-Token）。本机那几个账号的凭据都已失效
#      （报 "Invalid credentials in keychain ..., missing Xcode-Token"），而首次登录
#      要密码 + 双重认证 —— Apple 不允许无人值守跳过。
#   ② 就算凭据在，Developer ID 的正路是 archive → exportArchive(method=developer-id)；
#      直接 `CODE_SIGN_STYLE=Automatic` + `CODE_SIGN_IDENTITY=Developer ID Application`
#      会被 Xcode 拒掉："conflicting provisioning settings ... automatically signed for
#      development"。而 archive 必须先编译，本机命令行编译又是坏的（swift-plugin-server）。
#   ⇒ 所以证书只在 Xcode GUI 里点一次（Settings → Accounts → Manage Certificates → +），
#     那一步不需要编译。之后本脚本全自动，不用再管证书。
#     `./tools/package.sh setup-identity` 会把人领到那个面板。
#
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────── 基础路径
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
cd "$ROOT"

PROJECT_NAME="PDFReader"

# ─────────────────────────────────────────────────────────────── 输出样式
if [[ -t 1 ]]; then
  C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_C=$'\033[36m'; C_G=$'\033[32m'
  C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_DIM=''; C_B=''; C_C=''; C_G=''; C_Y=''; C_R=''; C_0=''
fi
step() { printf '\n%s▶ %s%s\n' "$C_B$C_C" "$*" "$C_0"; }
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
info() { printf '  %s·%s %s\n' "$C_DIM" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '\n%s✗ %s%s\n\n' "$C_R$C_B" "$*" "$C_0" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────── 从工程里读「唯一来源」
# 不重复维护这些值：PRODUCT_NAME / BUNDLE_ID 都从生成脚本里抠，
# 部署目标从 Package.swift 抠。改一处两边都跟着变。
rb_value() {  # $1=变量名  $2=默认值
  local v
  v="$(grep -oE "$1[[:space:]]*=[[:space:]]*'[^']+'" "$SELF_DIR/generate_xcodeproj.rb" 2>/dev/null \
        | head -1 | sed "s/.*'\(.*\)'/\1/")"
  printf '%s' "${v:-$2}"
}

APP_NAME="${APP_NAME:-$(rb_value PRODUCT_NAME 'PDF Free')}"
BUNDLE_ID="${BUNDLE_ID:-$(rb_value BUNDLE_ID 'com.jiejie.pdfreader')}"

MIN_MACOS="14.0"
if [[ -f Package.swift ]]; then
  mm="$(grep -oE 'macOS\(\.v[0-9]+\)' Package.swift | head -1 | grep -oE '[0-9]+')"
  [[ -n "${mm:-}" ]] && MIN_MACOS="${mm}.0"
fi

PLIST_SRC="$ROOT/Info.plist"
ENTITLEMENTS="$ROOT/PDFReader.entitlements"

# ─────────────────────────────────────────────────────────────── 默认参数
VERSION=""                 # --version，空表示沿用 Info.plist 现值
BUILD_NUM=""               # --build，空表示沿用（给了 version 则自动 +1）
ARCH_MODE="all"            # all | universal | arm64 | x86_64
IDENTITY=""                # 空表示自动从钥匙串里找 Developer ID Application
NOTARY_PROFILE="${NOTARY_PROFILE:-PDF-Free-notary}"
NOTARY_MODE="app+dmg"      # app+dmg | dmg-only
OUT_DIR="$ROOT/dist"
DO_NOTARIZE=1
KEEP_WORK=0
POSITIONAL=""              # 位置参数（setup-notary / clean）

# ─────────────────────────────────────────────────────────────── 帮助
print_help() {
  cat <<EOF
${C_B}PDF Free 打包脚本${C_0} —— 出可直接分发的、已公证的 DMG

${C_B}用法${C_0}
  ./tools/package.sh [选项]

${C_B}版本${C_0}
  --version X.Y.Z        设置对外版本号（写进 Info.plist，唯一来源）
  --build N              设置构建号；给了 --version 却不给 --build 时自动 +1
  --restore-plist        打包结束后把 Info.plist 恢复成改动前的样子

${C_B}架构${C_0}
  --arch all             【默认】arm64 + x86_64 各出一个 dmg
  --arch universal       只出一个「双架构通用」dmg
  --arch arm64           只出 Apple Silicon 包
  --arch x86_64          只出 Intel 包
  --only <同上>          同 --arch（写习惯了哪个用哪个）

${C_B}签名 / 公证${C_0}
  --identity "<名字>"    指定签名证书；默认自动找钥匙串里的 Developer ID Application
  --keychain-profile N   公证凭据在钥匙串里的 profile 名（默认 ${NOTARY_PROFILE}）
  --notary-mode M        app+dmg【默认】= app 和 dmg 各公证一次（离线最稳）
                         dmg-only      = 只公证 dmg（快一半，app 无票据）
  --no-notarize          跳过公证与 staple（本地试跑用，产出的是未公证包）

${C_B}其它${C_0}
  --output DIR           输出目录（默认 ./dist）
  --keep-work            保留中间产物（dist/.work），失败排查用
  --sign-only            只构建+签名，不出 dmg
  -h, --help             看这个

${C_B}子命令${C_0}
  setup-identity         配签名证书（领你去 Xcode 里一键创建，不用去网页）
  setup-notary           交互式把公证凭据存进钥匙串（跑一次就够）
  doctor                 体检：证书 / 凭据 / 工具链
  clean                  清掉 dist/

${C_B}关于证书${C_0}
  Direct Distribution 必须用 ${C_B}Developer ID Application${C_0} 证书。
  公司账号里的 "Apple Distribution: ..." 那是给 App Store 用的，${C_B}不能${C_0}走这条路。

  ${C_B}不用去 developer.apple.com${C_0}：跑 ./tools/package.sh setup-identity，
  它会领你去 Xcode 里点两下 —— Settings → Accounts → Manage Certificates → +。
  ${C_DIM}面板里已经列着同名证书，也要在本机重建一张：证书私钥只存在创建它的那台机器上。${C_0}

EOF
}

# ─────────────────────────────────────────────────────────────── 参数解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)         VERSION="${2:?--version 需要一个值}"; shift 2 ;;
    --version=*)       VERSION="${1#*=}"; shift ;;
    --build)           BUILD_NUM="${2:?--build 需要一个值}"; shift 2 ;;
    --build=*)         BUILD_NUM="${1#*=}"; shift ;;
    --arch|--only)     ARCH_MODE="${2:?--arch 需要一个值}"; shift 2 ;;
    --arch=*|--only=*) ARCH_MODE="${1#*=}"; shift ;;
    --identity)        IDENTITY="${2:?--identity 需要一个值}"; shift 2 ;;
    --identity=*)      IDENTITY="${1#*=}"; shift ;;
    --keychain-profile) NOTARY_PROFILE="${2:?需要一个值}"; shift 2 ;;
    --keychain-profile=*) NOTARY_PROFILE="${1#*=}"; shift ;;
    --notary-mode)     NOTARY_MODE="${2:?需要一个值}"; shift 2 ;;
    --notary-mode=*)   NOTARY_MODE="${1#*=}"; shift ;;
    --no-notarize)     DO_NOTARIZE=0; shift ;;
    --output)          OUT_DIR="${2:?--output 需要一个值}"; shift 2 ;;
    --output=*)        OUT_DIR="${1#*=}"; shift ;;
    --keep-work)       KEEP_WORK=1; shift ;;
    --sign-only)       SIGN_ONLY=1; shift ;;
    --restore-plist)   RESTORE_PLIST=1; shift ;;
    -h|--help)         print_help; exit 0 ;;
    -*)                die "不认识的选项：${1}（用 --help 看看）" ;;
    *)                 POSITIONAL="$1"; shift ;;
  esac
done
: "${SIGN_ONLY:=0}"
: "${RESTORE_PLIST:=0}"

# ═══════════════════════════════════════════════════════════════════════════════
#  子命令
# ═══════════════════════════════════════════════════════════════════════════════

cmd_setup_notary() {
  step "配置公证凭据"
  cat <<EOF
  接下来会问你 Apple ID、Team ID 和 app 专用密码，存进钥匙串（profile 名：${NOTARY_PROFILE}）。

  · Team ID：${C_B}74MC75RT69${C_0}（KOOLMESH TECHNOLOGY CO.,LTD —— 从本机证书上读到的，确认一下）
  · app 专用密码：appleid.apple.com → 登录 → 登录与安全 → App 专用密码 → 生成
    ${C_DIM}（不是你的 Apple ID 登录密码！形如 abcd-efgh-ijkl-mnop）${C_0}

EOF
  read -r -p "  继续？[y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { info "已取消"; exit 0; }
  # Apple ID 不预填（让它交互问，省得把邮箱写进脚本）；Team ID 直接给，少填一项。
  local args=()
  [[ -n "${NOTARY_APPLE_ID:-}" ]] && args+=(--apple-id "$NOTARY_APPLE_ID")
  [[ -n "${NOTARY_TEAM_ID:-}" ]] && args+=(--team-id "$NOTARY_TEAM_ID")
  if [[ ${#args[@]} -eq 0 ]]; then
    xcrun notarytool store-credentials "$NOTARY_PROFILE" --team-id "74MC75RT69"
  else
    xcrun notarytool store-credentials "$NOTARY_PROFILE" "${args[@]}"
  fi
  echo
  ok "凭据已存入钥匙串，profile = $NOTARY_PROFILE"
  info "之后打包不用再输密码，脚本会自动用它。"
}

cmd_setup_identity() {
  step "配置签名证书（Developer ID Application）"

  local id
  id="$(detect_identity)"
  if [[ -n "$id" ]]; then
    ok "钥匙串里已经有 Developer ID Application 证书："
    printf '    %s\n' "$id"
    info "package.sh 会自动挑它签名，不用再配什么。"
    return
  fi

  warn "钥匙串里没有 Developer ID Application 证书。"

  echo
  local wrong
  wrong="$(wrong_identity_hint)"
  if [[ -n "$wrong" ]]; then
    warn "下面这几张名字很像、但都走不了这条路："
    printf '%s' "$wrong"
    echo
  fi

  local accts
  accts="$(xcode_accounts | tr '\n' ' ')"
  if [[ -n "$accts" ]]; then
    info "Xcode 里配置过的 Apple ID：${accts}"
  fi
  if xcode_credentials_present; then
    printf '  %s✓%s Xcode 账号凭据在钥匙串里\n' "$C_G" "$C_0"
  else
    printf '  %s!%s Xcode 账号凭据已失效（钥匙串里没有 Xcode-Token）—— 要重新登录\n' "$C_Y" "$C_0"
  fi

  cat <<EOF

  ${C_B}这条路不用去 developer.apple.com，Xcode 里点两下就行：${C_0}

    1. 打开 Xcode（不用打开任何工程）
    2. 菜单 ${C_B}Xcode → Settings…${C_0}（⌘,）→ ${C_B}Accounts${C_0}
    3. 左边选中公司团队：${C_DIM}KOOLMESH TECHNOLOGY CO.,LTD · Team ID 74MC75RT69${C_0}
       账号凭据失效的话会提示重新登录（或点左下 ${C_B}+${C_0} 重新加一次）——
       输密码 + 双重认证。${C_DIM}这一步 Apple 不允许无人值守跳过，只能人工做一次。${C_0}
    4. 点右下角 ${C_B}Manage Certificates…${C_0}
    5. 左下角 ${C_B}+${C_0} → ${C_B}Developer ID Application${C_0}
       ${C_DIM}几秒后证书自动装进钥匙串。${C_0}

  ${C_DIM}面板里如果已经列着 Developer ID Application，仍然要在本机建一张：
  证书私钥只存在创建它的那台机器上，别人建的没法拿来签名。${C_0}

  弄好之后跑 ${C_B}./tools/package.sh doctor${C_0} 确认，再重新打包。

EOF

  read -r -p "  现在打开 Xcode？[Y/n] " ans
  case "$ans" in
    n|N) info "好，稍后自己开。步骤就在上面。" ;;
    *)   open -a Xcode && ok "已打开 Xcode —— 进去按 2~5 步走" ;;
  esac
}

cmd_doctor() {
  step "环境体检"

  printf '  swift        '
  if command -v swift >/dev/null 2>&1; then
    ok "$(swift --version 2>&1 | head -1)"
  else
    warn "没找到 swift"
  fi

  printf '  notarytool   '
  if xcrun --find notarytool >/dev/null 2>&1; then ok "可用"; else warn "不可用"; fi

  printf '  stapler      '
  if xcrun --find stapler >/dev/null 2>&1; then ok "可用"; else warn "不可用"; fi

  echo
  printf '  Info.plist   '
  ok "$(plist_read CFBundleShortVersionString) (build $(plist_read CFBundleVersion))"

  echo
  info "钥匙串里的签名证书："
  local found_any=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    found_any=1
    if [[ "$line" == *"Developer ID Application"* ]]; then
      printf '    %s✓%s %s\n' "$C_G" "$C_0" "$line"
    else
      printf '    %s·%s %s\n' "$C_DIM" "$C_0" "$line"
    fi
  done < <(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(.*\)"/\1/p')

  echo
  if [[ $found_any -eq 0 ]]; then
    warn "一个签名证书都没找到"
  elif [[ -z "$(detect_identity)" ]]; then
    warn "没有 Developer ID Application 证书 —— 正是打包会卡住的那一步。"
    info "跑 ./tools/package.sh setup-identity 看怎么办（不用去 developer.apple.com）"
  else
    ok "找到可用于分发的证书"
  fi

  echo
  printf '  Xcode 账号   '
  local accts
  accts="$(xcode_accounts | tr '\n' ' ' | sed 's/ *$//')"
  if xcode_credentials_present; then
    ok "凭据在钥匙串里（${accts}）"
  elif [[ -n "$accts" ]]; then
    warn "凭据已失效 —— ${accts} 要重新登录（Xcode → Settings → Accounts）"
  else
    info "没读到配置过的账号"
  fi

  echo
  info "公证凭据："
  local nrc=0
  verify_notary_profile "$NOTARY_PROFILE" || nrc=$?
  case $nrc in
    0) printf '    %s✓%s 钥匙串 profile「%s」已验证可用\n' "$C_G" "$C_0" "$NOTARY_PROFILE" ;;
    2) printf '    %s!%s 钥匙串里没有 profile「%s」\n' "$C_Y" "$C_0" "$NOTARY_PROFILE"
       info "  跑 ./tools/package.sh setup-notary 建一个，或改用环境变量" ;;
    *) printf '    %s·%s 连不上 Apple，没法验证「%s」（网络？）\n' "$C_DIM" "$C_0" "$NOTARY_PROFILE" ;;
  esac

  echo
  info "依赖检查：项目无外部 SwiftPM 依赖，直接 swift build 即可。"
}

cmd_clean() {
  step "清理"
  rm -rf "$OUT_DIR"
  ok "已删除 $OUT_DIR"
}

# 子命令分发在文件末尾。别把这行挪到前面去 —— 见文件末尾的说明。

# ═══════════════════════════════════════════════════════════════════════════════
#  小工具
# ═══════════════════════════════════════════════════════════════════════════════

plist_read() {  # $1=key  $2=plist路径（默认工程 Info.plist）
  /usr/libexec/PlistBuddy -c "Print :$1" "${2:-$PLIST_SRC}" 2>/dev/null || true
}

# ⚠️ 版本号用 sed 精准替换那一行的 <string>，**不用 PlistBuddy Set**：
#    PlistBuddy 写回时会用 CoreFoundation 重新序列化整份 plist —— 键的顺序、
#    缩进风格全被重排，git diff 里会出现一堆无关改动。sed 只碰目标行，其余原样。
plist_write_version() {  # $1=key  $2=值
  local key="$1" val="$2" before after
  before="$(plist_read "$key")"
  /usr/bin/sed -i '' -E \
    "/<key>${key}<\/key>/{n;s|<string>[^<]*</string>|<string>${val}</string>|;}" \
    "$PLIST_SRC"
  after="$(plist_read "$key")"
  [[ "$after" == "$val" ]] || die "写 Info.plist 的 ${key} 失败（期望 ${val}，实际 ${after:-空}）"
  printf '  %s·%s %s: %s → %s\n' "$C_DIM" "$C_0" "$key" "${before:-空}" "$val"
}

verify_version_format() {  # $1=值  $2=名字
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "${2} 格式不对：「${1}」。要形如 1.4.0 / 1.4（只许数字和点）"
}

detect_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' \
    | head -1 \
    | sed 's/.*"\(.*\)".*/\1/' || true
}

detect_team_id() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' \
    | head -1 \
    | sed -n 's/.*(\([A-Z0-9]*\))".*/\1/p' || true
}

# Xcode 里配置过的 Apple ID（只是"配置过"，不代表凭据还有效）
xcode_accounts() {
  defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists 2>/dev/null \
    | sed -n 's/.*username = "\(.*\)";.*/\1/p' | sort -u
}

# Xcode 的账号 token 存不存得住。缺它 xcodebuild -allowProvisioningUpdates 就会报
# "Invalid credentials in keychain ..., missing Xcode-Token" —— 自动签名直接废掉。
xcode_credentials_present() {
  security find-generic-password -s "Xcode-Token" >/dev/null 2>&1 \
    || security find-generic-password -s "Xcode-Username" >/dev/null 2>&1
}

# 钥匙串里那些「名字里也有 Distribution、但走不了这条路」的证书。
# 这三个特别容易选错（实测就选错过一次）：
#   · Mac Installer Distribution（＝ 3rd Party Mac Developer Installer）→ 签 .pkg，App Store 用
#   · Apple Distribution                                              → 签 .app，也是 App Store 用
#   · Developer ID Installer                                          → 签 .pkg，但那个是直发用的
# 真正要的是 Developer ID Application：签 .app + 直发给用户。
wrong_identity_hint() {
  local out="" label
  while IFS= read -r label; do
    [[ -z "$label" ]] && continue
    out="${out}    ${C_DIM}·${C_0} 「${label}」\n      ${C_DIM}→ 签 .pkg 用的，走 App Store 提交，不能签 .app${C_0}\n"
  done < <(security find-certificate -a -c "Installer" 2>/dev/null \
             | sed -n 's/.*"labl"<blob>="\(.*\)"/\1/p')
  while IFS= read -r label; do
    [[ -z "$label" ]] && continue
    out="${out}    ${C_DIM}·${C_0} 「${label}」\n      ${C_DIM}→ 签 .app 的，但同样是给 App Store 提交用的${C_0}\n"
  done < <(security find-identity -v -p codesigning 2>/dev/null \
             | grep 'Apple Distribution' | sed -n 's/.*"\(.*\)"/\1/p')
  printf '%b' "$out"
}

# ⚠️ 别试图去猜 notarytool 把凭据存在钥匙串的哪个 service 下。
# 实测 `security find-generic-password -s com.apple.gke.notary.tool -a <profile>` 查不到，
# 只按 account 查（`-a <profile>`，不限 service）也查不到 —— 那条记录不在普通 login
# keychain 里，猜 service 名这条路走不通（踩过：明明 setup-notary 刚存成功，
# 打包却报「没有可用的公证凭据」）。
# 唯一可靠的判据：让 notarytool 自己去读一次。
#   0 = 可用   2 = 明确没有这条凭据   1 = 其它（多半是网络，别据此判死）
verify_notary_profile() {  # $1=profile 名
  local out
  out="$(xcrun notarytool history --keychain-profile "$1" 2>&1)" || true
  case "$out" in
    *Successfully*)                                       return 0 ;;
    *"No Keychain password item found"*|*"not be found"*) return 2 ;;
    *)                                                    return 1 ;;
  esac
}

# 组装 notarytool 的凭据参数（返回进全局数组 NOTARY_CREDS）
build_notary_creds() {
  NOTARY_CREDS=()

  # 显式给的优先 —— 环境变量是"这次就用这个"的意思
  if [[ -n "${NOTARY_API_KEY_PATH:-}" ]]; then
    [[ -n "${NOTARY_API_KEY_ID:-}" && -n "${NOTARY_API_ISSUER:-}" ]] \
      || die "用了 API Key 就还要给 NOTARY_API_KEY_ID 和 NOTARY_API_ISSUER"
    NOTARY_CREDS=(--key "$NOTARY_API_KEY_PATH" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER")
    NOTARY_CRED_DESC="App Store Connect API Key"
    return
  fi

  if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
    NOTARY_CREDS=(--apple-id "$NOTARY_APPLE_ID" --team-id "${NOTARY_TEAM_ID:-}" --password "$NOTARY_PASSWORD")
    NOTARY_CRED_DESC="Apple ID「${NOTARY_APPLE_ID}」（环境变量）"
    return
  fi

  # 默认走钥匙串 profile
  if [[ -n "$NOTARY_PROFILE" ]]; then
    NOTARY_CREDS=(--keychain-profile "$NOTARY_PROFILE")
    NOTARY_CRED_DESC="钥匙串 profile「${NOTARY_PROFILE}」"
    local rc=0
    verify_notary_profile "$NOTARY_PROFILE" || rc=$?
    case $rc in
      0) NOTARY_CRED_DESC="${NOTARY_CRED_DESC}（notarytool 已验证）" ;;
      2) cat >&2 <<EOF

${C_R}${C_B}✗ 钥匙串里没有 profile「${NOTARY_PROFILE}」${C_0}

  先建一个：./tools/package.sh setup-notary
  ${C_DIM}（要 Apple ID + app 专用密码；Team ID 已经替你填好 74MC75RT69）${C_0}

EOF
         exit 1 ;;
      *) warn "连不上 Apple 验证凭据（网络？）—— 先接着用，真提交时见分晓" ;;
    esac
    return
  fi

  # ⚠️ 下面这段只是给人看的说明。**别把真实凭据填进来** ——
  # 这个文件在 git 仓库里，填了就等于把密码提交上去。
  # 真要临时用环境变量，在终端里 export，不要写进脚本。
  cat >&2 <<EOF

${C_R}${C_B}✗ 没有可用的公证凭据${C_0}

  三选一：

  ${C_B}A. 存进钥匙串（推荐，最省事）${C_0}
       ./tools/package.sh setup-notary
     只需要 Apple ID + Team ID + app 专用密码（不是登录密码）。

  ${C_B}B. 临时用环境变量${C_0}（${C_Y}在终端里敲，别写进这个脚本${C_0}）
       export NOTARY_APPLE_ID='<你的 Apple ID>'
       export NOTARY_TEAM_ID='74MC75RT69'
       export NOTARY_PASSWORD='<app 专用密码>'
       ./tools/package.sh --version 1.4.0

  ${C_B}C. 用 App Store Connect API Key${C_0}
       export NOTARY_API_KEY_PATH=~/AuthKey_XXXX.p8
       export NOTARY_API_KEY_ID=XXXXXXXXXX
       export NOTARY_API_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

  ${C_DIM}app 专用密码生成：appleid.apple.com → 登录与安全 → App 专用密码${C_0}

EOF
  exit 1
}

# ─────────────────────────────────────────────────────────────── 公证一个文件
notarize() {  # $1=待提交文件（.zip 或 .dmg）  $2=说明
  local file="$1" label="$2" out id status logjson
  info "提交公证：$label"
  out="$(xcrun notarytool submit "$file" "${NOTARY_CREDS[@]}" --wait --output-format json 2>&1)" || true

  # 直接从 json 里抠字段，不走 python3：
  # /usr/bin/python3 是 Xcode 命令行工具的 shim，没装 CLT 的机器上调用它会弹
  # 「要安装命令行工具吗」的窗，很烦人。sed 够了。
  id="$(printf '%s' "$out" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  status="$(printf '%s' "$out" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

  if [[ "$status" == "Accepted" ]]; then
    ok "公证通过（id=${id:-?}）"
    return 0
  fi

  echo "$out" >&2
  if [[ -n "$id" ]]; then
    warn "公证未通过（status=${status:-未知}），拉详细日志："
    xcrun notarytool log "$id" "${NOTARY_CREDS[@]}" 2>&1 | sed 's/^/    /' >&2 || true
  fi
  die "$label 公证失败"
}

staple_and_check() {  # $1=文件
  xcrun stapler staple "$1" >/dev/null
  xcrun stapler validate "$1" >/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════════
#  主流程
# ═══════════════════════════════════════════════════════════════════════════════
# 包成函数是为了解决一个顺序问题：doctor 要用 plist_read / detect_identity 这些
# 工具函数，而工具函数定义在主流程后面。主流程要是平铺在这儿，跑 `package.sh doctor`
# 会先把整套打包流程跑一遍才轮到 doctor。包成函数、交给文件末尾的分发器调用，各归各位。
main() {

step "0 / 7  预检"

[[ -f "$PLIST_SRC" ]]    || die "找不到 $PLIST_SRC"
[[ -f "$ENTITLEMENTS" ]] || die "找不到 $ENTITLEMENTS"
command -v swift >/dev/null || die "找不到 swift"
xcrun --find notarytool >/dev/null 2>&1 || die "找不到 notarytool（装个完整版 Xcode）"

case "$ARCH_MODE" in
  all)        TARGET_ARCHES=(arm64 x86_64) ;;
  universal)  TARGET_ARCHES=(universal) ;;
  arm64)      TARGET_ARCHES=(arm64) ;;
  x86_64)     TARGET_ARCHES=(x86_64) ;;
  *)          die "--arch 只能是 all / universal / arm64 / x86_64，你给的是「${ARCH_MODE}」" ;;
esac

case "$NOTARY_MODE" in
  app+dmg|dmg-only) ;;
  *) die "--notary-mode 只能是 app+dmg / dmg-only" ;;
esac

# 签名身份
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(detect_identity)"
fi
if [[ -z "$IDENTITY" ]]; then
  WRONG_HINT="$(wrong_identity_hint)"
  cat >&2 <<EOF

${C_R}${C_B}✗ 找不到 Developer ID Application 证书${C_0}

  Direct Distribution（DMG 分发 + 公证）必须用这种证书。

  ${C_B}Xcode 里点两下就有${C_0}（不用去 developer.apple.com）：
    Xcode → Settings…（⌘,）→ Accounts → 选中团队
          → 右下 Manage Certificates… → 左下 ${C_B}+${C_0} → ${C_B}Developer ID Application${C_0}
    需要该团队的 Account Holder / Admin 权限。

EOF
  if [[ -n "$WRONG_HINT" ]]; then
    cat >&2 <<EOF
  ${C_Y}钥匙串里下面这几张名字很像、但都走不了这条路：${C_0}
${WRONG_HINT}
EOF
  fi
  cat >&2 <<EOF

  弄好之后跑 ./tools/package.sh doctor 确认，再重新打包。
  ${C_DIM}要一步步的指引：./tools/package.sh setup-identity
  只想本地试跑流程（不签名不公证）：--identity - --no-notarize${C_0}

EOF
  exit 1
fi

ADHOC=0
[[ "$IDENTITY" == "-" ]] && ADHOC=1

if [[ $ADHOC -eq 1 && $DO_NOTARIZE -eq 1 ]]; then
  warn "身份是 ad-hoc（-），这种签名无法公证 —— 自动关掉公证。"
  DO_NOTARIZE=0
fi

# --sign-only 只到签名就停，用不着公证凭据。
#（不然想快速验证一张证书能不能签名，还会先被「没有公证凭据」挡住，挺别扭。）
if [[ $SIGN_ONLY -eq 1 ]]; then
  DO_NOTARIZE=0
fi

if [[ $ADHOC -eq 0 && $DO_NOTARIZE -eq 1 ]]; then
  build_notary_creds
fi

TEAM_ID="$(detect_team_id)"
ok "签名身份：${C_B}$IDENTITY${C_0}"
[[ -n "$TEAM_ID" ]] && info "Team ID：$TEAM_ID"
[[ $ADHOC -eq 1 ]] && warn "ad-hoc 模式：产物只能本机跑，不能分发"
if [[ $DO_NOTARIZE -eq 1 ]]; then
  ok "公证凭据：$NOTARY_CRED_DESC"
  info "模式：${NOTARY_MODE}（$( [[ $NOTARY_MODE == app+dmg ]] && echo 'app 和 dmg 各公证一次，离线最稳' || echo '只公证 dmg' ))"
else
  warn "跳过公证 —— 产物未公证，用户下载会被 Gatekeeper 拦"
fi

WORK="$OUT_DIR/.work"
rm -rf "$WORK"
mkdir -p "$WORK" "$OUT_DIR"

# 记住原来的版本号，方便出错时还原
ORIG_SHORT="$(plist_read CFBundleShortVersionString)"
ORIG_BUILD="$(plist_read CFBundleVersion)"
restore_plist_on_exit() {
  if [[ $RESTORE_PLIST -eq 1 && -n "$ORIG_SHORT" ]]; then
    plist_write_version CFBundleShortVersionString "$ORIG_SHORT" >/dev/null 2>&1 || true
    plist_write_version CFBundleVersion "$ORIG_BUILD" >/dev/null 2>&1 || true
    info "Info.plist 已恢复为 $ORIG_SHORT ($ORIG_BUILD)"
  fi
}
trap 'restore_plist_on_exit' EXIT

# ─────────────────────────────────────────────────────────────── 1. 版本号
step "1 / 7  版本号"

if [[ -n "$VERSION" || -n "$BUILD_NUM" ]]; then
  [[ -n "$VERSION" ]] || VERSION="$ORIG_SHORT"
  verify_version_format "$VERSION" "--version"
  if [[ -z "$BUILD_NUM" ]]; then
    # 只给了 --version 就自动把构建号 +1（不填的话 App Store / 更新检测会认为没变）
    [[ "$VERSION" == "$ORIG_SHORT" ]] && BUILD_NUM="$ORIG_BUILD" \
                                      || BUILD_NUM=$(( ${ORIG_BUILD:-0} + 1 ))
  fi
  verify_version_format "$BUILD_NUM" "--build"
  plist_write_version CFBundleShortVersionString "$VERSION"
  plist_write_version CFBundleVersion "$BUILD_NUM"
  VERSION="$VERSION"; BUILD_NUM="$BUILD_NUM"
else
  VERSION="$ORIG_SHORT"; BUILD_NUM="$ORIG_BUILD"
  info "没给 --version，沿用 Info.plist 现值"
  info "CFBundleShortVersionString = ${VERSION}，CFBundleVersion = ${BUILD_NUM}"
fi

# ─────────────────────────────────────────────────────────────── 2. 编译
step "2 / 7  编译（arm64 + x86_64 通用二进制）"
info "swift build -c release --arch arm64 --arch x86_64 --disable-sandbox"

BUILD_LOG="$WORK/build.log"
if ! swift build -c release --arch arm64 --arch x86_64 --disable-sandbox >"$BUILD_LOG" 2>&1; then
  tail -40 "$BUILD_LOG" >&2
  die "编译失败，完整日志：$BUILD_LOG"
fi
grep -E '^(error|warning):' "$BUILD_LOG" | sed 's/^/    /' || true

UNIVERSAL_BIN=""
for cand in \
  "$ROOT/.build/apple/Products/Release/$PROJECT_NAME" \
  "$ROOT/.build/out/Products/Release/$PROJECT_NAME" \
  "$ROOT/.build/release/$PROJECT_NAME"
do
  if [[ -f "$cand" ]]; then UNIVERSAL_BIN="$cand"; break; fi
done
[[ -n "$UNIVERSAL_BIN" ]] || die "编译过了但找不到产物，去 .build 里翻翻"

ARCHS_IN_BIN="$(lipo -archs "$UNIVERSAL_BIN")"
ok "产物：${UNIVERSAL_BIN#$ROOT/}"
ok "架构：$ARCHS_IN_BIN"

# 通用包里两个架构都在，但目标里要的是单架构 —— 说明构建参数没生效，早点报错
if [[ "$ARCH_MODE" != "universal" ]]; then
  for a in "${TARGET_ARCHES[@]}"; do
    [[ " $ARCHS_IN_BIN " == *" $a "* ]] || die "产物里没有 $a 这一片，检查 swift build 的 --arch 是否生效"
  done
fi

# dSYM：崩溃符号化要用，跟 dmg 一起归档
DSYM_SRC="$ROOT/.build/out/Products/Release/$PROJECT_NAME.dSYM"
[[ -d "$DSYM_SRC" ]] || DSYM_SRC="$ROOT/.build/release/$PROJECT_NAME.dSYM"
if [[ -d "$DSYM_SRC" ]]; then
  rm -rf "$OUT_DIR/dSYM"
  mkdir -p "$OUT_DIR/dSYM"
  cp -R "$DSYM_SRC" "$OUT_DIR/dSYM/"
  ok "dSYM 已归档到 dist/dSYM/"
fi

if [[ $SIGN_ONLY -eq 1 ]]; then
  info "--sign-only 只到签名，没打 dmg"
fi

# ─────────────────────────────────────────────────────────────── 3. 组装 .app
# 手工拼 Xcode 那种目录结构。关键点是 Info.plist 里的 $(VAR) 占位符要自己替换掉 ——
# 走 Xcode 构建时是 Xcode 替你做这件事，手工拼就得自己来，否则 app 一启动就崩
# （CFBundleExecutable 会是字面量 "$(EXECUTABLE_NAME)"，系统找不到可执行文件）。
assemble_app() {  # $1=目标架构  $2=输出 .app 路径
  local arch="$1" app="$2" bin_name="$APP_NAME"

  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

  # 可执行文件
  if [[ "$arch" == "universal" ]]; then
    cp "$UNIVERSAL_BIN" "$app/Contents/MacOS/$bin_name"
  else
    lipo -thin "$arch" "$UNIVERSAL_BIN" -output "$app/Contents/MacOS/$bin_name"
  fi
  chmod 755 "$app/Contents/MacOS/$bin_name"

  # Info.plist：占位符 → 真实值
  /usr/bin/sed -e "s|\$(EXECUTABLE_NAME)|$bin_name|g" \
               -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$BUNDLE_ID|g" \
               -e "s|\$(MACOSX_DEPLOYMENT_TARGET)|$MIN_MACOS|g" \
               "$PLIST_SRC" > "$app/Contents/Info.plist"

  # 占位符没换干净就直接炸，别把坏包放出去
  if grep -q '\$(' "$app/Contents/Info.plist"; then
    grep -n '\$(' "$app/Contents/Info.plist" >&2
    die "Info.plist 里还有没替换的 \$(...) 占位符，看看上面几行"
  fi

  # 图标 + PkgInfo
  [[ -f "$ROOT/Resources/AppIcon.icns" ]] \
    && cp "$ROOT/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
  printf 'APPL????' > "$app/Contents/PkgInfo"
}

# ─────────────────────────────────────────────────────────────── 4. 签名
sign_app() {  # $1=.app
  local app="$1"
  # --timestamp      : 打时间戳，公证硬性要求
  # --options runtime: 开 Hardened Runtime，公证硬性要求
  # 这里没有嵌套的 framework / dylib 要签，签 app 本体一次就够
  #（--deep 是苹果明确不推荐的：它会用同一套选项盖住内部组件的差异）
  codesign --force --timestamp --options runtime \
           --entitlements "$ENTITLEMENTS" \
           --sign "$IDENTITY" \
           "$app" 2>&1 | sed 's/^/    /'

  codesign --verify --strict --verbose=2 "$app" 2>&1 | sed 's/^/    /' || die "签名校验失败：$app"

  # 带 get-task-allow 的包公证必被拒 —— 那等于把调试器入口开放出去
  if codesign -d --entitlements :- "$app" 2>/dev/null | grep -q 'get-task-allow'; then
    die "$app 的 entitlements 里带着 get-task-allow，公证会被拒"
  fi
}

# ─────────────────────────────────────────────────────────────── 5. 打 DMG
make_dmg() {  # $1=源 .app  $2=输出 dmg  $3=卷标
  # ⚠️ local 必须一行一个。bash 3.2（macOS 自带的那个）会把同一行 local 里的所有
  # 变量先声明、后赋值，于是 `local a=$1 stage="...$a..."` 里的 $a 在求值时还是个
  # 未赋值的 local —— 撞上 set -u 就报 unbound variable，然后整行的赋值全废。
  local app="$1"
  local dmg="$2"
  local vol="$3"
  local stage="$WORK/stage-$(basename "$dmg" .dmg)"

  rm -rf "$stage"; mkdir -p "$stage"
  # ditto 比 cp -R 靠谱：完整保留资源分支、扩展属性和权限位
  ditto "$app" "$stage/$(basename "$app")"
  ln -s /Applications "$stage/Applications"   # 拖拽安装的落点

  rm -f "$dmg"
  # hdiutil 在 macOS 27 上会念叨一句「已废弃，请改用 diskutil image create」——
  # 功能照旧，只是提示。正常就把话吞进日志，真失败了再原样亮出来，不然每次打包
  # 都要看着一行红字提心吊胆。
  local hdlog="$WORK/hdiutil-create.log"
  if ! hdiutil create \
        -volname "$vol" \
        -srcfolder "$stage" \
        -ov -format UDZO \
        "$dmg" >"$hdlog" 2>&1
  then
    cat "$hdlog" >&2
    die "hdiutil 打 DMG 失败：$(basename "$dmg")"
  fi

  rm -rf "$stage"
}

# ─────────────────────────────────────────────────────────────── 6. 开始逐个架构处理
step "3 / 7  组装 / 签名 / 打 DMG / 公证"

PRODUCED=()

for arch in "${TARGET_ARCHES[@]}"; do
  case "$arch" in
    arm64)     suffix="arm64";     vol_suffix=" (Apple Silicon)" ;;
    x86_64)    suffix="x86_64";    vol_suffix=" (Intel)" ;;
    universal) suffix="universal"; vol_suffix="" ;;
  esac

  printf '\n  %s── %s ──────────────────────────────────────%s\n' "$C_B" "$arch" "$C_0"

  # ⚠️ 包名必须正好是「PDF Free.app」—— 这个目录名就是用户拖进 /Applications 之后
  # 看到、也是 Dock/Spotlight 显示的名字。区分架构只能靠**父目录**，不能污染包名。
  #（踩过：写成 PDF Free-arm64.app，用户装完发现 app 名字带后缀。）
  APP="$WORK/$suffix/$APP_NAME.app"
  mkdir -p "$WORK/$suffix"
  assemble_app "$arch" "$APP"
  ok "组装 ${APP_NAME}.app（${arch}，$(du -h "$APP/Contents/MacOS/$APP_NAME" | cut -f1 | tr -d ' ')）"

  if [[ $ADHOC -eq 1 ]]; then
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" \
             --sign - "$APP" 2>&1 | sed 's/^/    /' || true
    warn "ad-hoc 签名（本机可用，不可分发）"
  else
    sign_app "$APP"
    ok "签名完成（Hardened Runtime + 时间戳）"
  fi

  if [[ $SIGN_ONLY -eq 1 ]]; then
    continue
  fi

  # ---- 先公证 app 本体，这样它身上会带票据，用户拖走 app 后离线也能过 ----
  if [[ $DO_NOTARIZE -eq 1 && $NOTARY_MODE == "app+dmg" ]]; then
    ZIP="$WORK/$APP_NAME-$suffix.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"     # 公证只收 zip/dmg/pkg
    notarize "$ZIP" "app ($arch)"
    staple_and_check "$APP"
    ok "票据已 staple 进 app"
    rm -f "$ZIP"
  fi

  # ---- 打 dmg（用上面那个已 staple 的 app）----
  DMG="$OUT_DIR/$APP_NAME-$VERSION-$suffix.dmg"
  VOL="$APP_NAME $VERSION$vol_suffix"
  make_dmg "$APP" "$DMG" "$VOL"
  ok "DMG 已生成：$(basename "$DMG")（$(du -h "$DMG" | cut -f1 | tr -d ' ')）"

  # ---- 签名 dmg（dmg 不需要 runtime 选项和 entitlements）----
  if [[ $ADHOC -eq 1 ]]; then
    codesign --force --sign - "$DMG" 2>&1 | sed 's/^/    /' || true
  else
    codesign --force --timestamp --sign "$IDENTITY" "$DMG" 2>&1 | sed 's/^/    /'
    codesign --verify --verbose=2 "$DMG" 2>&1 | sed 's/^/    /' || die "dmg 签名校验失败"
    ok "DMG 已签名"
  fi

  # ---- 公证 dmg + staple ----
  if [[ $DO_NOTARIZE -eq 1 ]]; then
    notarize "$DMG" "dmg ($arch)"
    staple_and_check "$DMG"
    ok "票据已 staple 进 dmg"
  fi

  PRODUCED+=("$DMG")
done

# ─────────────────────────────────────────────────────────────── 7. 收尾
if [[ $SIGN_ONLY -eq 1 ]]; then
  step "完成（--sign-only）"
  info "签名后的 app 在 $WORK/"
  exit 0
fi

step "4 / 7  校验"

# bash 3.2 对空数组做 "${arr[@]}" 展开会撞上 set -u，先确认有东西再往下走
[[ ${#PRODUCED[@]} -gt 0 ]] || die "一个 DMG 都没产出，前面哪步出问题了"

for dmg in "${PRODUCED[@]}"; do
  printf '  %s\n' "$(basename "$dmg")"

  # 挂载 → 检查里面的 app 签名 → 卸载
  MP="$WORK/mnt-$(basename "$dmg" .dmg)"
  rm -rf "$MP"; mkdir -p "$MP"
  if hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$MP" >/dev/null 2>&1; then
    inner="$MP/$APP_NAME.app"
    if [[ -d "$inner" ]]; then
      if codesign --verify --strict "$inner" >/dev/null 2>&1; then
        printf '    %s✓%s 包内 app 签名完整\n' "$C_G" "$C_0"
      else
        printf '    %s✗%s 包内 app 签名有问题\n' "$C_R" "$C_0"
      fi
      # 离线可验证的核心判据：票据在不在 app 身上
      if xcrun stapler validate "$inner" >/dev/null 2>&1; then
        printf '    %s✓%s app 自带公证票据（离线可验证）\n' "$C_G" "$C_0"
      else
        printf '    %s·%s app 无票据（用户需联网首次验证）\n' "$C_Y" "$C_0"
      fi
    else
      printf '    %s✗%s DMG 里找不到 %s.app，只有：%s\n' \
        "$C_R" "$C_0" "$APP_NAME" "$(ls "$MP" | tr '\n' ' ')"
    fi
    hdiutil detach "$MP" >/dev/null 2>&1 || true
  else
    printf '    %s!%s 挂载失败，跳过内部检查\n' "$C_Y" "$C_0"
  fi
  rm -rf "$MP"

  if [[ $DO_NOTARIZE -eq 1 ]]; then
    if xcrun stapler validate "$dmg" >/dev/null 2>&1; then
      printf '    %s✓%s dmg 自带公证票据\n' "$C_G" "$C_0"
    else
      printf '    %s✗%s dmg 没有票据\n' "$C_R" "$C_0"
    fi
    # Gatekeeper 视角：这才是用户双击时走的那条判定
    if spctl -a -vvv -t open --context context:primary-signature "$dmg" >/dev/null 2>&1; then
      printf '    %s✓%s Gatekeeper 放行\n' "$C_G" "$C_0"
    else
      printf '    %s!%s Gatekeeper 判定未通过（看下面输出）\n' "$C_Y" "$C_0"
      spctl -a -vvv -t open --context context:primary-signature "$dmg" 2>&1 | sed 's/^/      /' || true
    fi
  fi
done

step "5 / 7  校验和"
SUMS="$OUT_DIR/SHA256SUMS.txt"
: > "$SUMS"
for dmg in "${PRODUCED[@]}"; do
  ( cd "$OUT_DIR" && shasum -a 256 "$(basename "$dmg")" >> "$SUMS" )
done
ok "$(basename "$SUMS")"

step "6 / 7  清理"
if [[ $KEEP_WORK -eq 1 ]]; then
  info "中间产物保留在 ${WORK#$ROOT/}"
else
  rm -rf "$WORK"
fi

step "7 / 7  完成"
printf '\n  %s版本%s    %s (%s)\n' "$C_DIM" "$C_0" "$VERSION" "$BUILD_NUM"
printf '  %s签名%s    %s\n' "$C_DIM" "$C_0" "$IDENTITY"
printf '  %s公证%s    %s\n' "$C_DIM" "$C_0" "$( [[ $DO_NOTARIZE -eq 1 ]] && echo '已公证 + 已 staple' || echo '未公证' )"
printf '\n'
for dmg in "${PRODUCED[@]}"; do
  printf '  %s%s%s\n' "$C_B" "${dmg#$ROOT/}" "$C_0"
done
[[ -d "$OUT_DIR/dSYM" ]] && printf '  %s\n' "${OUT_DIR#$ROOT/}/dSYM/（崩溃符号化用）"
printf '\n'

if [[ $DO_NOTARIZE -eq 1 ]]; then
  printf '  %s用户拿到 dmg 后：双击打开 → 拖进「应用程序」→ 直接能跑，联网与否都不拦。%s\n' "$C_G" "$C_0"
fi
if [[ "$VERSION" != "$ORIG_SHORT" || "$BUILD_NUM" != "$ORIG_BUILD" ]]; then
  printf '  %sInfo.plist 里的版本号已更新（这是项目里版本的唯一来源）%s\n' "$C_DIM" "$C_0"
fi
printf '\n'
}

# ═══════════════════════════════════════════════════════════════════════════════
#  子命令分发（放最后：到这儿上面所有函数才定义齐）
# ═══════════════════════════════════════════════════════════════════════════════
case "$POSITIONAL" in
  setup-identity) cmd_setup_identity ;;
  setup-notary) cmd_setup_notary ;;
  doctor)       cmd_doctor ;;
  clean)        cmd_clean ;;
  "")           main ;;
  *)            die "不认识的子命令：${POSITIONAL}（用 --help 看看）" ;;
esac
