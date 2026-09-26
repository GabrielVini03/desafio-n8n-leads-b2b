-- Migration 001 — tabelas de idempotência e de leads.
-- Executada pelo entrypoint do Postgres somente na primeira inicialização do volume
-- (arquivos de /docker-entrypoint-initdb.d, em ordem alfabética).

BEGIN;

-- ---------------------------------------------------------------------------
-- Barreira de idempotência
-- ---------------------------------------------------------------------------
-- PK sintética (UUID), como em todas as tabelas: chaves naturais mudam de formato
-- (ex.: CNPJ alfanumérico) e são previsíveis. A unicidade do CNPJ fica numa
-- constraint UNIQUE, que é o alvo do INSERT ... ON CONFLICT (cnpj) do workflow.
CREATE TABLE lead_idempotencia (
    id          UUID        NOT NULL DEFAULT gen_random_uuid(),
    cnpj        TEXT        NOT NULL,
    recebido_em TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_lead_idempotencia PRIMARY KEY (id),
    CONSTRAINT uq_lead_idempotencia_cnpj UNIQUE (cnpj),
    CONSTRAINT ck_lead_idempotencia_cnpj CHECK (cnpj ~ '^[0-9]{14}$')
);

COMMENT ON TABLE  lead_idempotencia             IS 'Último recebimento aceito por CNPJ; usado para barrar reenvios dentro da janela de idempotência.';
COMMENT ON COLUMN lead_idempotencia.recebido_em IS 'Momento do último recebimento aceito para o CNPJ.';

-- ---------------------------------------------------------------------------
-- Leads processados
-- ---------------------------------------------------------------------------
CREATE TABLE leads (
    id                        UUID          NOT NULL DEFAULT gen_random_uuid(),
    execucao_n8n              TEXT          NOT NULL,
    empresa                   TEXT          NOT NULL,
    razao_social              TEXT,
    cnpj                      TEXT          NOT NULL,
    email                     TEXT          NOT NULL,
    cep                       TEXT          NOT NULL,
    valor_estimado            NUMERIC(14,2) NOT NULL,
    municipio                 TEXT,
    uf                        TEXT,
    uf_registro               TEXT,
    situacao_cadastral        TEXT,
    rota                      TEXT          NOT NULL,
    enriquecimento_incompleto BOOLEAN       NOT NULL DEFAULT false,
    dados_enriquecidos        JSONB         NOT NULL DEFAULT '{}'::jsonb,
    criado_em                 TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT pk_leads PRIMARY KEY (id),

    -- Integridade de domínio: o banco é a última linha de defesa, mesmo com o
    -- workflow já validando esses campos antes.
    CONSTRAINT ck_leads_empresa_nao_vazia CHECK (btrim(empresa) <> ''),
    CONSTRAINT ck_leads_cnpj              CHECK (cnpj ~ '^[0-9]{14}$'),
    CONSTRAINT ck_leads_cep               CHECK (cep ~ '^[0-9]{8}$'),
    CONSTRAINT ck_leads_email             CHECK (email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
    CONSTRAINT ck_leads_valor_estimado    CHECK (valor_estimado >= 0),
    CONSTRAINT ck_leads_uf                CHECK (uf ~ '^[A-Z]{2}$'),
    CONSTRAINT ck_leads_uf_registro       CHECK (uf_registro ~ '^[A-Z]{2}$'),
    CONSTRAINT ck_leads_rota              CHECK (rota IN ('SUL_SUDESTE', 'GERAL', 'EXCECAO_OPERACIONAL')),

    -- Regra de negócio: só a exceção operacional pode ficar sem UF.
    CONSTRAINT ck_leads_uf_quando_roteado CHECK (rota = 'EXCECAO_OPERACIONAL' OR uf IS NOT NULL)
);

COMMENT ON TABLE  leads                           IS 'Registro consolidado de cada lead processado pelo workflow, incluindo os de exceção operacional.';
COMMENT ON COLUMN leads.execucao_n8n              IS 'ID da execução no n8n, para rastrear o lead até o log da execução.';
COMMENT ON COLUMN leads.uf                        IS 'UF do CEP (ViaCEP): critério de roteamento.';
COMMENT ON COLUMN leads.uf_registro               IS 'UF de registro do CNPJ (BrasilAPI): informativa, não usada no roteamento.';
COMMENT ON COLUMN leads.rota                      IS 'Código estável da rota: SUL_SUDESTE, GERAL ou EXCECAO_OPERACIONAL.';
COMMENT ON COLUMN leads.enriquecimento_incompleto IS 'true quando ViaCEP e/ou BrasilAPI falharam e o lead seguiu com dados parciais.';
COMMENT ON COLUMN leads.dados_enriquecidos        IS 'Respostas brutas do ViaCEP e da BrasilAPI, para auditoria e reprocessamento.';

-- Consultas por empresa e listagens cronológicas.
CREATE INDEX idx_leads_cnpj      ON leads (cnpj);
CREATE INDEX idx_leads_criado_em ON leads (criado_em DESC);

-- Fila de triagem manual: índice parcial, contém só os leads em exceção.
CREATE INDEX idx_leads_triagem_pendente ON leads (criado_em) WHERE rota = 'EXCECAO_OPERACIONAL';

COMMIT;
