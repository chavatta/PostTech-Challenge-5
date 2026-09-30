#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 05b - AIOps no New Relic (Applied Intelligence), como código e idempotente (NerdGraph):
#   1) policy "SolidaryTech SRE"
#   2) condições de ANOMALIA (baseline, sem limiar fixo) para as Golden Metrics dos 3 serviços:
#      throughput, taxa de erro e tempo de resposta (FACET appName)
#   3) condições de SLO espelhando o Prometheus: burn rate de erro (1,44 % = 14,4 x 0,1 %) com signal loss,
#      e latência p99 > 500 ms
#   4) workflow "sre-oncall": issues críticos da policy -> e-mail do usuário dono da key, com enrichment NRQL
#   5) Service Levels nativos do donation-service: disponibilidade 99,9 % e latência 99 % < 250 ms (28 dias)
# Rodar uma vez por conta New Relic (não depende do cluster; pode rodar antes da Etapa 4).
# Uso: NEW_RELIC_API_KEY=NRAK-... NEW_RELIC_ACCOUNT_ID=1234567 scripts/05-newrelic-aiops.sh
#      (User key: New Relic -> API keys -> Create a key -> tipo User. NÃO é a license key INGEST.)
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
[ -n "${NEW_RELIC_API_KEY:-}" ] || fail "exporte NEW_RELIC_API_KEY (User key NRAK-..., New Relic -> API keys)"
[ -n "${NEW_RELIC_ACCOUNT_ID:-}" ] || fail "exporte NEW_RELIC_ACCOUNT_ID (número da conta, aparece em New Relic -> Administration)"
# espaço/CR de copiar e colar (terminal do Windows) invalidam a key sem mensagem clara
export NEW_RELIC_API_KEY="$(printf '%s' "$NEW_RELIC_API_KEY" | tr -d '[:space:]')"
export NEW_RELIC_ACCOUNT_ID="$(printf '%s' "$NEW_RELIC_ACCOUNT_ID" | tr -d '[:space:]')"
# as duas keys ficam na mesma tela do New Relic: a license (INGEST, termina em NRAL) só envia dados, não configura nada
case "$NEW_RELIC_API_KEY" in
  NRAK-*) ;;
  *NRAL) fail "NEW_RELIC_API_KEY é a license key (INGEST, termina em NRAL). Aqui é a User key: API keys -> Create a key -> Key type: User (começa com NRAK-)" ;;
  *) fail "NEW_RELIC_API_KEY não parece uma User key (deveria começar com NRAK-)" ;;
esac

step "Aplicando AIOps via NerdGraph (policy, anomalias, SLO, workflow, service levels)" \
     "configuração de alerta também é código: reproduzível no ambiente 2 e revisável no git, nada clicado"
python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request

API = os.environ.get("NEW_RELIC_NERDGRAPH_URL", "https://api.newrelic.com/graphql")
KEY = os.environ["NEW_RELIC_API_KEY"]
ACC = int(os.environ["NEW_RELIC_ACCOUNT_ID"])
POLICY = "SolidaryTech SRE"
APP = "solidarytech-donation-service"
RUNBOOK = "https://github.com/chavatta/PostTech-Challenge-5/blob/main/docs/ITSM.md#runbook-donation-5xx"
SIGNAL = {"aggregationWindow": 60, "aggregationMethod": "EVENT_FLOW", "aggregationDelay": 120}

def gql(query, **variables):
    req = urllib.request.Request(API, json.dumps({"query": query, "variables": variables}).encode(),
                                 {"Content-Type": "application/json", "API-Key": KEY})
    try:
        body = json.load(urllib.request.urlopen(req, timeout=30))
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            sys.exit(f"\033[1;31m    ✖ New Relic recusou a key (HTTP {e.code}). Causas comuns: key revogada; key de um usuário sem acesso "
                     f"à conta {ACC} (User keys são pessoais: peça convite na conta ou use a key de quem é membro); conta na "
                     f"região EU (export NEW_RELIC_NERDGRAPH_URL=https://api.eu.newrelic.com/graphql)\033[0m")
        raise
    if body.get("errors"):
        sys.exit("NerdGraph: " + json.dumps(body["errors"], ensure_ascii=False))
    return body["data"]

def ok(msg): print(f"\033[1;32m    ✔ {msg}\033[0m")

# 1) policy (por condição: cada sinal abre o seu incidente; o Incident Intelligence correlaciona em 1 Issue)
pol = gql("""query($a:Int!,$n:String){actor{account(id:$a){alerts{policiesSearch(searchCriteria:{name:$n}){policies{id name}}}}}}""",
          a=ACC, n=POLICY)["actor"]["account"]["alerts"]["policiesSearch"]["policies"]
pol = [p for p in pol if p["name"] == POLICY]
if pol:
    pid = pol[0]["id"]; ok(f"policy '{POLICY}' já existe (id {pid})")
else:
    pid = gql("""mutation($a:Int!,$p:AlertsPolicyInput!){alertsPolicyCreate(accountId:$a,policy:$p){id}}""",
              a=ACC, p={"name": POLICY, "incidentPreference": "PER_CONDITION"})["alertsPolicyCreate"]["id"]
    ok(f"policy '{POLICY}' criada (id {pid})")

