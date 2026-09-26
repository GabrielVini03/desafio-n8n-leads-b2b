# Pipeline de Processamento e Enriquecimento de Leads B2B — n8n

Fluxo em **n8n** que recebe leads corporativos via Webhook, higieniza e valida os dados,
barra reenvios duplicados, enriquece com **ViaCEP** e **BrasilAPI**, roteia por Unidade
Federativa, grava o resultado no **PostgreSQL**, responde de forma síncrona ao cliente HTTP
e envia um alerta no **Telegram**. Falhas de terceiros são toleradas com timeout, retry e
dados parciais; falhas não tratadas caem num **Error Workflow** dedicado.

🎥 **Vídeo de demonstração:** _adicionar link aqui_

### Início rápido

Pré-requisitos: Docker com Compose v2, bash, curl e a porta 5678 livre.

```bash
bash scripts/setup.sh    # sobe n8n + PostgreSQL, importa e ativa os workflows (~5 min na 1ª vez)
bash scripts/testar.sh   # 13 cenários; esperado: "Resultado: 13 passaram, 0 falharam"
```

UI em **http://localhost:5678** · Webhook em `POST http://localhost:5678/webhook/lead-b2b` ·
passo a passo completo, com o que conferir em cada etapa, na [seção 4](#4-guia-de-replicação-passo-a-passo).

---

## 1. O que foi implementado

| Requisito | Onde está |
|---|---|
| 4.1 Webhook POST; 400 para corpo vazio, JSON malformado ou campo ausente | `Receber Lead B2B` → `Validar Estrutura do Payload` |
| 4.2 Trim, normalização de CEP, CNPJ (módulo 11 + sequências repetidas), e-mail por regex; 400 indicando a chave | `Sanitizar e Validar Dados` |
| 4.3 ViaCEP + BrasilAPI com tolerância a falhas e `enriquecimento_incompleto` | `Consultar ViaCEP` / `Consultar BrasilAPI` + nós `Tratar Falha …` |
| 4.4 Roteamento Sul/Sudeste · Geral · exceção operacional registrada | `UF identificada?` → `Roteamento por UF` / `Registrar Exceção de Localização` |
| 4.5 Resposta síncrona com roteamento, município, UF e situação cadastral | `Responder ao Cliente` |
| 4.6 Error Workflow, retry com espera, nunca sem resposta | `Lead B2B - Error Workflow`; retry e timeout nos nós HTTP |
| 4.7 Nomes semânticos, canvas em 5 seções, endpoints e segredos via variáveis de ambiente | Sticky notes ①–⑤; `.env` |
| **Diferencial:** idempotência | `Verificar Duplicidade` → `Lead Novo?` (409) |
| **Diferencial:** persistência relacional | `Gravar Lead no Banco` (PostgreSQL), [modelo de dados](#8-modelo-de-dados) |
| **Diferencial:** notificação | `Notificar Novo Lead no Telegram` + alerta no Error Workflow |
| **Diferencial:** memorial de decisões | [Seção 11](#11-memorial-de-decisões-técnicas) |

---

## 2. Arquitetura

```
① ENTRADA E VALIDAÇÃO
Webhook POST /lead-b2b (corpo cru)
  → Validar Estrutura do Payload ── inválido ──► 400 (JSON malformado / campo ausente)
  → Sanitizar e Validar Dados ───── inválido ──► 400 (campo que reprovou)

② IDEMPOTÊNCIA
  → Verificar Duplicidade (Postgres) ── mesmo CNPJ na janela ──► 409
        └─ banco indisponível ──► segue adiante (fail-open)

③ ENRIQUECIMENTO                       (timeout 5 s · 3 tentativas · espera 2 s)
  → Consultar ViaCEP ──── falha ──► Tratar Falha ViaCEP ────┐
  → Consultar BrasilAPI ─ falha ──► Tratar Falha BrasilAPI ─┤  enriquecimento_incompleto: true
                                                            ▼
④ ROTEAMENTO
  → UF identificada? ── não ──► Registrar Exceção de Localização ─────────┐
        └─ sim ─► Roteamento por UF ─► SP/RJ/MG/ES → Sul/Sudeste         │
                                     └► demais UFs → Geral               │
                                                                          ▼
⑤ PERSISTÊNCIA, RESPOSTA E NOTIFICAÇÃO
  → Montar Resultado do Lead → Gravar Lead no Banco → Responder ao Cliente (200 / 202)
  → Telegram Configurado? → Formatar Alerta do Lead → Notificar Novo Lead no Telegram
```

**Error Workflow** (`Lead B2B - Error Workflow`): `Error Trigger` → `Registrar Erro Global`
→ `Telegram Configurado?` → `Notificar Erro no Telegram`. Está vinculado ao fluxo principal em
*Settings → Error Workflow*.

---

## 3. Estrutura do repositório

```
.
├── docker-compose.yml        n8n 2.40.7 (versão fixada) + PostgreSQL 16
├── .env.example              todas as variáveis de configuração, comentadas
├── db/migrations/
│   └── 001_criar_tabelas_leads.sql   tabelas, constraints, índices e comentários
├── scripts/
│   ├── setup.sh              sobe tudo, cria a credencial, importa e ativa os workflows
│   └── testar.sh             bateria de 13 testes com verificação do status HTTP
└── workflows/
    ├── Lead_B2B_Processamento_e_Roteamento.json
    └── Lead_B2B_Error_Workflow.json
```

---

## 4. Guia de replicação passo a passo

Tempo estimado: 5 a 10 minutos. A primeira execução baixa cerca de 1,3 GB de imagens Docker.

### Passo 1: conferir os pré-requisitos

| Ferramenta | Como conferir | Observação |
|---|---|---|
| Docker com Compose v2 | `docker compose version` | Docker Desktop (Windows/macOS) ou Docker Engine (Linux) |
| bash e curl | `bash --version` · `curl --version` | **Windows:** rode os comandos dentro do **WSL2** (recomendado) ou do Git Bash |
| Porta 5678 livre | — | Se estiver ocupada, veja o passo 2 |
| Acesso à internet | — | Download das imagens, ViaCEP e BrasilAPI |

> **Linux:** se o `docker` pedir `sudo`, adicione seu usuário ao grupo `docker`
> (`sudo usermod -aG docker $USER`, depois abra um novo terminal) ou rode os scripts com `sudo`.

### Passo 2: obter o projeto (e ajustar a configuração, se precisar)

```bash
git clone https://github.com/GabrielVini03/desafio-n8n-leads-b2b.git
cd desafio-n8n-leads-b2b
```

A configuração padrão funciona sem editar nada. Crie o `.env` antes apenas se precisar mudar
algo, como a porta ou o Telegram (veja a [seção 5](#5-variáveis-de-configuração)):

```bash
cp .env.example .env    # depois edite; ex.: HOST_PORT=5680 se a 5678 estiver ocupada
```

### Passo 3: subir o ambiente

```bash
bash scripts/setup.sh
```

✅ **Confira:** a saída termina com

```
✔ Pronto.
  UI:      http://localhost:5678  (no primeiro acesso, crie a conta de owner)
  Webhook: POST http://localhost:5678/webhook/lead-b2b
```

O script, que pode ser executado mais de uma vez:
1. cria o `.env` a partir do `.env.example`, se ainda não existir;
2. sobe o PostgreSQL (que aplica as migrations de `db/migrations/`) e o n8n;
3. cria a credencial **Postgres Leads** no n8n com os valores do `.env` (a senha é enviada por
   stdin e nunca fica gravada no workflow nem em disco);
4. importa os dois workflows, publica ambos e reinicia o n8n para registrar o webhook.

### Passo 4: rodar a bateria de testes

```bash
bash scripts/testar.sh
```

✅ **Confira:** cada cenário aparece com ✅, e a última linha é
`Resultado: 13 passaram, 0 falharam`.

### Passo 5: ver o fluxo na interface

1. Abra **http://localhost:5678** e crie a conta de owner. Ela fica só na sua máquina: qualquer
   nome, e-mail e senha servem.
2. ✅ **Confira:** na página inicial aparecem os dois workflows, **Lead B2B - Processamento e
   Roteamento** e **Lead B2B - Error Workflow**, ambos publicados.
3. Abra o workflow principal: o canvas está dividido em 5 seções numeradas (① a ⑤), na ordem do
   processamento.
4. Na aba **Executions** do workflow, cada chamada do passo 4 virou uma execução. Abra qualquer
   uma para ver **o caminho percorrido** (os nós executados ficam destacados) e os dados de entrada
   e saída de cada nó. Compare, por exemplo, a execução do lead de SP com a do CEP inexistente.

### Passo 6: explorar por conta própria

- Enviar leads com `curl` e ver a resposta: [seção 7](#7-testes).
- Consultar o que foi gravado no PostgreSQL: [seção 7](#consultar-o-que-foi-gravado).
- Ligar os alertas do Telegram (opcional): [seção 5](#5-variáveis-de-configuração).

### Passo 7: desligar

```bash
docker compose stop          # para os containers (os dados ficam)
docker compose start         # religa
docker compose down -v       # remove containers e volumes (apaga todos os dados)
```

### Alternativa: sem os scripts (importação manual pela UI)

1. `cp .env.example .env && docker compose up -d`, e aguarde a UI abrir em http://localhost:5678.
2. Crie a conta de owner.
3. **Credentials → Create → Postgres**, com nome `Postgres Leads`, host `postgres`, database
   `leads`, user `n8n_leads`, password `n8n_leads_local`, port `5432` e SSL `disable`.
4. Crie um workflow em branco → **⋯ → Import → From file** → `workflows/Lead_B2B_Error_Workflow.json` → salve.
5. Repita com `workflows/Lead_B2B_Processamento_e_Roteamento.json`. Depois:
   - nos nós **Verificar Duplicidade** e **Gravar Lead no Banco**, selecione a credencial *Postgres Leads*;
   - em **⋯ → Settings → Error Workflow**, selecione **Lead B2B - Error Workflow**. A importação
     pela UI gera IDs novos, então esse vínculo precisa ser refeito;
   - salve.
6. Clique em **Publish** nos dois workflows. No n8n 2.x, publicar é o que ativa o webhook de
   produção.

---

## 5. Variáveis de configuração

Todas ficam no `.env`. O workflow lê os valores via expressão nativa `{{ $env.NOME }}`, sem
nenhum endpoint ou segredo fixo no JSON.

| Variável | Padrão | Para que serve |
|---|---|---|
| `HOST_PORT` | `5678` | Porta do host para a UI e o webhook |
| `N8N_BLOCK_ENV_ACCESS_IN_NODE` | `false` | **Obrigatória.** O n8n 2.x bloqueia `$env` por padrão |
| `GENERIC_TIMEZONE` / `TZ` | `America/Sao_Paulo` | Fuso das execuções e dos registros |
| `VIACEP_BASE_URL` | `https://viacep.com.br` | Base do ViaCEP |
| `BRASILAPI_BASE_URL` | `https://brasilapi.com.br` | Base da BrasilAPI |
| `TELEGRAM_API_BASE_URL` | `https://api.telegram.org` | Base da API do Telegram |
| `HTTP_TIMEOUT_MS` | `5000` | Timeout de cada chamada HTTP externa |
| `IDEMPOTENCIA_JANELA_SEGUNDOS` | `300` | Janela em que o mesmo CNPJ é considerado duplicado |
| `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` | `leads` / `n8n_leads` / `n8n_leads_local` | Banco e credencial |
| `TELEGRAM_BOT_TOKEN` | vazio | Token do bot. **Vazio = notificação desligada**, e o fluxo segue normal |
| `TELEGRAM_CHAT_ID` | vazio | Chat que recebe os alertas |

**Telegram (opcional):** no Telegram, fale com **@BotFather** → `/newbot` e copie o token. Abra
o bot criado e toque em **Iniciar**. Descubra o chat_id em
`https://api.telegram.org/bot<TOKEN>/getUpdates` (campo `message.chat.id`). Preencha as duas
variáveis e rode `docker compose up -d` para aplicar.

---

## 6. Contrato da API

`POST /webhook/lead-b2b` · `Content-Type: application/json`

```json
{
  "empresa": "Exemplo Comércio LTDA",
  "cnpj": "43.261.753/0001-63",
  "email": "contato@exemplo.com.br",
  "cep": "01310-100",
  "valor_estimado": 5000
}
```

| HTTP | Quando | Corpo |
|---|---|---|
| **200** | Lead roteado automaticamente | `success: true`, roteamento, município, UF, situação cadastral, razão social, `enriquecimento_incompleto`, `lead_id` |
| **202** | UF não determinada: lead aceito e registrado, encaminhado para triagem manual | Mesmos campos + `erro` com `tipo: LOCALIZACAO_NAO_DETERMINADA` |
| **400** | Corpo vazio, JSON malformado, campo ausente ou dado inválido | `errors: [{ field, message }]` |
| **409** | Mesmo CNPJ recebido dentro da janela de idempotência | `erro.tipo: LEAD_DUPLICADO` |
| **500** | Falha inesperada; o Error Workflow é acionado | `{"message":"Error in workflow"}` (padrão do n8n) |

Exemplo de 200:
```json
{
  "success": true,
  "status": 200,
  "roteamento": "Direcionar para Time Comercial Sul/Sudeste",
  "municipio": "São Paulo",
  "uf": "SP",
  "situacao_cadastral": "ATIVA",
  "razao_social": "TIEXPRESS SOLUCOES LTDA",
  "enriquecimento_incompleto": false,
  "falhas_enriquecimento": [],
  "lead_id": "75c105ec-8610-485d-8a9b-e3d7c3bc3ace"
}
```

---

## 7. Testes

### Bateria completa
```bash
bash scripts/testar.sh
```
Executa 13 cenários e compara o status HTTP com o esperado (✅/❌). Antes de começar, limpa a
tabela de idempotência para que os casos de sucesso não sejam barrados como reenvio.

### Comandos individuais

> Os casos de sucesso usam CNPJs diferentes porque o **mesmo CNPJ é barrado com 409 por 5
> minutos**. Para repetir um caso na sequência, rode o `testar.sh` (que limpa a barreira) ou
> `docker compose exec postgres psql -U n8n_leads -d leads -c "TRUNCATE lead_idempotencia;"`.

**✅ Sucesso: SP → Sul/Sudeste (200)**
```bash
curl -i -X POST http://localhost:5678/webhook/lead-b2b \
  -H 'Content-Type: application/json' \
  -d '{"empresa":"Exemplo Comércio LTDA","cnpj":"43.261.753/0001-63","email":"contato@exemplo.com.br","cep":"01310-100","valor_estimado":5000}'
```

**🔁 Idempotência: repetir o comando acima em seguida (409)**

**✅ Sucesso: SC → Geral (200)**
```bash
curl -i -X POST http://localhost:5678/webhook/lead-b2b \
  -H 'Content-Type: application/json' \
  -d '{"empresa":"Petrobras","cnpj":"33.000.167/0001-01","email":"compras@petrobras.com.br","cep":"88010-400","valor_estimado":120000}'
```

**⚠️ CEP inexistente → exceção operacional (202)**
```bash
curl -i -X POST http://localhost:5678/webhook/lead-b2b \
  -H 'Content-Type: application/json' \
  -d '{"empresa":"Banco do Brasil","cnpj":"00.000.000/0001-91","email":"contato@bb.com.br","cep":"99999-999","valor_estimado":800}'
```

**❌ JSON malformado (400)**
```bash
curl -i -X POST http://localhost:5678/webhook/lead-b2b \
  -H 'Content-Type: application/json' \
  -d '{"empresa": "X",'
```

**❌ Corpo vazio (400, lista os 5 campos ausentes)**
```bash
curl -i -X POST http://localhost:5678/webhook/lead-b2b -H 'Content-Type: application/json'
```

**❌ Campo obrigatório ausente: sem `email` (400)**
```bash
curl -i -X POST http://localhost:5678/webhook/lead-b2b \
  -H 'Content-Type: application/json' \
  -d '{"empresa":"X","cnpj":"43.261.753/0001-63","cep":"01310-100","valor_estimado":100}'
```

**❌ CNPJ com dígito verificador errado (400)**
```bash
curl -i -X POST http://localhost:5678/webhook/lead-b2b \
  -H 'Content-Type: application/json' \
  -d '{"empresa":"X","cnpj":"43.261.753/0001-64","email":"a@b.com","cep":"01310-100","valor_estimado":100}'
```

**❌ CNPJ com dígitos repetidos (400)**
```bash
curl -i -X POST http://localhost:5678/webhook/lead-b2b \
  -H 'Content-Type: application/json' \
  -d '{"empresa":"X","cnpj":"11.111.111/1111-11","email":"a@b.com","cep":"01310-100","valor_estimado":100}'
```

**❌ E-mail malformado (400)**
```bash
curl -i -X POST http://localhost:5678/webhook/lead-b2b \
  -H 'Content-Type: application/json' \
  -d '{"empresa":"X","cnpj":"43.261.753/0001-63","email":"nao-eh-email","cep":"01310-100","valor_estimado":100}'
```

### Consultar o que foi gravado
```bash
# Últimos leads
docker compose exec postgres psql -U n8n_leads -d leads \
  -c "SELECT id, empresa, cnpj, municipio, uf, situacao_cadastral, rota, enriquecimento_incompleto, criado_em FROM leads ORDER BY criado_em DESC LIMIT 10;"

# Fila de triagem manual (usa o índice parcial idx_leads_triagem_pendente)
docker compose exec postgres psql -U n8n_leads -d leads \
  -c "SELECT id, empresa, cep, criado_em FROM leads WHERE rota = 'EXCECAO_OPERACIONAL' ORDER BY criado_em;"

# Estrutura da tabela, com constraints e índices
docker compose exec postgres psql -U n8n_leads -d leads -c "\d+ leads"
```

---

## 8. Modelo de dados

Definido em `db/migrations/001_criar_tabelas_leads.sql`, aplicado dentro de uma transação.

**`leads`**: um registro por lead processado, incluindo os de exceção.

| Coluna | Tipo | Observação |
|---|---|---|
| `id` | `UUID` PK | `gen_random_uuid()`: não expõe volume nem sequência, e pode ser gerado fora do banco |
| `execucao_n8n` | `TEXT` | Liga o lead ao log da execução no n8n |
| `empresa`, `razao_social` | `TEXT` | Nome declarado × razão social oficial (BrasilAPI) |
| `cnpj`, `cep` | `TEXT` | Só dígitos, garantido por `CHECK` (14 e 8 dígitos) |
| `email` | `TEXT` | `CHECK` com a mesma regex do workflow |
| `valor_estimado` | `NUMERIC(14,2)` | Tipo exato para dinheiro (nunca `float`), `CHECK >= 0` |
| `municipio`, `uf` | `TEXT` | Localização do CEP: critério de roteamento |
| `uf_registro`, `situacao_cadastral` | `TEXT` | Dados cadastrais do CNPJ |
| `rota` | `TEXT` | Código estável: `SUL_SUDESTE`, `GERAL` ou `EXCECAO_OPERACIONAL` |
| `enriquecimento_incompleto` | `BOOLEAN` | Alguma API falhou |
| `dados_enriquecidos` | `JSONB` | Respostas brutas das APIs, para auditoria e reprocessamento |
| `criado_em` | `TIMESTAMPTZ` | Instante absoluto, independente de fuso |

- **Constraints nomeadas** (`ck_leads_*`): formato de CNPJ, CEP, e-mail e UF, valor não negativo,
  rota dentro do domínio e a regra de negócio `ck_leads_uf_quando_roteado` (só a exceção pode ficar
  sem UF). O banco é a última linha de defesa, mesmo com o workflow validando antes.
- **Índices:** `cnpj` (busca por empresa), `criado_em DESC` (listagens) e um **índice parcial**
  para a fila de triagem (`WHERE rota = 'EXCECAO_OPERACIONAL'`).

**`lead_idempotencia`**: uma linha por CNPJ com o último recebimento aceito.

| Coluna | Tipo | Observação |
|---|---|---|
| `id` | `UUID` PK | Chave sintética, como em todas as tabelas |
| `cnpj` | `TEXT` | `UNIQUE` (`uq_lead_idempotencia_cnpj`): alvo do `ON CONFLICT (cnpj)` |
| `recebido_em` | `TIMESTAMPTZ` | Início da janela de idempotência |

**Padrão de chaves:** toda tabela tem PK sintética em UUID, e chaves naturais (como o CNPJ) viram
constraints `UNIQUE`. Chaves naturais são previsíveis e podem mudar de formato: o CNPJ, por
exemplo, passou a ter versão alfanumérica em 2026. Com a PK sintética, uma mudança dessas não afeta
identidade nem referências.

---

## 9. Regras de validação

| Campo | Regra |
|---|---|
| **Corpo** | Presente, JSON sintaticamente válido e objeto (não array/primitivo) |
| **Estrutura** | Os 5 campos obrigatórios presentes |
| **empresa** | `trim`; string não vazia |
| **cep** | `trim`; remove tudo que não é dígito (`01310-100` → `01310100`); exatamente 8 dígitos |
| **cnpj** | `trim`; remove máscara; 14 dígitos; rejeita sequências repetidas; valida os **2 dígitos verificadores por módulo 11** (pesos 5‥2/9‥2 e 6‥2/9‥2) |
| **email** | `trim`; regex estrutural `^[^\s@]+@[^\s@]+\.[^\s@]+$` |
| **valor_estimado** | Número finito `>= 0` |

Qualquer violação retorna **400** listando cada campo reprovado e o motivo.

---

## 10. Resiliência e tratamento de erros

| Situação | Comportamento |
|---|---|
| ViaCEP ou BrasilAPI lenta | Timeout de 5 s por tentativa (`HTTP_TIMEOUT_MS`); sem ele o n8n esperaria até 5 min |
| Erro, 5xx ou 429 numa API | 3 tentativas (1 + 2 repetições) com 2 s de espera; depois segue pela saída de erro do nó |
| BrasilAPI indisponível | Rota normal pela UF do ViaCEP; `situacao_cadastral: null`, `enriquecimento_incompleto: true`, `falhas_enriquecimento: ["BrasilAPI"]` |
| ViaCEP indisponível | UF não determinável → exceção operacional (202), com os dados da BrasilAPI preservados |
| PostgreSQL indisponível | Fail-open: o lead é processado e respondido normalmente, com `lead_id: null` |
| Telegram indisponível ou não configurado | A notificação é ignorada; a resposta já foi enviada antes |
| Erro não tratado em qualquer nó | O n8n responde 500 imediatamente e o Error Workflow registra o erro e alerta no Telegram |

Cenários validados em ambiente isolado: API sem resposta (timeout), BrasilAPI com 429 real,
PostgreSQL parado e erro forçado para acionar o Error Workflow.

---

## 11. Memorial de decisões técnicas

**1. Webhook recebendo o corpo cru para responder 400 em JSON malformado.**
No n8n 2.x, o Webhook v2 passa o corpo `application/json` pelo parser da plataforma, que
rejeita JSON inválido com **422 antes de o workflow executar**. Nenhum nó consegue interceptar
isso. Por isso o `Receber Lead B2B` usa a versão 1 do nó com *Binary Data* ativado: o corpo
chega cru e o primeiro nó de código faz o `JSON.parse` com `try/catch`, devolvendo 400 como pede o
requisito 4.1. *Trade-off:* usa uma versão anterior do nó e exige parse manual, em troca de
controle total sobre o contrato de erro.

**2. Idempotência atômica no banco, antes do enriquecimento.**
A barreira é um único `INSERT … ON CONFLICT (cnpj) DO UPDATE … WHERE recebido_em < now() - janela
RETURNING`. Se nenhuma linha volta, o CNPJ já foi aceito na janela e o fluxo responde 409.
Por ser um comando atômico, duas requisições simultâneas não passam juntas, o que não aconteceria
com um "SELECT e depois INSERT". Fica **antes** das APIs, então reenvios não consomem a cota da
BrasilAPI (que responde 429 sob carga). *Trade-offs:* (a) se o processamento falhar depois da
barreira, um reenvio legítimo dentro da janela é barrado; (b) com o banco fora do ar a barreira
fica aberta (fail-open), porque priorizei não perder lead em vez de garantir deduplicação.

**3. Tolerância a falhas visível no canvas, em vez de try/catch em código.**
Os nós HTTP usam *On Error → Continue (using error output)*, com nós dedicados de tratamento.
Retry, espera e timeout são configurações declarativas do nó. *Trade-off:* mais nós no canvas,
em troca de um fluxo que se documenta visualmente e é fácil de auditar.

**4. Um único ponto de convergência para persistência e resposta.**
As três rotas (Sul/Sudeste, Geral, exceção) convergem em `Montar Resultado do Lead`, então
gravação, resposta e alerta existem uma vez só. O lead é gravado **antes** da resposta (o cliente
recebe o `lead_id`), e o Telegram é chamado **depois**, para não somar latência externa ao
cliente. A exceção responde **202**: o lead foi aceito e registrado, mas não roteado.

**5. Roteamento estritamente pelo enunciado.**
SC vai para o Comercial **Geral** apesar de ser da região Sul, porque o requisito lista apenas
SP, RJ, MG e ES. O critério é a UF do **CEP** (ViaCEP), não a UF de registro do CNPJ (gravada à
parte em `uf_registro`). O CNPJ do exemplo do enunciado, por exemplo, é registrado em SC e o CEP
é de SP.

### Melhorias para produção em alta escala
- **Processamento assíncrono:** responder 202 imediatamente e enriquecer via fila (n8n em
  *queue mode* com workers e Redis), desacoplando a latência das APIs externas da resposta HTTP.
- **Cache de enriquecimento:** CEP→UF e CNPJ→cadastro em Redis, reduzindo chamadas e o risco de 429.
- **Autenticação do webhook:** Header Auth ou HMAC, com rate limit por origem num gateway.
- **Gestão de segredos:** credenciais em cofre (Vault, AWS Secrets Manager) em vez de `.env`, e
  `N8N_ENCRYPTION_KEY` definida explicitamente.
- **Observabilidade:** métricas de latência e taxa de falha por serviço externo, e alertas do Error
  Workflow num canal de plantão.
- **CNPJ alfanumérico:** a Receita Federal passou a emitir CNPJs alfanuméricos em julho/2026. A
  validação atual aceita só dígitos e precisaria adotar o cálculo com valores ASCII.
- **Banco:** migrations aplicadas por ferramenta dedicada (Flyway, dbmate) com histórico de versões,
  em vez do init do container; usuário da aplicação com privilégio mínimo (só `INSERT/SELECT` em
  `leads` e `INSERT/UPDATE` em `lead_idempotencia`) no lugar do superusuário; PostgreSQL gerenciado
  com backup e pool de conexões; limpeza periódica da tabela de idempotência.

---

## 12. Solução de problemas

| Sintoma | Causa provável | Solução |
|---|---|---|
| `port is already allocated` ao subir | Porta 5678 em uso | Defina `HOST_PORT=5680` (por exemplo) no `.env` e rode o setup de novo |
| `permission denied ... docker.sock` | Usuário fora do grupo `docker` (Linux) | Veja a nota do passo 1 ou use `sudo` |
| `$'\r': command not found` ao rodar um script | Quebras de linha CRLF (Windows) | Clone de novo com o `.gitattributes` do projeto ou rode `dos2unix scripts/*.sh .env.example` |
| `404 webhook "POST lead-b2b" is not registered` | Workflow inativo ou n8n ainda iniciando | Aguarde alguns segundos ou ative o workflow na UI |
| Todo lead cai na exceção com `uf: null` | `$env` bloqueado | Confirme `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` no `.env` e rode `docker compose up -d` |
| 409 num teste que deveria passar | Mesmo CNPJ dentro da janela | Rode `bash scripts/testar.sh` ou `TRUNCATE lead_idempotencia` |
| Alterei a migration e nada mudou | O Postgres só roda `db/migrations/` com o volume vazio | `docker compose rm -sf postgres && docker volume rm desafio-n8n-leads-b2b_postgres_data && bash scripts/setup.sh` |
| `lead_id: null` na resposta | PostgreSQL indisponível (fail-open) | `docker compose ps` e `docker compose logs postgres` |
| Alerta do Telegram não chega | Token ou chat_id ausente, ou o bot nunca foi iniciado | Toque em **Iniciar** no bot e confira as variáveis |
