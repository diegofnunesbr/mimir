# mimir

Instalação do **Grafana Mimir** em modo single-binary (`target: all`), pra
receber métricas via `remote_write` das VMs do homelab. Sem MinIO/S3: usa
`filesystem` como backend de storage, direto na PVC do pod - suficiente
pra escala de homelab, não recomendado em produção multi-tenant.

O Ingress deixa o domínio inteiro aberto, sem login: página inicial,
config, status, consultas e envio. É uma escolha consciente pro homelab
(a rede de casa é a fronteira de confiança). O Mimir não tem autenticação
própria, então qualquer aparelho na rede consegue ler e gravar métricas.
Na empresa é diferente: os agentes enviam pra um gateway dedicado
(`telemetry-agents`) com certificado de cliente (mTLS), e as consultas
passam só pelo Grafana. Se um dia quiser fechar aqui, o caminho é
restringir o Ingress e pôr autenticação no envio (basic auth ou mTLS).

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

| Quem | Por onde |
|---|---|
| Alloy nas VMs (envio) | `https://mimir.diegofnunesbr.com/api/v1/push` |
| Grafana (consultas) | `http://mimir.mimir.svc:8080/prometheus`, direto pelo Service (não sai do cluster) |
| Você (página de admin, config, consultas) | `https://mimir.diegofnunesbr.com` |

## Verificar

```bash
curl -s -G 'https://mimir.diegofnunesbr.com/prometheus/api/v1/query' \
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
