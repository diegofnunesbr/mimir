#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

CTX="${KUBE_CONTEXT:-k0s}"
K="kubectl --context=$CTX"
SEALED=mimir-auth.sealed.yaml
$K -n mimir get deploy mimir >/dev/null || { echo "Sem acesso ao Mimir pelo contexto '$CTX' (ver README do repositório argocd, seção do kubeconfig)."; exit 1; }

read -rp "Usuário [diegofnunesbr]: " USERNAME
USERNAME="${USERNAME:-diegofnunesbr}"
[[ "$USERNAME" =~ ^[a-zA-Z0-9._-]+$ && "$USERNAME" != "alloy" ]] || { echo "Usuário inválido (só letras, números, . _ -, e não pode ser 'alloy', que é o das VMs)."; exit 1; }
read -rsp "Nova senha do Mimir: " PW; echo
read -rsp "Confirme a senha: " PW2; echo
[ -n "$PW" ] && [ "$PW" = "$PW2" ] || { echo "Senhas vazias ou diferentes."; exit 1; }

HASH=$(printf '%s' "$PW" | htpasswd -niB "$USERNAME")

git pull --ff-only

OTHERS=$($K -n mimir get secret mimir-auth -o jsonpath='{.data.auth}' 2>/dev/null | base64 -d | grep -v "^$USERNAME:" || true)
AUTH=$(printf '%s\n%s\n' "$HASH" "$OTHERS" | sed '/^$/d')

cat <<EOF | kubeseal --context "$CTX" --controller-name sealed-secrets --controller-namespace kube-system \
  --scope cluster-wide --format yaml > "$SEALED"
apiVersion: v1
kind: Secret
metadata:
  name: mimir-auth
  namespace: mimir
type: Opaque
data:
  auth: $(printf '%s\n' "$AUTH" | base64 -w0)
EOF

git add "$SEALED"
git commit -m "rotate mimir login password"
git push

REV=$(git rev-parse HEAD)
$K -n argocd annotate application mimir argocd.argoproj.io/refresh=hard --overwrite >/dev/null
echo "Aguardando o Argo CD sincronizar $REV..."
STATUS=""
for _ in $(seq 1 60); do
  STATUS=$($K -n argocd get application mimir -o jsonpath='{.status.sync.status} {.status.sync.revision}')
  [[ "$STATUS" == "Synced $REV" ]] && break
  sleep 5
done
[[ "$STATUS" == "Synced $REV" ]] || { echo "Timeout esperando o sync."; exit 1; }
echo "Pronto. Em ~30s: https://mimir.diegofnunesbr.com com $USERNAME + a senha nova."
