# Leads B2B no n8n

Workflow que recebe leads de empresas por webhook, valida os dados, consulta CEP e CNPJ em APIs
públicas (ViaCEP e BrasilAPI), decide para qual time comercial o lead vai e responde na hora.
Também bloqueia envios duplicados, grava tudo no PostgreSQL e avisa no Telegram.

**Vídeo:** _adicionar link aqui_

O que tem aqui:

- `workflows/`: os dois workflows exportados do n8n (principal e Error Workflow)
- `scripts/`: `setup.sh` sobe o ambiente e `testar.sh` roda os testes
- `db/migrations/`: criação das tabelas do banco
- `docker-compose.yml` e `.env.example`: ambiente e configuração

## Como rodar

Você precisa de Docker (com Compose v2), git, bash e curl. No Windows, use o terminal do WSL2.

No terminal:

```bash
git clone https://github.com/GabrielVini03/desafio-n8n-leads-b2b.git
cd desafio-n8n-leads-b2b
bash scripts/setup.sh
```

Na primeira vez leva alguns minutos, porque o Docker baixa as imagens. No fim aparece `✔ Pronto.`

Pronto. O n8n fica em http://localhost:5678 e o webhook em
`POST http://localhost:5678/webhook/lead-b2b`. No primeiro acesso ao n8n, ele pede para criar uma
conta; ela fica só na sua máquina, então qualquer e-mail serve.

O `setup.sh` sobe o n8n e o PostgreSQL, cria as tabelas, cadastra a credencial do banco, importa os
dois workflows e ativa os dois. Pode rodar de novo sem problema.

Para desligar, `docker compose stop`. Para religar, `docker compose start`. Para apagar tudo,
`docker compose down -v`.

## Como testar

Este comando roda 13 cenários e mostra se cada um passou:

```bash
bash scripts/testar.sh
```

Para testar um por vez, use os comandos abaixo. Cada CNPJ só é aceito uma vez a cada 5 minutos; para
repetir um teste, rode o `testar.sh`, que limpa esse bloqueio.

Lead válido de SP. Resposta 200, com "Direcionar para Time Comercial Sul/Sudeste". Se rodar de novo
logo em seguida, a resposta é 409 (duplicado).

```bash
curl -i -X POST http://localhost:5678/webhook/lead-b2b -H 'Content-Type: application/json' \
  -d '{"empresa":"Exemplo Comércio LTDA","cnpj":"43.261.753/0001-63","email":"contato@exemplo.com.br","cep":"01310-100","valor_estimado":5000}'
```

Lead válido de SC. Resposta 200, com "Direcionar para Time Comercial Geral".

```bash
curl -i -X POST http://localhost:5678/webhook/lead-b2b -H 'Content-Type: application/json' \
  -d '{"empresa":"Petrobras","cnpj":"33.000.167/0001-01","email":"compras@petrobras.com.br","cep":"88010-400","valor_estimado":120000}'
```

CEP que não existe. Resposta 202: o lead é aceito, mas vai para triagem manual.

```bash
curl -i -X POST http://localhost:5678/webhook/lead-b2b -H 'Content-Type: application/json' \
  -d '{"empresa":"Banco do Brasil","cnpj":"00.000.000/0001-91","email":"contato@bb.com.br","cep":"99999-999","valor_estimado":800}'
```

JSON malformado. Resposta 400.

```bash
curl -i -X POST http://localhost:5678/webhook/lead-b2b -H 'Content-Type: application/json' \
  -d '{"empresa": "X",'
```

Campo obrigatório faltando (sem `email`). Resposta 400, dizendo qual campo falta.

```bash
curl -i -X POST http://localhost:5678/webhook/lead-b2b -H 'Content-Type: application/json' \
  -d '{"empresa":"X","cnpj":"43.261.753/0001-63","cep":"01310-100","valor_estimado":100}'
```

CNPJ com dígito verificador errado. Resposta 400.

```bash
curl -i -X POST http://localhost:5678/webhook/lead-b2b -H 'Content-Type: application/json' \
  -d '{"empresa":"X","cnpj":"43.261.753/0001-64","email":"a@b.com","cep":"01310-100","valor_estimado":100}'
```

