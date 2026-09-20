# mimir

Instalação do **Grafana Mimir** em modo single-binary (`target: all`), pra
receber métricas via `remote_write` das VMs do homelab. Sem MinIO/S3: usa
`filesystem` como backend de storage, direto na PVC do pod - suficiente
pra escala de homelab, não recomendado em produção multi-tenant.

Diferente da stack real da empresa (Mimir multi-tenant + Alloy com mTLS via
gateway dedicado), aqui o Alloy manda direto pro Service do Mimir, sem TLS
nem autenticação - a rede do homelab já é a fronteira de confiança.

## Pré-requisitos

- `Kubernetes` instalado
- `kubectl` instalado
- ArgoCD instalado (ver repositório `argocd`)

## Estrutura do repositório

```text
mimir/
├── applications/
│   └── argocd.mimir.yaml     # Application do Argo CD
├── mimir.yaml                # Namespace, ConfigMap, PVC, Deployment, Service
└── README.md
```

## Instalar o Mimir

```bash
git clone https://github.com/diegofnunesbr/mimir.git
cd mimir
kubectl apply -f applications/argocd.mimir.yaml
```

## Endpoint de ingestão

O Service é `NodePort` (porta `30900`) porque quem envia métricas via
`remote_write` são as VMs do homelab via Alloy, que estão fora do
cluster - de dentro do cluster, o Service também responde em
`mimir.observability.svc:8080`.

De fora do cluster (Alloy nas VMs onboardadas pelo Rundeck):

```text
http://<ip-do-node-k0s>:30900/api/v1/push
```

De dentro do cluster (datasource do Grafana, Prometheus-compatible):

```text
http://mimir.observability.svc:8080/prometheus
```

## Remover o Mimir

```bash
cd mimir
kubectl delete -f applications/argocd.mimir.yaml
kubectl delete namespace observability --ignore-not-found
```

Isso também apaga as métricas armazenadas (a PVC fica presa ao namespace).
