#!/usr/bin/env bash
# release.sh - versiona o app, cria a tag e envia ao GitHub.
# O build e a publicação da release rodam no GitHub Actions (workflow release.yml),
# disparado pela tag vX.Y.Z enviada por este script.
#
# Uso: ./release.sh [--skip-checks] [--dry-run]
#   --skip-checks  não roda flutter analyze / flutter test antes de lançar
#   --dry-run      mostra o que seria feito, sem alterar nada
set -euo pipefail

SKIP_CHECKS=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --skip-checks) SKIP_CHECKS=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Opção desconhecida: $arg (use --help)"; exit 1 ;;
  esac
done

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
info() { echo "${BLD}$*${RST}"; }
ok()   { echo "${GRN}✓ $*${RST}"; }
warn() { echo "${YEL}! $*${RST}"; }
die()  { echo "${RED}✗ $*${RST}" >&2; exit 1; }

# Executa o comando, ou apenas o exibe no modo --dry-run.
run() {
  if [ "$DRY_RUN" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi
}

# ask_yes_no "pergunta" [s|n]  -> retorna 0 para sim
ask_yes_no() {
  local def="${2:-n}" hint ans
  if [ "$def" = s ]; then hint="[S/n]"; else hint="[s/N]"; fi
  read -r -p "$1 $hint " ans || ans=""
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[sSyY]$ ]]
}

# ---------- 1. Verificações do repositório ----------
top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Execute dentro de um repositório git."
cd "$top"
[ -f pubspec.yaml ] || die "pubspec.yaml não encontrado na raiz do repositório."
git remote get-url origin >/dev/null 2>&1 || die "Remote 'origin' não configurado."

branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" != "HEAD" ] || die "HEAD destacado: entre em uma branch antes de lançar."
if [[ "$branch" != "main" && "$branch" != "master" ]]; then
  warn "Você está na branch '$branch' (não é main/master)."
  ask_yes_no "Continuar mesmo assim?" n || exit 1
fi

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  git status --short --untracked-files=no
  die "Há alterações não commitadas. Faça commit (ou stash) antes de lançar."
fi

info "Sincronizando com o GitHub..."
git fetch --tags origin >/dev/null 2>&1 || die "Falha ao consultar o GitHub (git fetch). Verifique a conexão."

if upstream="$(git rev-parse --abbrev-ref '@{u}' 2>/dev/null)"; then
  behind="$(git rev-list --count "HEAD..$upstream")"
  [ "$behind" -eq 0 ] || die "Sua branch está $behind commit(s) atrás de $upstream. Rode: git pull"
fi

# ---------- 2. Última versão ----------
SEMVER='^v[0-9]+\.[0-9]+\.[0-9]+$'
last_tag="$(git tag -l 'v*' --sort=-v:refname | grep -E "$SEMVER" | head -n1 || true)"

gh_last=""; gh_drafts=""
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh_last="$(gh release list --exclude-drafts --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || true)"
  gh_drafts="$(gh release list --limit 20 --json tagName,isDraft -q '.[] | select(.isDraft) | .tagName' 2>/dev/null || true)"
fi

cur_line="$(grep -E '^version:' pubspec.yaml | head -n1 || true)"
[ -n "$cur_line" ] || die "Linha 'version:' não encontrada no pubspec.yaml."
cur_full="$(echo "$cur_line" | sed -E 's/^version:[[:space:]]*//; s/[[:space:]]+#.*$//' | tr -d '\r[:space:]')"
cur_name="${cur_full%%+*}"
cur_build=0
if [[ "$cur_full" == *+* ]]; then cur_build="${cur_full##*+}"; fi
[[ "$cur_build" =~ ^[0-9]+$ ]] || cur_build=0

echo
info "Versões atuais"
echo "  Última tag:               ${last_tag:-nenhuma}"
if [ -n "$gh_last" ]; then
  echo "  Última release publicada: $gh_last"
else
  echo "  Última release publicada: (indisponível; instale e autentique o 'gh' para ver)"
fi
echo "  pubspec.yaml:             $cur_full"
if [ -n "$gh_drafts" ]; then
  warn "Há release(s) em rascunho: $(echo "$gh_drafts" | tr '\n' ' ')(build em andamento ou que falhou)."