E-mail inválido. Resposta 400.

```bash
curl -i -X POST http://localhost:5678/webhook/lead-b2b -H 'Content-Type: application/json' \
  -d '{"empresa":"X","cnpj":"43.261.753/0001-63","email":"nao-eh-email","cep":"01310-100","valor_estimado":100}'
```

No n8n, a aba **Executions** do workflow mostra cada requisição e o caminho que ela percorreu.
Para ver o que foi gravado no banco:

```bash
docker compose exec postgres psql -U n8n_leads -d leads -c "SELECT empresa, uf, rota, criado_em FROM leads;"
```

### Respostas possíveis

- **200**: lead roteado. Traz o roteamento, o município, a UF, a situação cadastral e o id do lead.
- **202**: lead aceito, mas sem UF identificada. Fica registrado para triagem manual.
- **400**: dado inválido. A resposta diz qual campo falhou e por quê.
- **409**: o mesmo CNPJ foi enviado há menos de 5 minutos.
- **500**: erro inesperado. O Error Workflow registra e avisa no Telegram.

Exemplo de resposta 200:

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

## Configuração

Tudo fica no arquivo `.env`, que o `setup.sh` cria a partir do `.env.example`. Os valores padrão já
funcionam. O workflow lê essas variáveis com `$env`, então nenhum endereço ou senha fica fixo no
fluxo. Depois de mudar o `.env`, rode `docker compose up -d`.

| Variável | Padrão | Para quê |
|---|---|---|
| `HOST_PORT` | `5678` | Porta do n8n no seu computador |
| `N8N_BLOCK_ENV_ACCESS_IN_NODE` | `false` | Obrigatória: o n8n 2.x bloqueia o `$env` se ela não estiver como `false` |
| `VIACEP_BASE_URL` | `https://viacep.com.br` | Endereço do ViaCEP |
| `BRASILAPI_BASE_URL` | `https://brasilapi.com.br` | Endereço da BrasilAPI |
| `TELEGRAM_API_BASE_URL` | `https://api.telegram.org` | Endereço da API do Telegram |
| `HTTP_TIMEOUT_MS` | `5000` | Tempo máximo de espera por cada API |
| `IDEMPOTENCIA_JANELA_SEGUNDOS` | `300` | Por quanto tempo o mesmo CNPJ fica bloqueado |
| `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` | `leads`, `n8n_leads`, `n8n_leads_local` | Banco de dados local |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | vazios | Alertas no Telegram (opcional) |
| `GENERIC_TIMEZONE`, `TZ` | `America/Sao_Paulo` | Fuso horário |

Para ligar os alertas do Telegram: crie um bot com o @BotFather, abra o bot e toque em Iniciar,
pegue o seu chat_id em `https://api.telegram.org/bot<TOKEN>/getUpdates` e preencha as duas
variáveis. Sem elas, o fluxo funciona igual, só não manda alertas.

## Como o fluxo funciona

O workflow principal tem 5 etapas, marcadas no canvas:

1. **Validação.** Confere se o JSON é válido e se os 5 campos existem. Tira espaços extras, deixa CEP
   e CNPJ só com números, valida o CNPJ pelos dígitos verificadores (módulo 11) e o e-mail por regex.
   Qualquer problema gera 400.
2. **Duplicados.** Se o mesmo CNPJ chegou nos últimos 5 minutos, responde 409 sem chamar as APIs.
3. **Enriquecimento.** Busca cidade e UF no ViaCEP, razão social e situação cadastral na BrasilAPI.
   Cada chamada espera no máximo 5 segundos e tenta 3 vezes. Se uma API falhar, o fluxo segue com o
   que conseguiu e marca `enriquecimento_incompleto: true`.
4. **Roteamento.** SP, RJ, MG e ES vão para o Time Comercial Sul/Sudeste; as outras UFs, para o Time
   Comercial Geral. Sem UF, o lead vira exceção operacional.