existing = {c["name"] for c in gql("""query($a:Int!,$p:ID){actor{account(id:$a){alerts{nrqlConditionsSearch(searchCriteria:{policyId:$p}){nrqlConditions{name}}}}}}""",
                                  a=ACC, p=pid)["actor"]["account"]["alerts"]["nrqlConditionsSearch"]["nrqlConditions"]}

def condition(kind, c):
    if c["name"] in existing:
        return ok(f"condição já existe: {c['name']}")
    m = {"baseline": "alertsNrqlConditionBaselineCreate(accountId:$a,policyId:$p,condition:$c)",
         "static": "alertsNrqlConditionStaticCreate(accountId:$a,policyId:$p,condition:$c)"}[kind]
    t = {"baseline": "AlertsNrqlConditionBaselineInput!", "static": "AlertsNrqlConditionStaticInput!"}[kind]
    gql(f"mutation($a:Int!,$p:ID!,$c:{t}){{{m}{{id}}}}", a=ACC, p=pid, c=c)
    ok(f"condição criada: {c['name']}")

# 2) anomalias (baseline): o modelo aprende o comportamento normal de cada serviço; 3 desvios-padrão por 5 min
anomalias = [
    ("anomalia de throughput", "SELECT rate(count(*), 1 minute) FROM Transaction", "UPPER_AND_LOWER"),
    ("anomalia de taxa de erro", "SELECT percentage(count(*), WHERE error IS true) FROM Transaction", "UPPER_ONLY"),
    ("anomalia de tempo de resposta", "SELECT average(duration) FROM Transaction", "UPPER_ONLY"),
]
for nome, sel, direcao in anomalias:
    condition("baseline", {
        "name": f"AIOps: {nome} (solidarytech-*)", "enabled": True, "baselineDirection": direcao,
        "nrql": {"query": f"{sel} WHERE appName LIKE 'solidarytech-%' FACET appName"},
        "signal": SIGNAL, "runbookUrl": RUNBOOK,
        "terms": [{"threshold": 3, "thresholdOccurrences": "ALL", "thresholdDuration": 300,
                   "operator": "ABOVE", "priority": "CRITICAL"}]})

# 3) SLO: mesmos números dos alertas do Prometheus (docs/SRE.md)
condition("static", {
    "name": "SLO: burn rate de erro do donation-service (> 14,4x o budget)", "enabled": True,
    "nrql": {"query": f"SELECT percentage(count(*), WHERE error IS true) FROM Transaction WHERE appName = '{APP}'"},
    "signal": SIGNAL, "runbookUrl": RUNBOOK,
    # signal loss: serviço sem enviar nada por 5 min também é incidente (pod morto não gera erro, gera silêncio)
    "expiration": {"expirationDuration": 300, "openViolationOnExpiration": True, "closeViolationsOnExpiration": False},
    "terms": [{"threshold": 1.44, "thresholdOccurrences": "ALL", "thresholdDuration": 300, "operator": "ABOVE", "priority": "CRITICAL"},
              {"threshold": 0.6, "thresholdOccurrences": "ALL", "thresholdDuration": 1800, "operator": "ABOVE", "priority": "WARNING"}]})
condition("static", {
    "name": "SLO: latência p99 do donation-service > 500 ms", "enabled": True,
    "nrql": {"query": f"SELECT percentile(duration, 99) FROM Transaction WHERE appName = '{APP}'"},
    "signal": SIGNAL, "runbookUrl": RUNBOOK,
    "terms": [{"threshold": 0.5, "thresholdOccurrences": "ALL", "thresholdDuration": 300, "operator": "ABOVE", "priority": "CRITICAL"}]})

# 4) workflow: destino = e-mail do próprio dono da key (nada vai para terceiros)
email = gql("{actor{user{email}}}")["actor"]["user"]["email"]
wf = gql("""query($a:Int!){actor{account(id:$a){aiWorkflows{workflows(filters:{name:"sre-oncall"}){entities{id name}}}}}}""",
         a=ACC)["actor"]["account"]["aiWorkflows"]["workflows"]["entities"]
if wf:
    ok("workflow 'sre-oncall' já existe")
