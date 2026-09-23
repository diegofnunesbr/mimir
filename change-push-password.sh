#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

CTX="${KUBE_CONTEXT:-k0s}"
K="kubectl --context=$CTX"
SEAL="kubeseal --context $CTX --controller-name sealed-secrets --controller-namespace kube-system --scope cluster-wide --format yaml"
$K -n mimir get deploy mimir >/dev/null || { echo "Sem acesso ao Mimir pelo contexto '$CTX' (ver README do repositório argocd, seção do kubeconfig)."; exit 1; }

PW=$(openssl rand -hex 24)
HASH=$(printf '%s' "$PW" | htpasswd -niB alloy)

git pull --ff-only

cat <<EOF | $SEAL > mimir-push-auth.sealed.yaml
apiVersion: v1
kind: Secret
metadata:
  name: mimir-push-auth
  namespace: mimir
type: Opaque
data:
  auth: $(printf '%s' "$HASH" | base64 -w0)
EOF

cat <<EOF | $SEAL > alloy-push-password.sealed.yaml
apiVersion: v1
kind: Secret
metadata:
  name: alloy-push-password
  namespace: rundeck
type: Opaque
data:
  password: $(printf '%s' "$PW" | base64 -w0)
EOF

git add mimir-push-auth.sealed.yaml alloy-push-password.sealed.yaml
git commit -m "rotate mimir push password"
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
echo "Senha nova no Mimir. A partir de agora as VMs só conseguem enviar depois de receberem a senha nova."

if [ $# -eq 0 ]; then
  echo "Rode o job install-alloy do Rundeck em cada VM que envia métricas,"
  echo "ou rode este script de novo passando os IPs: ./change-push-password.sh 192.168.0.4 192.168.0.10"
  exit 0
fi

echo "Aguardando a senha nova chegar no pod do Rundeck..."
for _ in $(seq 1 60); do
  CUR=$($K -n rundeck exec deploy/rundeck -- cat /etc/alloy-push-password/password 2>/dev/null || true)
  [ "$CUR" = "$PW" ] && break
  sleep 5
done
[ "$CUR" = "$PW" ] || { echo "A senha nova não chegou no pod do Rundeck a tempo. Rode o job install-alloy depois."; exit 1; }
unset CUR

for HOST in "$@"; do
  echo "==> install-alloy em $HOST"
  $K -n rundeck exec deploy/rundeck -- sh -c "cd /home/rundeck/ansible && ansible-playbook -i /home/rundeck/inventory/hosts install-alloy.yml -e target_hosts=$HOST -u rundeck --private-key /home/rundeck/.ssh/rundeck -b" \
    | grep -E "PLAY RECAP|failed=|fatal" || true
done
echo "Pronto."
