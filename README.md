# mimir

Instalação do **Grafana Mimir** em modo single-binary (`target: all`), pra
receber métricas via `remote_write` das VMs do homelab. Sem MinIO/S3: usa
`filesystem` como backend de storage, direto na PVC do pod - suficiente
pra escala de homelab, não recomendado em produção multi-tenant.

O Ingress expõe **só** o envio (`/api/v1/push`), e exige usuário e senha
(basic auth). O Mimir não tem autenticação própria, então sem isso
qualquer um na rede conseguia ler a config, consultar e gravar métricas.

A empresa separa o envio do mesmo jeito, mas com mTLS (certificado de
cliente) num gateway dedicado (`telemetry-agents`). Aqui a escolha foi
usuário e senha: protege igual nesse cenário (nos dois casos é um segredo
guardado em cada VM) e não vence, então não tem renovação anual pra
entregar nas VMs. Mesmo modelo do Grafana Cloud (o Alloy envia com usuário
e token).

## Pré-requisitos

- `Kubernetes` instalado
- `kubectl` instalado
- ArgoCD instalado (ver repositório `argocd`)
- `cert-manager` instalado (repositório `cert-manager`)
- `ingress-nginx` instalado (repositório `ingress-nginx`)
- DNS `mimir.diegofnunesbr.com` apontando pro node (ver repositório `dns`)

## Estrutura do repositório

```text
mimir/
├── applications/
│   └── argocd.mimir.yaml     # Application do Argo CD
├── mimir.yaml                # Namespace, ConfigMap, PVC, Deployment, Service, Ingress
├── mimir-push-auth.sealed.yaml     # hash da senha de envio (Ingress do Mimir confere)
├── alloy-push-password.sealed.yaml # a senha em si, na namespace rundeck (entregue às VMs)
├── change-push-password.sh   # gera/troca a senha de envio
└── README.md
```

## Instalar o Mimir

```bash
git clone https://github.com/diegofnunesbr/mimir.git
cd mimir
kubectl apply -f applications/argocd.mimir.yaml
```

**Lembrete:** a Application aponta pro GitHub (`repoURL`), não pro seu
clone local - qualquer mudança em `mimir.yaml` só tem efeito depois de
`git push` (e um sync, automático ou forçado via
`kubectl -n argocd patch application mimir --type merge -p '{"operation":{"sync":{}}}'`).

## Acesso

| Quem | Por onde | Autenticação |
|---|---|---|
| Alloy nas VMs (envio) | `https://mimir.diegofnunesbr.com/api/v1/push` | usuário `alloy` + senha (basic auth) |
| Grafana (consultas) | `http://mimir.mimir.svc:8080/prometheus`, direto pelo Service | nenhuma, só dentro do cluster |
| Você (debug, páginas de admin) | `kubectl --context=k0s -n mimir port-forward svc/mimir 8080:8080` e `http://localhost:8080` | acesso ao cluster |

O Ingress só roteia `/api/v1/push` (`pathType: Exact`), com basic auth
conferido contra o Secret `mimir-push-auth` (hash bcrypt). Sem senha ou
com senha errada volta 401; com a senha, qualquer caminho fora do envio
volta 404. Abrir o endereço no navegador não serve pra nada: quem usa ele
é o Alloy.

## Senha de envio

A senha não vence. Pra trocar (ou definir num cluster novo, com outra
chave do Sealed Secrets), rode do seu clone (precisa de `htpasswd`,
`kubeseal`, `openssl` e do contexto `k0s`, ver README do repositório
`argocd`, seção "Acessar o cluster de fora da VM"):

```bash
./change-push-password.sh 192.168.0.4 192.168.0.10
```

Ele gera uma senha aleatória (é senha de máquina, ninguém digita), sela os
dois Secrets, faz commit + push e espera o Argo CD. Com os IPs das VMs,
ele também espera a senha nova chegar no pod do Rundeck e reinstala o
Alloy em cada VM (mesmo playbook do job `install-alloy`). Sem IPs, só
troca a senha e avisa pra rodar o job `install-alloy` depois. Entre a
troca e a reinstalação, as VMs ficam alguns minutos sem conseguir enviar.
Detalhes da entrega pras VMs: repositório `rundeck`, seção "Senha de envio
do Alloy pro Mimir".

## Verificar

```bash
kubectl --context=k0s -n mimir port-forward svc/mimir 8080:8080 &
curl -s -G 'http://localhost:8080/prometheus/api/v1/query' \
  --data-urlencode 'query=up{host="<ip-da-vm-onboardada>"}'
```

Resultado esperado: `"status":"success"` com um vetor não vazio. Se vier
`"error":"too many unhealthy instances in the ring"`, é porque
`replication_factor` do `ingester`/`store_gateway` está diferente de `1` -
esse manifesto já sobe com `replication_factor: 1` porque só existe uma
réplica; se algum dia aumentar `spec.replicas` no Deployment, ajuste esse
valor junto.

## Remover o Mimir

```bash
cd mimir
kubectl delete -f applications/argocd.mimir.yaml
kubectl delete namespace mimir --ignore-not-found
```

Isso também apaga as métricas armazenadas (a PVC fica presa ao namespace).