fi
echo

# ---------- 3. Nova versão ----------
if [ -n "$last_tag" ]; then
  IFS=. read -r maj min pat <<<"${last_tag#v}"
  suggested="$maj.$min.$((pat + 1))"
elif [[ "$cur_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  suggested="$cur_name"
else
  suggested="1.0.0"
fi

while true; do
  read -r -e -i "$suggested" -p "Nova versão (X.Y.Z): " new_input || die "Entrada cancelada."
  new_version="$(echo "$new_input" | tr -d '[:space:]')"
  new_version="${new_version#v}"

  if ! [[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    warn "Formato inválido. Use X.Y.Z (ex.: 1.2.3)."; continue
  fi
  tag="v$new_version"
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    warn "A tag $tag já existe localmente."; continue
  fi
  if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    warn "A tag $tag já existe no GitHub."; continue
  fi
  if [ -n "$last_tag" ] && [ "$new_version" != "${last_tag#v}" ]; then
    highest="$(printf '%s\n%s\n' "${last_tag#v}" "$new_version" | sort -V | tail -n1)"
    if [ "$highest" != "$new_version" ]; then
      warn "A versão $new_version é MENOR que a última ($last_tag)."
      ask_yes_no "Usar mesmo assim?" n || continue
    fi
  fi
  break
done

new_build=$((cur_build + 1))
new_pubspec="$new_version+$new_build"

# ---------- 4. Confirmação ----------
echo
info "Resumo"
echo "  Branch:           $branch"
echo "  Última versão:    ${last_tag:-nenhuma}"
echo "  Nova versão:      $tag"
echo "  pubspec.yaml:     $cur_full  ->  $new_pubspec"
echo "  Ações:            commit do pubspec.yaml, tag $tag, push da branch e da tag"
echo "  Depois:           o GitHub Actions compila (Linux e Windows) e publica a release"
[ "$DRY_RUN" = 1 ] && warn "Modo --dry-run: nada será alterado."
echo
ask_yes_no "Confirmar e publicar?" n || { echo "Cancelado. Nada foi alterado."; exit 0; }

# ---------- 5. Verificações locais (antes de alterar qualquer coisa) ----------
if [ "$SKIP_CHECKS" = 0 ]; then
  if command -v flutter >/dev/null 2>&1; then
    info "Rodando flutter analyze e flutter test..."
    flutter analyze || die "flutter analyze falhou. Nada foi alterado."
    flutter test || die "flutter test falhou. Nada foi alterado."
    ok "Verificações locais passaram."
  else
    warn "flutter não encontrado no PATH; pulando verificações locais."
  fi
fi

# ---------- 6. Commit, tag e push ----------
run sed -i -E "s/^version:.*/version: $new_pubspec/" pubspec.yaml
if [ "$DRY_RUN" = 1 ] || ! git diff --quiet -- pubspec.yaml; then
  run git commit -m "Versão $new_version" -- pubspec.yaml
fi
run git tag -a "$tag" -m "Versão $new_version"

if ! run git push origin HEAD "$tag"; then
  warn "O push falhou. O commit e a tag existem apenas localmente."
  echo "  Para tentar de novo:  git push origin HEAD $tag"
  echo "  Para desfazer:        git tag -d $tag && git reset --soft HEAD~1"
  exit 1
fi
if [ "$DRY_RUN" = 1 ]; then ok "Dry-run concluído: nada foi alterado."; exit 0; fi
ok "Tag $tag enviada ao GitHub."

# ---------- 7. Acompanhar o build ----------
slug="$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
echo
echo "  Build:    https://github.com/$slug/actions"
echo "  Release:  https://github.com/$slug/releases/tag/$tag"

if [ "$DRY_RUN" = 0 ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  echo
  if ask_yes_no "Acompanhar o build agora?" s; then
    sleep 6
    run_id="$(gh run list --workflow release.yml --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
    if [ -n "$run_id" ]; then
      gh run watch "$run_id" --exit-status && ok "Release $tag publicada." \
        || warn "O build falhou. Veja o log em: https://github.com/$slug/actions/runs/$run_id"
    else
      warn "Não encontrei a execução do workflow. Confira na aba Actions."
    fi
  fi
fi