else:
    # destino e canal são reaproveitados pelo nome: uma execução anterior pode ter parado depois de criá-los
    notif = gql("""query($a:Int!){actor{account(id:$a){aiNotifications{
                     destinations(filters:{name:"SolidaryTech on-call (e-mail)"}){entities{id}}
                     channels(filters:{name:"sre-oncall-email"}){entities{id}}}}}}""", a=ACC)["actor"]["account"]["aiNotifications"]
    if notif["channels"]["entities"]:
        chan_id = notif["channels"]["entities"][0]["id"]
    else:
        if notif["destinations"]["entities"]:
            dest_id = notif["destinations"]["entities"][0]["id"]
        else:
            dest = gql("""mutation($a:Int!,$d:AiNotificationsDestinationInput!){aiNotificationsCreateDestination(accountId:$a,destination:$d){destination{id} error{... on AiNotificationsResponseError{description}}}}""",
                       a=ACC, d={"type": "EMAIL", "name": "SolidaryTech on-call (e-mail)",
                                 "properties": [{"key": "email", "value": email}]})["aiNotificationsCreateDestination"]
            if not dest.get("destination"): sys.exit(f"destino: {dest}")
            dest_id = dest["destination"]["id"]
        chan = gql("""mutation($a:Int!,$c:AiNotificationsChannelInput!){aiNotificationsCreateChannel(accountId:$a,channel:$c){channel{id} error{... on AiNotificationsResponseError{description}}}}""",
                   a=ACC, c={"type": "EMAIL", "name": "sre-oncall-email", "destinationId": dest_id, "product": "IINT",
                             "properties": [{"key": "subject", "value": "[SolidaryTech] {{ issueTitle }}"}]})["aiNotificationsCreateChannel"]
        if not chan.get("channel"): sys.exit(f"canal: {chan}")
        chan_id = chan["channel"]["id"]
    workflow = {"name": "sre-oncall", "workflowEnabled": True, "destinationsEnabled": True,
                "mutingRulesHandling": "NOTIFY_ALL_ISSUES", "enrichmentsEnabled": True,
                "issuesFilter": {"name": "criticos-solidarytech", "type": "FILTER", "predicates": [
                    {"attribute": "labels.policyIds", "operator": "EXACTLY_MATCHES", "values": [str(pid)]},
                    {"attribute": "priority", "operator": "EQUAL", "values": ["CRITICAL"]}]},
                "destinationConfigurations": [{"channelId": chan_id}],
                # enrichment: o e-mail do alerta já chega com os erros recentes (contexto para o runbook)
                "enrichments": {"nrql": [{"name": "Erros recentes do donation-service", "configuration": [{
                    "query": f"SELECT count(*) FROM TransactionError WHERE appName = '{APP}' FACET error.message SINCE 30 minutes ago"}]}]}}
    create = """mutation($a:Int!,$w:AiWorkflowsCreateWorkflowInput!){aiWorkflowsCreateWorkflow(accountId:$a,createWorkflowData:$w){workflow{id} errors{description type}}}"""
    r = gql(create, a=ACC, w=workflow)["aiWorkflowsCreateWorkflow"]
    extra = ", com enrichment NRQL"
    if any(e.get("type") == "MISSING_ENTITLEMENT" for e in r.get("errors") or []):
        # plano gratuito do New Relic não inclui enrichments (visto na conta do projeto): cria sem, o resto é igual
        workflow.pop("enrichments"); workflow["enrichmentsEnabled"] = False
        r = gql(create, a=ACC, w=workflow)["aiWorkflowsCreateWorkflow"]; extra = " (sem enrichment: não incluído no plano da conta)"
    if r.get("errors"): sys.exit(f"workflow: {r['errors']}")
    ok(f"workflow 'sre-oncall' criado (críticos -> {email}){extra}")

# 5) Service Levels nativos (segunda fonte do SLO, além do Grafana)
ent = gql("""query($q:String!){actor{entitySearch(query:$q){results{entities{guid name}}}}}""",
          q=f"name = '{APP}' AND domain = 'APM' AND accountId = {ACC}")["actor"]["entitySearch"]["results"]["entities"]
if not ent:
    sys.exit(f"entidade APM '{APP}' não encontrada: rode a Etapa 5 (agentes reportando) antes dos service levels")
guid = ent[0]["guid"]
have = {s["name"] for s in (gql("""query($g:EntityGuid!){actor{entity(guid:$g){serviceLevel{indicators{name}}}}}""", g=guid)
                            ["actor"]["entity"]["serviceLevel"] or {}).get("indicators", [])}
slis = [
    ("donation-service: disponibilidade", "Requisições sem erro / total (espelha o SLO de 99,9 % do docs/SRE.md)",
     {"accountId": ACC, "validEvents": {"from": "Transaction", "where": f"appName = '{APP}'"},
      "badEvents": {"from": "Transaction", "where": f"appName = '{APP}' AND error IS true"}}, 99.9),
    ("donation-service: latência < 250 ms", "Requisições atendidas em menos de 250 ms / total",
     {"accountId": ACC, "validEvents": {"from": "Transaction", "where": f"appName = '{APP}'"},
      "goodEvents": {"from": "Transaction", "where": f"appName = '{APP}' AND duration < 0.25"}}, 99.0),
]
for nome, desc, events, alvo in slis:
    if nome in have:
        ok(f"service level já existe: {nome}"); continue
    gql("""mutation($g:EntityGuid!,$i:ServiceLevelIndicatorCreateInput!){serviceLevelCreate(entityGuid:$g,indicator:$i){id}}""",
        g=guid, i={"name": nome, "description": desc, "events": events,
                   "objectives": [{"target": alvo, "timeWindow": {"rolling": {"count": 28, "unit": "DAY"}}}]})
    ok(f"service level criado: {nome} ({alvo} % em 28 dias)")
PY
ok "AIOps configurado: Alerts -> Alert conditions / Workflows; APM -> solidarytech-donation-service -> Service levels"