5. **Finalização.** Grava o lead no PostgreSQL, responde ao cliente e só depois manda o alerta no
   Telegram, para não atrasar a resposta.

O segundo workflow, **Lead B2B - Error Workflow**, entra em ação se algo quebrar de forma inesperada:
registra o erro e avisa no Telegram. O cliente recebe 500 na hora, sem ficar esperando.

O banco tem duas tabelas: `leads`, com um registro por lead, e `lead_idempotencia`, que controla os
duplicados. Os ids são UUID, e o próprio banco também valida o formato de CNPJ, CEP, e-mail e UF.

## Decisões técnicas

**1. Receber o corpo da requisição sem conversão, para responder 400 em JSON malformado.**
No n8n 2.x, o nó Webhook padrão recusa JSON inválido com 422 antes de o fluxo rodar, e nenhum nó
consegue mudar isso. Por isso usei a versão 1 do nó, com a opção Binary Data: o corpo chega como
texto e o primeiro nó de código faz a conversão e devolve 400 quando ela falha.
*Trade-off:* uso uma versão mais antiga do nó para cumprir o código de erro pedido.

**2. Bloquear duplicados no banco, antes de chamar as APIs.**
Um único comando SQL (`INSERT ... ON CONFLICT`) registra o CNPJ ou percebe que ele já chegou. Como
é um comando só, duas requisições iguais ao mesmo tempo não passam juntas. E como fica antes das
APIs, envios duplicados não gastam o limite de requisições da BrasilAPI.
*Trade-off:* se o processamento falhar depois do bloqueio, um reenvio nos 5 minutos seguintes é
recusado.

**3. Nunca perder um lead por falha externa.**
Os nós HTTP usam a saída de erro do n8n, com timeout e novas tentativas configurados no próprio nó.
Se uma API ou o banco cair, o lead segue com os dados que deu para obter, em vez de ser recusado.
*Trade-off:* o canvas tem mais nós, mas o comportamento em caso de falha fica visível e fácil de
conferir.

Para colocar em produção com alto volume, eu faria:

- responder 202 na hora e processar em fila (n8n em queue mode, com workers);
- cache de CEP e CNPJ, para reduzir chamadas e evitar o limite das APIs;
- autenticação e limite de requisições no webhook;
- senhas e tokens num cofre (Vault, Secrets Manager) em vez do `.env`;
- migrations com ferramenta própria (Flyway, dbmate) e um usuário de banco com permissões mínimas;
- aceitar o CNPJ alfanumérico, que a Receita Federal começou a emitir em julho de 2026.

## Problemas comuns

- **Porta 5678 ocupada.** Rode `cp .env.example .env`, troque `HOST_PORT` (por exemplo, para 5680)
  e rode o `setup.sh` de novo.
- **Todo lead vira exceção, com `uf: null`.** O `$env` está bloqueado. Confira se
  `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` está no `.env` e rode `docker compose up -d`.
- **409 num teste que deveria passar.** O CNPJ foi usado há menos de 5 minutos. Rode
  `bash scripts/testar.sh`, que limpa o bloqueio.
- **404 "webhook is not registered".** O n8n ainda está iniciando. Espere alguns segundos.
- **Erro `$'\r'` ao rodar um script no Windows.** O arquivo ficou com quebra de linha do Windows.
  Rode `dos2unix scripts/*.sh .env.example`.

## Importar os workflows sem o script

Se preferir importar pela interface do n8n, com o ambiente no ar
(`cp .env.example .env && docker compose up -d`):

1. Em Credentials, crie uma credencial Postgres chamada `Postgres Leads`: host `postgres`, banco
   `leads`, usuário `n8n_leads`, senha `n8n_leads_local`.
2. Importe os dois arquivos da pasta `workflows/` (menu ⋯ → Import → From file), começando pelo
   Error Workflow.
3. No workflow principal, escolha essa credencial nos nós Verificar Duplicidade e Gravar Lead no
   Banco. Em Settings → Error Workflow, escolha "Lead B2B - Error Workflow".
4. Clique em Publish nos dois workflows.
